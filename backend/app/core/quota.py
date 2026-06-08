"""LLM 일일 비용 한도 (L5 / Track B-1).

기준: **비용**(요청 수 아님). 윈도우: **KST(Asia/Seoul) 달력 일** — 자정 리셋(롤링 24h 아님).
tier별 한도는 검증된 JWT `app_metadata.tier`로 결정(`DAILY_COST_LIMIT_{NORMAL,PRO}_USD`).
0/미설정 → 해당 tier 무제한.

계약: docs/launch-readiness-implementation-spec.md §3.2-b.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.usage import LLMUsage
from app.models.textbook import TextbookSource

log = logging.getLogger(__name__)

KST = timezone(timedelta(hours=9))


def _kst_month_bounds(now_utc: datetime | None = None) -> tuple[datetime, datetime]:
    """(이번 달 KST 1일 0시의 UTC-naive 시각, 다음 달 KST 1일 0시 aware 시각)을 반환.

    ocr_started_at은 naive UTC로 저장되므로 비교 하한도 naive UTC로 맞춘다.
    """
    now_utc = now_utc or datetime.now(timezone.utc)
    now_kst = now_utc.astimezone(KST)
    month_start_kst = now_kst.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if month_start_kst.month == 12:
        next_month_kst = month_start_kst.replace(year=month_start_kst.year + 1, month=1)
    else:
        next_month_kst = month_start_kst.replace(month=month_start_kst.month + 1)
    since_utc_naive = month_start_kst.astimezone(timezone.utc).replace(tzinfo=None)
    return since_utc_naive, next_month_kst


def _kst_day_bounds(now_utc: datetime | None = None) -> tuple[datetime, datetime]:
    """(오늘 KST 자정의 UTC-naive 시각, 다음 KST 자정 aware 시각)을 반환.

    llm_usage.created_at은 naive UTC로 저장되므로 비교 하한도 naive UTC로 맞춘다.
    """
    now_utc = now_utc or datetime.now(timezone.utc)
    now_kst = now_utc.astimezone(KST)
    midnight_kst = now_kst.replace(hour=0, minute=0, second=0, microsecond=0)
    next_midnight_kst = midnight_kst + timedelta(days=1)
    # 하한: KST 자정을 UTC naive로 변환
    since_utc_naive = midnight_kst.astimezone(timezone.utc).replace(tzinfo=None)
    return since_utc_naive, next_midnight_kst


def _limit_for_tier(tier: str) -> float:
    if tier == "pro":
        return settings.DAILY_COST_LIMIT_PRO_USD
    return settings.DAILY_COST_LIMIT_NORMAL_USD


async def check_daily_quota(user_id: str, tier: str, db: AsyncSession, *, is_admin: bool = False) -> None:
    """일일 비용 한도 초과 시 HTTPException(429)를 던진다. 한도 0/미설정이면 무제한(통과).

    is_admin(검증된 JWT role=="admin")이면 한도 무관하게 무제한 — 운영자 dogfooding용.
    """
    if is_admin:
        return  # 운영자(admin) 무제한
    limit = _limit_for_tier(tier)
    if not limit or limit <= 0:
        return  # 무제한 (락도 생략 — 오버헤드 회피)

    # 동시성 race 방지: per-user 트랜잭션 advisory lock.
    # check_daily_quota → LLM 호출 → usage commit 사이에 중간 commit이 없으므로,
    # 이 lock은 요청이 usage를 기록·커밋할 때까지 유지된다. 같은 유저의 다음 요청은
    # lock 획득에서 대기 → 직전 요청의 비용을 반영한 합계를 읽는다(stale read 차단).
    # 한 유저의 병렬 요청만 직렬화되며(타 유저 무관), hashtext 충돌 시 드물게
    # 무관한 유저와 직렬화될 뿐 정확성·안전성에는 영향 없다.
    await db.execute(text("SELECT pg_advisory_xact_lock(hashtext(:uid))"), {"uid": user_id})

    since, next_midnight_kst = _kst_day_bounds()
    used = await db.scalar(
        select(func.coalesce(func.sum(LLMUsage.cost_usd), 0.0)).where(
            LLMUsage.user_id == user_id,
            LLMUsage.created_at >= since,
        )
    )
    used = float(used or 0.0)

    if used >= limit:
        retry_after = max(1, int((next_midnight_kst - datetime.now(KST)).total_seconds()))
        log.warning(
            "Quota exceeded: user=%s tier=%s used=$%.4f limit=$%.4f",
            user_id, tier, used, limit,
        )
        raise HTTPException(
            status_code=429,
            detail={
                "detail": "Daily usage limit reached",
                "code": "quota_exceeded",
                "tier": tier,
                "limit_usd": round(limit, 4),
                "used_usd": round(used, 4),
                "reset_at": next_midnight_kst.isoformat(),
            },
            headers={"Retry-After": str(retry_after)},
        )

    # O3: 임계(80%) 초과 시 비용 폭주 조기 경보.
    if used >= limit * 0.8:
        log.warning(
            "Quota near limit (>=80%%): user=%s tier=%s used=$%.4f limit=$%.4f",
            user_id, tier, used, limit,
        )


def _ocr_monthly_limit_for_tier(tier: str) -> int:
    if tier == "pro":
        return settings.OCR_MONTHLY_FILES_PRO
    return settings.OCR_MONTHLY_FILES_FREE


async def check_ocr_monthly_quota(
    user_id: str, tier: str, db: AsyncSession, *, is_admin: bool = False
) -> None:
    """이번 KST 달력 월에 OCR을 시작한 스캔본 *파일 수*가 tier 한도 이상이면 429를 던진다.

    "한 PDF는 원자적으로 처리"가 원칙이라 시간축 분할(일일 예산 pause) 대신 시작 시점에
    건수로 게이트한다. ocr_started_at이 이번 달인 행을 센다(재개/재시도는 ocr_started_at을
    갱신하지 않으므로 한 파일은 평생 1건만 차지 — 중복 카운트 없음). 호출부는 이 체크를
    통과한 뒤에만 ocr_started_at을 set하므로, 시작하려는 당사자는 아직 카운트에 안 잡힌다.

    is_admin이면 무제한(통과).
    """
    if is_admin:
        return
    limit = _ocr_monthly_limit_for_tier(tier)
    if not limit or limit <= 0:
        # 0 → 해당 tier는 스캔본 OCR 비허용.
        raise HTTPException(
            status_code=429,
            detail={
                "detail": "Scanned OCR is not available on this plan",
                "code": "ocr_quota_exceeded",
                "tier": tier,
                "limit_files": 0,
                "used_files": 0,
            },
        )

    # 같은 유저의 동시 start_ocr가 한도를 넘겨 통과하는 race 방지(check_daily_quota와 동일 패턴).
    await db.execute(text("SELECT pg_advisory_xact_lock(hashtext(:uid))"), {"uid": "ocrm:" + user_id})

    since, next_month_kst = _kst_month_bounds()
    used = await db.scalar(
        select(func.count()).select_from(TextbookSource).where(
            TextbookSource.user_id == user_id,
            TextbookSource.ocr_started_at >= since,
        )
    )
    used = int(used or 0)
    if used >= limit:
        retry_after = max(1, int((next_month_kst - datetime.now(KST)).total_seconds()))
        log.warning(
            "OCR monthly quota exceeded: user=%s tier=%s used=%d limit=%d",
            user_id, tier, used, limit,
        )
        raise HTTPException(
            status_code=429,
            detail={
                "detail": "Monthly OCR file limit reached",
                "code": "ocr_quota_exceeded",
                "tier": tier,
                "limit_files": limit,
                "used_files": used,
                "reset_at": next_month_kst.isoformat(),
            },
            headers={"Retry-After": str(retry_after)},
        )


async def check_ocr_quota(user_id: str, db: AsyncSession) -> bool:
    """OCR(task_type="ocr") 일일 비용 *백스톱* 초과 여부를 반환한다(True=초과).

    1차 게이트는 check_ocr_monthly_quota(건수). 이건 무한재시도 등 폭주 버그 대비 안전망일
    뿐 정상 UX 경로에선 닿지 않는다. 백그라운드 잡 페이싱용이라 429를 던지지 않고 bool 반환
    (초과 시 잡은 paused 후 다음 사이클 재개). DAILY_COST_LIMIT_OCR_PRO_USD가 0/미설정이면 무제한(False).
    """
    limit = settings.DAILY_COST_LIMIT_OCR_PRO_USD
    if not limit or limit <= 0:
        return False
    since, _ = _kst_day_bounds()
    used = await db.scalar(
        select(func.coalesce(func.sum(LLMUsage.cost_usd), 0.0)).where(
            LLMUsage.user_id == user_id,
            LLMUsage.task_type == "ocr",
            LLMUsage.created_at >= since,
        )
    )
    used = float(used or 0.0)
    if used >= limit:
        log.warning("OCR quota exceeded: user=%s used=$%.4f limit=$%.4f", user_id, used, limit)
        return True
    return False
