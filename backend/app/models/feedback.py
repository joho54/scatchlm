import uuid
from datetime import datetime, timezone

from sqlalchemy import String, Integer, SmallInteger, Boolean, DateTime, Text, ForeignKey
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class AIResponse(Base):
    """모든 평가 가능한 AI 응답 — 손글씨 피드백, 채팅 응답, 페이지/챕터 가이드 등을 task_type으로 구분한다."""
    __tablename__ = "ai_response"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str] = mapped_column(String, nullable=False, index=True)
    note_id: Mapped[str | None] = mapped_column(String, nullable=True, index=True)
    task_type: Mapped[str] = mapped_column(String, nullable=False)
    language: Mapped[str] = mapped_column(String, nullable=False, default="en")
    response_language: Mapped[str] = mapped_column(String, nullable=False, default="English")
    model: Mapped[str] = mapped_column(String, nullable=False)
    textbook_id: Mapped[str | None] = mapped_column(String, nullable=True)
    current_page: Mapped[int | None] = mapped_column(Integer, nullable=True)
    has_textbook_context: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    prompt_context_snippet: Mapped[str | None] = mapped_column(Text, nullable=True)
    previous_context: Mapped[str | None] = mapped_column(Text, nullable=True)
    response_content: Mapped[str] = mapped_column(Text, nullable=False)
    request_id: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=_utcnow)


class AIResponseRating(Base):
    __tablename__ = "ai_response_rating"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    response_id: Mapped[str] = mapped_column(
        String, ForeignKey("ai_response.id", ondelete="CASCADE"), nullable=False, unique=True, index=True
    )
    user_id: Mapped[str] = mapped_column(String, nullable=False, index=True)
    rating: Mapped[int] = mapped_column(SmallInteger, nullable=False)  # -1 or 1
    reason_tags: Mapped[list[str]] = mapped_column(ARRAY(String), nullable=False, default=list)
    comment: Mapped[str | None] = mapped_column(Text, nullable=True)
    client_ts: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=_utcnow, onupdate=_utcnow)
