"""IAP entitlement 영속 모델 (Track A-1).

백엔드가 구독 상태의 source of truth. JWT `app_metadata.tier`는 enforcement 캐시일 뿐이고,
이 테이블이 검증/웹훅으로 갱신되는 진짜 상태다(누락 웹훅 복구·앱 시작 재동기화·감사·환불 추적).

계약/스키마: docs/iap-subscription-spec.md §4.3.
"""
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


class IapEntitlement(Base):
    __tablename__ = "iap_entitlements"

    # Apple 구독 식별자 — 갱신돼도 불변. 멱등 upsert의 키.
    original_transaction_id: Mapped[str] = mapped_column(String, primary_key=True)
    # Supabase uid. auth는 Supabase 소관이라 FK 없음. 조회 인덱스만.
    user_id: Mapped[str] = mapped_column(String, nullable=False, index=True)
    product_id: Mapped[str] = mapped_column(String, nullable=False)
    # active | expired | refunded | revoked
    status: Mapped[str] = mapped_column(String, nullable=False)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    # Production | Sandbox
    environment: Mapped[str] = mapped_column(String, nullable=False)
    # ASSN v2 notificationType (감사용)
    last_notification_type: Mapped[str | None] = mapped_column(Text, nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime,
        default=lambda: datetime.now(timezone.utc).replace(tzinfo=None),
        onupdate=lambda: datetime.now(timezone.utc).replace(tzinfo=None),
    )

    def is_active(self, now: datetime | None = None) -> bool:
        """활성 판정: status==active && (expires_at 없음 or 미래)."""
        if self.status != "active":
            return False
        if self.expires_at is None:
            return True
        ref = now or datetime.now(timezone.utc).replace(tzinfo=None)
        return self.expires_at > ref
