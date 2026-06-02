import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Request
from pydantic import BaseModel

log = logging.getLogger("fe")

router = APIRouter(prefix="/api/dev", tags=["devlog"])


class LogEntry(BaseModel):
    level: str = "info"
    tag: str = ""
    message: str
    data: dict | None = None
    # `ts`(신규) 또는 `timestamp`(레거시) 모두 수용.
    ts: str | None = None
    timestamp: str | None = None
    request_id: str | None = None


class LogContext(BaseModel):
    user_id: str | None = None
    app_version: str | None = None
    build: str | None = None
    os_version: str | None = None
    device_model: str | None = None
    locale: str | None = None
    session_id: str | None = None


class LogBatch(BaseModel):
    logs: list[LogEntry]
    context: LogContext | None = None  # optional — 하위호환


@router.post("/log")
async def receive_log(entry: LogEntry):
    _emit(entry, None)
    return {"ok": True}


@router.post("/log/batch")
async def receive_log_batch(batch: LogBatch):
    for entry in batch.logs:
        _emit(entry, batch.context)
    return {"received": len(batch.logs)}


def _emit(entry: LogEntry, context: "LogContext | None"):
    level = entry.level.upper()
    ts = entry.ts or entry.timestamp or datetime.now(timezone.utc).isoformat()
    parts = [f"[FE {ts}]"]
    if context and context.session_id:
        parts.append(f"[sess:{context.session_id[:8]}]")
    if context and context.user_id:
        parts.append(f"[u:{context.user_id[:8]}]")
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
        log.debug(msg)
    else:
        log.info(msg)
