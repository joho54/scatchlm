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

from app.core.constants import DEFAULT_SUBJECT
from app.models.user import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class Folder(Base):
    """노트 정리용 플랫(단일 레벨) 폴더 — note-folders-spec §4.1.

    note.folder_id가 이 폴더를 가리킨다(FK 강제 안 함, 단순 컬럼). 폴더 삭제는
    soft delete이며 소속 노트는 클라가 folder_id=NULL로 옮긴다(노트 유실 방지, §4.4).
    """
    __tablename__ = "folders"

    id: Mapped[str] = mapped_column(String, primary_key=True)  # 클라 생성 UUID
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False, default="")
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_folders_user_updated", "user_id", "updated_at"),)


class Note(Base):
    __tablename__ = "notes"

    id: Mapped[str] = mapped_column(String, primary_key=True)  # 클라 생성 UUID
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    title: Mapped[str] = mapped_column(String, nullable=False, default="")
    language: Mapped[str] = mapped_column(String, nullable=False, default=DEFAULT_SUBJECT)
    folder_id: Mapped[str | None] = mapped_column(String, nullable=True)  # 미분류=NULL (FK 강제 안 함)
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


class PdfAnnotation(Base):
    """PDF 페이지 위 필기 오버레이 (필기 전용). 노트 종속(note_id) + PDF 페이지 번호(pdf_page).

    note_pages와 동일한 sync 모델이되 페이지 키가 PDF 페이지 번호(1-based)다.
    drawing 본문은 blob 채널(drawing_hash)로 동기화한다.
    """
    __tablename__ = "pdf_annotations"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    note_id: Mapped[str] = mapped_column(String, nullable=False)
    pdf_page: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    drawing_hash: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_pdf_annotations_user_updated", "user_id", "updated_at"),)


class ChatSession(Base):
    """캔버스 비종속 채팅 세션 (chapter-chat-drawer-spec §3.2-a).

    가이드/피드백 채팅을 한 엔티티로 흡수. 서버는 sync 미러일 뿐 세션 로직은 없다.
    챕터 귀속은 `textbook_id`+`anchor_page`로 보관(표시 시 클라가 chapters로 계산).
    """
    __tablename__ = "chat_sessions"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    kind: Mapped[str] = mapped_column(String, nullable=False, default="feedback")
    title: Mapped[str] = mapped_column(Text, nullable=False, default="")
    note_id: Mapped[str | None] = mapped_column(String, nullable=True)
    textbook_id: Mapped[str | None] = mapped_column(String, nullable=True)
    anchor_page: Mapped[int | None] = mapped_column(Integer, nullable=True)
    chapter_title: Mapped[str | None] = mapped_column(String, nullable=True)
    source_feedback_id: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_chat_sessions_user_updated", "user_id", "updated_at"),)


class Feedback(Base):
    """클라 피드백 카드 메타(위치/bbox/stroke 범위). LLM 본문 로그인 AIResponse와 별개.

    `server_feedback_id`로 AIResponse를 옵션 참조(§4.3). `session_id`로 세션을 placement한다.
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
    session_id: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_feedbacks_user_updated", "user_id", "updated_at"),)


class ChatMessage(Base):
    """iOS 로컬 `feedback_chats` → 서버 `chat_messages`."""
    __tablename__ = "chat_messages"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    session_id: Mapped[str] = mapped_column(String, nullable=False, default="")
    feedback_id: Mapped[str | None] = mapped_column(String, nullable=True)
    role: Mapped[str] = mapped_column(String, nullable=False, default="user")
    content: Mapped[str] = mapped_column(Text, nullable=False, default="")
    server_message_id: Mapped[str | None] = mapped_column(String, nullable=True)
    user_rating: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    __table_args__ = (Index("ix_chat_messages_user_updated", "user_id", "updated_at"),)
