import uuid
from datetime import datetime, timezone

from sqlalchemy import String, Integer, Float, DateTime, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.constants import DEFAULT_SUBJECT
from app.models.user import Base


class LLMUsage(Base):
    __tablename__ = "llm_usage"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str] = mapped_column(String, nullable=False, index=True)
    model: Mapped[str] = mapped_column(String, nullable=False)
    input_tokens: Mapped[int] = mapped_column(Integer, nullable=False)
    output_tokens: Mapped[int] = mapped_column(Integer, nullable=False)
    total_tokens: Mapped[int] = mapped_column(Integer, nullable=False)
    cost_usd: Mapped[float] = mapped_column(Float, nullable=False)
    latency_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    task_type: Mapped[str] = mapped_column(String, nullable=False)
    language: Mapped[str] = mapped_column(String, nullable=False, default=DEFAULT_SUBJECT)
    has_textbook_context: Mapped[bool] = mapped_column(default=False)
    # 일일 비용 quota(quota.py)에 차감되는지. False면 기록은 하되 한도엔 안 잡힌다.
    # 정책상 면제: chapter_detect(업로드 자동), recognition·query_rewrite(피드백 하위 단계),
    # ocr(자체 월 파일수 + 일일 백스톱 트랙). 기본 True.
    billable: Mapped[bool] = mapped_column(default=True, server_default="true")
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None)
    )
