import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


def _now_naive() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class AppLog(Base):
    """FE 텔레메트리 영속 적재 (data-durability-spec §B.3).

    devlog.py의 /api/dev/log/batch ingest 경로가 best-effort로 적재한다.
    배포(컨테이너 재생성)에 살아남고, `users` 분석을 SQL 집계+users JOIN으로 전환할
    기반. user_id/session_id는 절단 없이 전체값을 저장해 users.id(uuid)와 equi-join.
    """

    __tablename__ = "app_logs"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    # FE entry.ts/timestamp 파싱, 실패 시 received_at 폴백
    ts: Mapped[datetime] = mapped_column(DateTime, nullable=False, index=True)
    # 백엔드 수신 시각
    received_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=_now_naive)
    level: Mapped[str] = mapped_column(String, nullable=False)  # info/warn/error/debug
    tag: Mapped[str] = mapped_column(String, nullable=False, default="", index=True)
    message: Mapped[str] = mapped_column(Text, nullable=False)
    data: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    # 전체값 저장(절단 X) — users.id와 JOIN
    user_id: Mapped[str | None] = mapped_column(String, nullable=True, index=True)
    session_id: Mapped[str | None] = mapped_column(String, nullable=True, index=True)
    trace_id: Mapped[str | None] = mapped_column(String, nullable=True)
    request_id: Mapped[str | None] = mapped_column(String, nullable=True)
    app_version: Mapped[str | None] = mapped_column(String, nullable=True)
    build: Mapped[str | None] = mapped_column(String, nullable=True)
    os_version: Mapped[str | None] = mapped_column(String, nullable=True)
    device_model: Mapped[str | None] = mapped_column(String, nullable=True)
    locale: Mapped[str | None] = mapped_column(String, nullable=True)
