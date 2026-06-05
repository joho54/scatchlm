import uuid
from datetime import datetime, timezone

from sqlalchemy import String, Integer, Text, DateTime, ForeignKey, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


class OcrPageText(Base):
    """스캔본 PDF의 페이지별 OCR 추출 텍스트 캐시.

    페이지 1:1 매핑이라 `extract_text` OCR 분기와 재개(skip-on-exists) 판정이 단순하다.
    (DocumentChunk는 청크 단위라 페이지 1:1이 아니므로 전용 테이블을 둔다.)
    """
    __tablename__ = "ocr_page_text"
    __table_args__ = (
        UniqueConstraint("textbook_id", "page", name="uq_ocr_page_text_textbook_page"),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    textbook_id: Mapped[str] = mapped_column(
        String, ForeignKey("textbook_sources.id", ondelete="CASCADE"), nullable=False, index=True
    )
    page: Mapped[int] = mapped_column(Integer, nullable=False)  # 1-indexed
    content: Mapped[str] = mapped_column(Text, nullable=False)  # OCR 원문 (null 바이트 제거)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None)
    )
