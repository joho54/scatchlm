"""델타 동기화 대상 테이블 — iOS 로컬 5개 테이블 중 4개를 서버에 미러링한다.

PK는 클라이언트 생성 UUID를 그대로 canonical id로 사용한다(id 재매핑 불필요).
모든 테이블은 `user_id` 스코프 + `updated_at`(LWW 기준) + `deleted`(soft delete tombstone)를 갖는다.
`(user_id, updated_at)` 복합 인덱스가 pull 쿼리의 핵심이다.

cloud-data-sync-spec §3.2 / §4.3 / A-1 참조.
`pdf_drawings`는 휴면 테이블이라 sync 대상에서 제외(§1.2).
"""
from datetime import datetime, timezone

from sqlalchemy import (
    String,
    Integer,
    Boolean,
    Double,
    DateTime,
    Text,
    ForeignKey,
    Index,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class Note(Base):
    __tablename__ = "notes"

    id: Mapped[str] = mapped_column(String, primary_key=True)  # 클라 생성 UUID
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    title: Mapped[str] = mapped_column(String, nullable=False, default="")
    language: Mapped[str] = mapped_column(String, nullable=False, default="en")
    textbook_id: Mapped[str | None] = mapped_column(String, nullable=True)
    textbook_name: Mapped[str | None] = mapped_column(String, nullable=True)
    textbook_pages: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_page: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    pdf_open: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    current_page_index: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    drawing_hash: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_notes_user_updated", "user_id", "updated_at"),)


class NotePage(Base):
    __tablename__ = "note_pages"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    note_id: Mapped[str] = mapped_column(String, nullable=False)
    page_index: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    drawing_hash: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_note_pages_user_updated", "user_id", "updated_at"),)


class Feedback(Base):
    """클라 피드백 카드 메타(위치/bbox/stroke 범위). LLM 본문 로그인 AIResponse와 별개.

    `server_feedback_id`로 AIResponse를 옵션 참조(§4.3).
    """
    __tablename__ = "feedbacks"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    note_id: Mapped[str] = mapped_column(String, nullable=False)
    page_id: Mapped[str | None] = mapped_column(String, nullable=True)
    content: Mapped[str] = mapped_column(Text, nullable=False, default="")
    position_x: Mapped[float] = mapped_column(Double, nullable=False, default=0.0)
    position_y: Mapped[float] = mapped_column(Double, nullable=False, default=0.0)
    bbox_x: Mapped[float] = mapped_column(Double, nullable=False, default=0.0)
    bbox_y: Mapped[float] = mapped_column(Double, nullable=False, default=0.0)
    bbox_width: Mapped[float] = mapped_column(Double, nullable=False, default=0.0)
    bbox_height: Mapped[float] = mapped_column(Double, nullable=False, default=0.0)
    stroke_range_start: Mapped[int | None] = mapped_column(Integer, nullable=True)
    stroke_range_end: Mapped[int | None] = mapped_column(Integer, nullable=True)
    server_feedback_id: Mapped[str | None] = mapped_column(String, nullable=True)
    user_rating: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_feedbacks_user_updated", "user_id", "updated_at"),)


class ChatMessage(Base):
    """iOS 로컬 `feedback_chats` → 서버 `chat_messages`."""
    __tablename__ = "chat_messages"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    feedback_id: Mapped[str] = mapped_column(String, nullable=False)
    role: Mapped[str] = mapped_column(String, nullable=False, default="user")
    content: Mapped[str] = mapped_column(Text, nullable=False, default="")
    server_message_id: Mapped[str | None] = mapped_column(String, nullable=True)
    user_rating: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_chat_messages_user_updated", "user_id", "updated_at"),)
