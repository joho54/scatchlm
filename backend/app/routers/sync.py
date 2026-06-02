"""델타 동기화 엔드포인트 — pull / push / blob.

cloud-data-sync-spec §3.2 계약 준수. 모든 엔드포인트는 get_current_user_id로
인증하고 user_id 스코프를 강제한다. A-3 / A-5 참조.
"""
import logging
import os

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.services import sync as sync_service
from app.services.storage import storage

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api/sync", tags=["sync"])


class Changes(BaseModel):
    notes: list[dict] = Field(default_factory=list)
    note_pages: list[dict] = Field(default_factory=list)
    feedbacks: list[dict] = Field(default_factory=list)
    chat_messages: list[dict] = Field(default_factory=list)


class PullRequest(BaseModel):
    since: str | None = None
    limit: int = sync_service.DEFAULT_LIMIT


class PushRequest(BaseModel):
    changes: Changes


@router.post("/pull")
async def pull(
    req: PullRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await sync_service.pull_changes(db, user_id, req.since, req.limit)
    except ValueError as e:
        log.warning("sync pull bad since: user=%s err=%s", user_id, e)
        raise HTTPException(status_code=400, detail=f"Invalid since cursor: {e}")
    total = sum(len(v) for v in result["changes"].values())
    log.info("sync pull: user=%s since=%s returned=%d has_more=%s",
             user_id, req.since, total, result["has_more"])
    return result


@router.post("/push")
async def push(
    req: PushRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await sync_service.push_changes(db, user_id, req.changes.model_dump())
    except ValueError as e:
        log.warning("sync push bad payload: user=%s err=%s", user_id, e)
        raise HTTPException(status_code=400, detail=str(e))
    applied = sum(1 for r in result["results"] if r["status"] == "applied")
    log.info("sync push: user=%s applied=%d/%d missing_blobs=%d",
             user_id, applied, len(result["results"]), len(result["missing_blobs"]))
    return result


@router.post("/blob")
async def upload_blob(
    hash: str = Form(...),
    file: UploadFile = File(...),
    user_id: str = Depends(get_current_user_id),
):
    data = await file.read()
    try:
        stored = sync_service.store_blob(user_id, hash, data)
    except ValueError as e:
        log.warning("sync blob hash mismatch: user=%s err=%s", user_id, e)
        raise HTTPException(status_code=400, detail=str(e))
    log.info("sync blob stored: user=%s hash=%s bytes=%d", user_id, hash[:12], len(data))
    return {"hash": hash, "stored": stored}


@router.get("/blob/{hash}")
async def download_blob(
    hash: str,
    token: str | None = None,
    user_id: str = Depends(get_current_user_id),
):
    key = sync_service.blob_storage_key(user_id, hash)
    local = storage.local_path(key)
    if local and os.path.exists(local):
        return FileResponse(local, media_type="application/octet-stream")
    try:
        return StreamingResponse(storage.stream(key), media_type="application/octet-stream")
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Blob not found")
    except Exception as e:
        # S3 미보유 등
        log.info("sync blob not found: user=%s hash=%s err=%s", user_id, hash[:12], e)
        raise HTTPException(status_code=404, detail="Blob not found")
