import uuid
from datetime import datetime, timezone

from sqlalchemy import String, Integer, DateTime, ForeignKey, Boolean
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


class TextbookSource(Base):
    __tablename__ = "textbook_sources"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    note_id: Mapped[str | None] = mapped_column(String, nullable=True)
    file_name: Mapped[str] = mapped_column(String, nullable=False)
    server_path: Mapped[str] = mapped_column(String, nullable=False)
    total_pages: Mapped[int] = mapped_column(Integer, nullable=False)
    file_size: Mapped[int] = mapped_column(Integer, nullable=False)
    content_hash: Mapped[str | None] = mapped_column(String, nullable=True, index=True)
    # 스캔본(이미지) PDF OCR 상태 — docs/scanned-pdf-ocr-spec.md §4.1-b.
    is_scanned: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    ocr_status: Mapped[str | None] = mapped_column(String, nullable=True)  # pending|running|paused|capped|complete
    ocr_pages_done: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    ocr_cap: Mapped[int | None] = mapped_column(Integer, nullable=True)  # 이 책에 적용된 캡 (free=50, pro=600)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None))
