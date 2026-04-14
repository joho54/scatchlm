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
    timestamp: str | None = None


class LogBatch(BaseModel):
    logs: list[LogEntry]


@router.post("/log")
async def receive_log(entry: LogEntry):
    _emit(entry)
    return {"ok": True}


@router.post("/log/batch")
async def receive_log_batch(batch: LogBatch):
    for entry in batch.logs:
        _emit(entry)
    return {"ok": True, "count": len(batch.logs)}


def _emit(entry: LogEntry):
    level = entry.level.upper()
    ts = entry.timestamp or datetime.now(timezone.utc).isoformat()
    prefix = f"[FE {ts}]"
    tag = f"[{entry.tag}]" if entry.tag else ""
    msg = f"{prefix} {tag} {entry.message}"

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
