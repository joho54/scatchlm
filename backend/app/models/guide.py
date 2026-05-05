from datetime import datetime, timezone

from sqlalchemy import String, Integer, Text, DateTime, UniqueConstraint, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


class PageGuide(Base):
    __tablename__ = "page_guides"
    __table_args__ = (
        UniqueConstraint("textbook_id", "page", name="uq_page_guide"),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True)
    textbook_id: Mapped[str] = mapped_column(
        String, ForeignKey("textbook_sources.id", ondelete="CASCADE"), nullable=False
    )
    page: Mapped[int] = mapped_column(Integer, nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)  # JSON serialized
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None)
    )
