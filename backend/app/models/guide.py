from datetime import datetime, timezone

from sqlalchemy import String, Integer, Text, DateTime, UniqueConstraint, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


class PageGuide(Base):
    __tablename__ = "page_guides"
    __table_args__ = (
        UniqueConstraint("textbook_id", "page", "response_language", name="uq_page_guide"),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True)
    textbook_id: Mapped[str] = mapped_column(
        String, ForeignKey("textbook_sources.id", ondelete="CASCADE"), nullable=False
    )
    page: Mapped[int] = mapped_column(Integer, nullable=False)
    # 캐시 키 차원 — 피드백 언어가 바뀌면 다른 언어 가이드를 별도 캐싱(stale 방지).
    response_language: Mapped[str] = mapped_column(String, nullable=False, default="Korean")
    content: Mapped[str] = mapped_column(Text, nullable=False)  # JSON serialized
    ai_response_id: Mapped[str | None] = mapped_column(
        String, ForeignKey("ai_response.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None)
    )
