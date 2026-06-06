"""델타 동기화 핵심 로직 — pull 쿼리 / push LWW / blob 저장.

cloud-data-sync-spec §3.2 / §4.1 / A-4 참조. 라우터(`routers/sync.py`)에서 호출한다.
"""
from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.sync import Note, NotePage, PdfAnnotation, Feedback, ChatMessage, ChatSession, Folder
from app.services.storage import storage

log = logging.getLogger(__name__)

# 엔티티 키(요청/응답 JSON의 키) → SQLAlchemy 모델
# chat_sessions를 chat_messages/feedbacks보다 앞에 둬 pull/push 적용 순서에서 먼저 처리한다
# (참조 무결성, chapter-chat-drawer-spec §3.2-a / R2). dict 삽입 순서가 곧 적용 순서다.
# folders를 notes보다 앞에 둬 note.folder_id가 가리키는 폴더를 먼저 적용한다
# (참조 무결성, note-folders-spec §3.2-a / R1). FK 강제는 안 하므로 dangling은 허용.
ENTITY_MODELS: dict[str, type] = {
    "sessions": ChatSession,
    "folders": Folder,
    "notes": Note,
    "note_pages": NotePage,
    "pdf_annotations": PdfAnnotation,
    "feedbacks": Feedback,
    "chat_messages": ChatMessage,
}

# 응답 results의 entity 라벨 (단수)
ENTITY_SINGULAR: dict[str, str] = {
    "sessions": "chat_session",
    "folders": "folder",
    "notes": "note",
    "note_pages": "note_page",
    "pdf_annotations": "pdf_annotation",
    "feedbacks": "feedback",
    "chat_messages": "chat_message",
}

# 엔티티별 동기화 필드 (id/user_id/updated_at/deleted 외 본문 필드)
ENTITY_FIELDS: dict[str, list[str]] = {
    "sessions": [
        "kind", "title", "note_id", "textbook_id", "anchor_page",
        "chapter_title", "source_feedback_id", "created_at",
    ],
    "folders": ["name", "sort_order", "created_at"],
    "notes": [
        "title", "language", "folder_id", "textbook_id", "textbook_name", "textbook_pages",
        "last_page", "pdf_open", "current_page_index", "template", "drawing_hash", "created_at",
    ],
    "note_pages": ["note_id", "page_index", "drawing_hash", "created_at"],
    "pdf_annotations": ["note_id", "pdf_page", "drawing_hash", "created_at"],
    "feedbacks": [
        "note_id", "page_id", "content", "position_x", "position_y",
        "bbox_x", "bbox_y", "bbox_width", "bbox_height",
        "stroke_range_start", "stroke_range_end",
        "server_feedback_id", "user_rating", "session_id", "created_at",
    ],
    "chat_messages": [
        "session_id", "feedback_id", "role", "content",
        "server_message_id", "user_rating", "created_at",
    ],
}

# 해당 엔티티에서 blob(drawing_hash)을 참조하는지
ENTITY_BLOB_FIELD: dict[str, str | None] = {
    "sessions": None,
    "folders": None,
    "notes": "drawing_hash",
    "note_pages": "drawing_hash",
    "pdf_annotations": "drawing_hash",
    "feedbacks": None,
    "chat_messages": None,
}

_DATETIME_FIELDS = {"created_at", "updated_at"}
DEFAULT_LIMIT = 500
MAX_LIMIT = 1000


# ---- 직렬화 헬퍼 -------------------------------------------------------------

def _iso(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    # naive(UTC로 저장됨)이면 UTC 가정
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    dt = dt.astimezone(timezone.utc)
    # 항상 밀리초(3자리) + 'Z'로 직렬화한다.
    # Python isoformat()은 마이크로초(6자리)를 내보내는데, iOS ISO8601DateFormatter(
    # .withFractionalSeconds)는 3자리만 파싱하고 6자리엔 nil을 반환한다 → pull 날짜 파싱 실패.
    # ms로 절삭(내림)하면 iOS와 정합하고, 커서 since(>=)도 절대 건너뛰지 않아 안전하다.
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def parse_iso(value: str) -> datetime:
    """iso8601(UTC) 문자열 → naive UTC datetime (DB 저장 형식과 일치)."""
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).replace(tzinfo=None)


def serialize(entity_key: str, row) -> dict:
    out: dict = {
        "id": row.id,
        "updated_at": _iso(row.updated_at),
        "deleted": bool(row.deleted),
    }
    for field in ENTITY_FIELDS[entity_key]:
        val = getattr(row, field)
        if field in _DATETIME_FIELDS:
            val = _iso(val)
        out[field] = val
    return out


# ---- pull -------------------------------------------------------------------

async def pull_changes(
    db: AsyncSession, user_id: str, since: str | None, limit: int
) -> dict:
    """since 커서 이후(>=) 변경분을 엔티티별로 내려준다.

    cursor는 반환된 행들의 max(updated_at). has_more는 limit을 꽉 채운 엔티티가
    하나라도 있고 커서가 since보다 전진했을 때만 True (경계 동일 timestamp 무한루프 방지).
    `since`는 `>=` 비교 + 클라 idempotent upsert로 경계 누락을 막는다(Risk 표).
    """
    limit = max(1, min(limit, MAX_LIMIT))
    since_dt = parse_iso(since) if since else datetime(1970, 1, 1)

    changes: dict[str, list[dict]] = {}
    max_updated: datetime | None = None
    hit_limit = False

    for entity_key, model in ENTITY_MODELS.items():
        result = await db.execute(
            select(model)
            .where(model.user_id == user_id, model.updated_at >= since_dt)
            .order_by(model.updated_at.asc(), model.id.asc())
            .limit(limit)
        )
        rows = result.scalars().all()
        changes[entity_key] = [serialize(entity_key, r) for r in rows]
        if len(rows) == limit:
            hit_limit = True
        for r in rows:
            if max_updated is None or r.updated_at > max_updated:
                max_updated = r.updated_at

    cursor_dt = max_updated if max_updated is not None else since_dt
    has_more = hit_limit and cursor_dt > since_dt

    return {
        "changes": changes,
        "cursor": _iso(cursor_dt),
        "has_more": has_more,
    }


# ---- push -------------------------------------------------------------------

def _blob_key(user_id: str, hash_: str) -> str:
    return f"sync/{user_id}/{hash_}"


def _blob_exists(user_id: str, hash_: str) -> bool:
    try:
        storage.read(_blob_key(user_id, hash_))
        return True
    except Exception:
        return False


async def push_changes(db: AsyncSession, user_id: str, changes: dict) -> dict:
    """클라 dirty 레코드를 LWW로 적용한다.

    incoming.updated_at > server.updated_at 이면 적용, 아니면 conflict.
    drawing_hash가 있으나 서버에 blob이 없으면 missing_blob (적용 보류).
    """
    results: list[dict] = []
    missing_blobs: set[str] = set()

    for entity_key, model in ENTITY_MODELS.items():
        incoming_list = changes.get(entity_key) or []
        singular = ENTITY_SINGULAR[entity_key]
        blob_field = ENTITY_BLOB_FIELD[entity_key]

        for incoming in incoming_list:
            ent_id = incoming.get("id")
            if not ent_id:
                continue
            incoming_updated = parse_iso(incoming["updated_at"])

            # blob 부재 검사 (삭제가 아닌 경우에만 blob 필요)
            if blob_field and not incoming.get("deleted"):
                h = incoming.get(blob_field)
                if h and not _blob_exists(user_id, h):
                    missing_blobs.add(h)
                    results.append({
                        "id": ent_id,
                        "entity": singular,
                        "status": "missing_blob",
                        "server_updated_at": None,
                    })
                    continue

            existing = await db.get(model, ent_id)

            if existing is not None and existing.user_id != user_id:
                # 타 유저 소유 id → 격리. conflict 취급(적용 거부).
                results.append({
                    "id": ent_id,
                    "entity": singular,
                    "status": "conflict",
                    "server_updated_at": _iso(existing.updated_at),
                })
                continue

            if existing is not None and existing.updated_at >= incoming_updated:
                # 서버가 더 최신(또는 동일) → conflict, 클라는 pull로 수용
                results.append({
                    "id": ent_id,
                    "entity": singular,
                    "status": "conflict",
                    "server_updated_at": _iso(existing.updated_at),
                })
                continue

            # 적용 (upsert)
            row = existing or model(id=ent_id, user_id=user_id)
            row.user_id = user_id
            row.updated_at = incoming_updated
            row.deleted = bool(incoming.get("deleted", False))
            for field in ENTITY_FIELDS[entity_key]:
                if field not in incoming:
                    continue
                val = incoming[field]
                if field in _DATETIME_FIELDS and val is not None:
                    val = parse_iso(val)
                setattr(row, field, val)
            if existing is None:
                db.add(row)

            results.append({
                "id": ent_id,
                "entity": singular,
                "status": "applied",
                "server_updated_at": _iso(incoming_updated),
            })

    await db.commit()
    return {"results": results, "missing_blobs": sorted(missing_blobs)}


# ---- blob -------------------------------------------------------------------

def store_blob(user_id: str, hash_: str, data: bytes) -> bool:
    """content-addressed blob 저장. hash != sha256(data)면 ValueError."""
    actual = hashlib.sha256(data).hexdigest()
    if actual != hash_:
        raise ValueError(f"hash mismatch: declared={hash_} actual={actual}")
    storage.save(_blob_key(user_id, hash_), data)
    return True


def blob_storage_key(user_id: str, hash_: str) -> str:
    return _blob_key(user_id, hash_)
