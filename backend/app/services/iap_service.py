"""IAP entitlement 동기화 공통 로직 (Track A-4).

verify/notifications/status 3엔드포인트가 공유한다: 검증된 트랜잭션 → `iap_entitlements` upsert →
활성/비활성에 따라 `app_metadata.tier` 동기화. 백엔드 테이블이 source of truth(§1.2-3),
JWT tier는 enforcement 캐시.

계약: docs/iap-subscription-spec.md §3.2 / §4.3.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.iap import IapEntitlement
from app.services import supabase_admin
from app.services.apple_iap import VerifiedTransaction

log = logging.getLogger(__name__)


def _now() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def derive_status(tx: VerifiedTransaction, notification_type: str | None = None) -> str:
    """트랜잭션(+선택적 알림 타입)에서 entitlement status를 도출한다.

    active | expired | refunded | revoked. revocation은 REFUND/REVOKE를 구분, 그 외는 만료시각 기준.
    """
    if tx.is_revoked:
        return "refunded" if notification_type == "REFUND" else "revoked"
    if tx.expires_at is not None and tx.expires_at <= _now():
        return "expired"
    return "active"


def _tier_for_status(status: str) -> str:
    return "pro" if status == "active" else "normal"


async def upsert_entitlement(
    db: AsyncSession,
    *,
    user_id: str,
    tx: VerifiedTransaction,
    status: str,
    notification_type: str | None = None,
) -> IapEntitlement:
    """original_transaction_id 기준 멱등 upsert. 같은 트랜잭션 재수신 시 동일 결과."""
    values = {
        "original_transaction_id": tx.original_transaction_id,
        "user_id": user_id,
        "product_id": tx.product_id,
        "status": status,
        "expires_at": tx.expires_at,
        "environment": tx.environment,
        "last_notification_type": notification_type,
        "updated_at": _now(),
    }
    stmt = (
        pg_insert(IapEntitlement)
        .values(**values)
        .on_conflict_do_update(
            index_elements=[IapEntitlement.original_transaction_id],
            set_={
                "user_id": values["user_id"],
                "product_id": values["product_id"],
                "status": values["status"],
                "expires_at": values["expires_at"],
                "environment": values["environment"],
                "last_notification_type": values["last_notification_type"],
                "updated_at": values["updated_at"],
            },
        )
    )
    await db.execute(stmt)
    await db.commit()
    ent = await db.scalar(
        select(IapEntitlement).where(
            IapEntitlement.original_transaction_id == tx.original_transaction_id
        )
    )
    return ent


async def get_active_entitlement(db: AsyncSession, user_id: str) -> IapEntitlement | None:
    """유저의 활성 entitlement(가장 늦은 만료) 반환. 없으면 None."""
    rows = await db.scalars(
        select(IapEntitlement).where(IapEntitlement.user_id == user_id)
    )
    active = [e for e in rows if e.is_active()]
    if not active:
        return None
    return max(active, key=lambda e: (e.expires_at or datetime.max))


async def sync_tier(user_id: str, tier: str) -> None:
    """Supabase `app_metadata.tier`를 동기화한다(merge로 role 보존). 실패는 호출부에서 처리."""
    await supabase_admin.set_app_metadata(user_id, {"tier": tier})
    log.info("IAP tier synced: user=%s tier=%s", user_id, tier)


async def apply_transaction(
    db: AsyncSession,
    *,
    user_id: str,
    tx: VerifiedTransaction,
    notification_type: str | None = None,
    sync_metadata: bool = True,
) -> tuple[IapEntitlement, str]:
    """검증된 트랜잭션을 반영한다: status 도출 → upsert → (활성 entitlement 기준) tier 동기화.

    Returns (해당 entitlement, 유저의 최종 tier).
    """
    status = derive_status(tx, notification_type)
    await upsert_entitlement(
        db, user_id=user_id, tx=tx, status=status, notification_type=notification_type
    )
    # 유저의 종합 활성 여부로 tier 결정(여러 트랜잭션 가능성 방어).
    active = await get_active_entitlement(db, user_id)
    tier = "pro" if active is not None else "normal"
    if sync_metadata:
        await sync_tier(user_id, tier)
    # 응답에 쓸 entitlement는 방금 처리한 것(없으면 활성).
    ent = await db.scalar(
        select(IapEntitlement).where(
            IapEntitlement.original_transaction_id == tx.original_transaction_id
        )
    )
    return ent, tier
