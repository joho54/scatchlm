"""IAP 구독 엔드포인트 (Track A-4).

- POST /api/iap/verify         구매 트랜잭션 검증 → tier=pro (유저 인증 필요)
- POST /api/iap/notifications  Apple ASSN v2 웹훅 (유저 인증 없음, JWS 서명만 신뢰)
- GET  /api/iap/status         현재 entitlement 조회/재동기화 (유저 인증 필요)

계약(동결): docs/iap-subscription-spec.md §3.2.
"""
import logging
from datetime import timezone

from fastapi import APIRouter, Body, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.iap import IapEntitlement
from app.services import iap_service
from app.services.apple_iap import AppleVerificationError, verify_notification, verify_transaction

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api/iap", tags=["iap"])


def _iso(dt) -> str | None:
    # DB는 naive UTC로 저장 → 응답 계약(ISO8601 +00:00)에 맞춰 UTC offset을 명시.
    return dt.replace(tzinfo=timezone.utc).isoformat() if dt is not None else None


class VerifyRequest(BaseModel):
    signed_transaction: str


@router.post("/verify")
async def verify(
    body: VerifyRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """StoreKit2 서명 트랜잭션을 검증하고 tier를 동기화한다(§3.2-a)."""
    try:
        tx = verify_transaction(body.signed_transaction)
    except AppleVerificationError as e:
        log.warning("IAP verify failed: user=%s err=%s", user_id, e)
        raise HTTPException(status_code=400, detail={"detail": "invalid transaction", "code": "iap_invalid"})

    # appAccountToken ↔ Supabase user_id 매핑(서명 검증된 값이라 위조 불가). 불일치는 타 계정 트랜잭션.
    if tx.app_account_token and tx.app_account_token.lower() != user_id.lower():
        log.warning("IAP account mismatch: token=%s user=%s", tx.app_account_token, user_id)
        raise HTTPException(
            status_code=409,
            detail={"detail": "transaction belongs to another account", "code": "iap_account_mismatch"},
        )

    try:
        ent, tier = await iap_service.apply_transaction(db, user_id=user_id, tx=tx)
    except Exception:
        log.exception("IAP verify upstream failed: user=%s", user_id)
        raise HTTPException(status_code=502, detail="verification upstream failed")

    return {
        "tier": tier,
        "product_id": tx.product_id or None,
        "expires_at": _iso(tx.expires_at),
        "environment": tx.environment,
    }


@router.post("/notifications")
async def notifications(payload: dict = Body(...), db: AsyncSession = Depends(get_db)):
    """Apple ASSN v2 웹훅(§3.2-b). 유저 인증 없음 — 신뢰는 JWS 서명 검증으로만."""
    signed = payload.get("signedPayload")
    if not signed or not isinstance(signed, str):
        raise HTTPException(status_code=400, detail="missing signedPayload")

    try:
        notification, tx = verify_notification(signed)
    except AppleVerificationError as e:
        log.warning("ASSN verify failed: %s", e)
        raise HTTPException(status_code=400, detail="invalid signedPayload")

    ntype = notification.notificationType.value if notification.notificationType else (
        notification.rawNotificationType or "UNKNOWN"
    )

    # 검증 통과 후 처리 실패는 200 + 내부 로깅(Apple 재시도 폭주 방지 — §3.2-b).
    try:
        if tx is None:
            log.info("ASSN no transaction info: type=%s uuid=%s", ntype, notification.notificationUUID)
            return {"received": True}

        # 유저 매핑: appAccountToken(서명 검증값) 우선, 없으면 기존 entitlement에서 역참조.
        user_id = tx.app_account_token.lower() if tx.app_account_token else None
        if user_id is None:
            existing = await db.scalar(
                select(IapEntitlement).where(
                    IapEntitlement.original_transaction_id == tx.original_transaction_id
                )
            )
            user_id = existing.user_id if existing else None
        if user_id is None:
            log.warning("ASSN unmappable transaction: type=%s otid=%s", ntype, tx.original_transaction_id)
            return {"received": True}

        await iap_service.apply_transaction(db, user_id=user_id, tx=tx, notification_type=ntype)
        log.info("ASSN processed: type=%s user=%s otid=%s", ntype, user_id, tx.original_transaction_id)
    except Exception:
        log.exception("ASSN processing failed (acknowledged 200): type=%s", ntype)

    return {"received": True}


@router.get("/status")
async def status(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """현재 entitlement 조회 + tier 재동기화(웹훅 누락 복구, §3.2-c)."""
    active = await iap_service.get_active_entitlement(db, user_id)
    tier = "pro" if active is not None else "normal"

    # 웹훅 누락 복구: 백엔드 source of truth로 app_metadata.tier를 best-effort 재설정.
    try:
        await iap_service.sync_tier(user_id, tier)
    except Exception:
        log.exception("IAP status tier re-sync failed (non-fatal): user=%s", user_id)

    if active is None:
        return {"tier": "normal", "product_id": None, "expires_at": None, "active": False}
    return {
        "tier": tier,
        "product_id": active.product_id,
        "expires_at": _iso(active.expires_at),
        "active": True,
    }
