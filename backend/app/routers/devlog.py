import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.models.app_log import AppLog

log = logging.getLogger("fe")

router = APIRouter(prefix="/api/dev", tags=["devlog"])


def _parse_ts(raw: str | None, fallback: datetime) -> datetime:
    """FE entry.ts/timestamp(ISO8601)를 naive UTC datetime으로 파싱. 실패 시 fallback."""
    if not raw:
        return fallback
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return fallback
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt


class LogEntry(BaseModel):
    level: str = "info"
    tag: str = ""
    message: str
    data: dict | None = None
    # `ts`(신규) 또는 `timestamp`(레거시) 모두 수용.
    ts: str | None = None
    timestamp: str | None = None
    request_id: str | None = None
    trace_id: str | None = None


class LogContext(BaseModel):
    user_id: str | None = None
    app_version: str | None = None
    build: str | None = None
    os_version: str | None = None
    device_model: str | None = None
    locale: str | None = None
    session_id: str | None = None
    # FE Sentry trace_id (spec §4.3). FE 로그↔Sentry 트레이스 상관.
    trace_id: str | None = None
    # 인증 provider (spec §3.2-a): "apple"|"google"|"email"|null. 미인증/미상이면 None → 토큰 생략.
    provider: str | None = None


class LogBatch(BaseModel):
    logs: list[LogEntry]
    context: LogContext | None = None  # optional — 하위호환


@router.post("/log")
async def receive_log(entry: LogEntry):
    _emit(entry, None)
    return {"ok": True}


@router.post("/log/batch")
async def receive_log_batch(batch: LogBatch, db: AsyncSession = Depends(get_db)):
    for entry in batch.logs:
        _emit(entry, batch.context)
    # best-effort DB 적재 (§B.4 Track A): 실패해도 엔드포인트는 정상 반환.
    await _persist(batch, db)
    return {"received": len(batch.logs)}


async def _persist(batch: "LogBatch", db: AsyncSession) -> None:
    """entry+context → AppLog row 배치 적재. DB 실패는 삼키고 콘솔 로그만 남긴다."""
    if not batch.logs:
        return
    ctx = batch.context
    received_at = datetime.now(timezone.utc).replace(tzinfo=None)
    try:
        rows = [
            AppLog(
                ts=_parse_ts(entry.ts or entry.timestamp, received_at),
                received_at=received_at,
                level=entry.level or "info",
                tag=entry.tag or "",
                message=entry.message,
                data=entry.data,
                user_id=(ctx.user_id if ctx and ctx.user_id else None),
                session_id=(ctx.session_id if ctx else None),
                trace_id=entry.trace_id or (ctx.trace_id if ctx else None),
                request_id=entry.request_id,
                app_version=(ctx.app_version if ctx else None),
                build=(ctx.build if ctx else None),
                os_version=(ctx.os_version if ctx else None),
                device_model=(ctx.device_model if ctx else None),
                locale=(ctx.locale if ctx else None),
            )
            for entry in batch.logs
        ]
        db.add_all(rows)
        await db.commit()
    except Exception as exc:  # noqa: BLE001 — best-effort, 적재 실패가 수집을 깨면 안 됨
        await db.rollback()
        log.warning(f"[devlog] app_logs 적재 실패(무시): {type(exc).__name__}: {exc}")


def _emit(entry: LogEntry, context: "LogContext | None"):
    level = entry.level.upper()
    ts = entry.ts or entry.timestamp or datetime.now(timezone.utc).isoformat()
    parts = [f"[FE {ts}]"]
    # FE Sentry trace_id — 라인별 entry 우선, 없으면 batch context (spec §4.3).
    trace_id = entry.trace_id or (context.trace_id if context else None)
    if trace_id:
        parts.append(f"[trace:{trace_id}]")
    if context and context.session_id:
        parts.append(f"[sess:{context.session_id[:12]}]")
    if context and context.user_id:
        parts.append(f"[u:{context.user_id[:12]}]")
    # provider 있으면 [u:] 뒤에 [prov:] 토큰 추가 (spec §3.2-a). 없으면 생략(하위호환).
    if context and context.provider:
        parts.append(f"[prov:{context.provider}]")
    if entry.request_id:
        parts.append(f"[rid:{entry.request_id}]")
    if entry.tag:
        parts.append(f"[{entry.tag}]")
    parts.append(entry.message)
    msg = " ".join(parts)

    if entry.data:
        msg += f" | {entry.data}"

    if level == "ERROR":
        log.error(msg)
    elif level == "WARN":
        log.warning(msg)
    elif level == "DEBUG":
        # FE debug 로그도 stdout(docker logs)에 보이게 INFO로 승격하되 [debug] 마커로 구분.
        # uvicorn 로거가 INFO 레벨이라 log.debug면 stdout에서 묻힌다(app_logs에만 남음).
        # debug는 Debug 빌드에서만 전송되므로(Release는 클라이언트가 드롭) 실유저 트래픽엔 안 와
        # prod stdout이 평소 더러워지지 않는다 — dev 디버깅 때만 보인다.
        log.info(f"[debug] {msg}")
    else:
        log.info(msg)
