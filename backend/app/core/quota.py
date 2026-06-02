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
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.usage import LLMUsage

log = logging.getLogger(__name__)

KST = timezone(timedelta(hours=9))


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


async def check_daily_quota(user_id: str, tier: str, db: AsyncSession) -> None:
    """일일 비용 한도 초과 시 HTTPException(429)를 던진다. 한도 0/미설정이면 무제한(통과)."""
    limit = _limit_for_tier(tier)
    if not limit or limit <= 0:
        return  # 무제한

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
