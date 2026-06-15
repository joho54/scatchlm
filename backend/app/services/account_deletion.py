"""계정 삭제 로직 (L1 / Track A-1).

순서가 중요하다:
  1. blob 키 수집(텍스트북 server_path) — 행 삭제 전에 모아둔다.
  2. **단일 DB 트랜잭션**으로 모든 테이블 행 삭제 → 커밋(router가 수행).
  3. 커밋 후 blob 삭제(드로잉 prefix + PDF).
  4. 마지막에 Supabase auth 유저 삭제(service-role, 재시도 가능하게 맨 끝).

FK cascade 혼재(§1.2): sync 4테이블·textbook_sources는 users FK가 있어 users보다 먼저
삭제해야 하고, ai_response/llm_usage 등은 FK가 없어 user_id로 명시 삭제한다.
"""
from __future__ import annotations

import logging

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.feedback import AIResponse, AIResponseRating
from app.models.sync import (
    ChatMessage,
    ChatSession,
    Feedback,
    Folder,
    Note,
    NotePage,
    PdfAnnotation,
)
from app.models.textbook import TextbookSource
from app.models.usage import LLMUsage
from app.models.user import User
from app.services.storage import storage

log = logging.getLogger(__name__)


async def collect_blob_keys(user_id: str, db: AsyncSession) -> list[str]:
    """삭제 대상 blob 키(텍스트북 PDF server_path)를 행 삭제 전에 수집한다."""
    result = await db.execute(
        select(TextbookSource.server_path).where(TextbookSource.user_id == user_id)
    )
    return [row[0] for row in result.all() if row[0]]


async def delete_db_rows(user_id: str, db: AsyncSession) -> dict[str, int]:
    """user_id의 모든 DB 행을 삭제한다. **커밋은 호출자(router)가 수행** — 부분 실패 시 롤백.

    textbook_sources 삭제는 FK cascade로 document_chunks·chapters·page_guides를 함께 지운다.
    """
    counts: dict[str, int] = {}

    async def _del(model, label: str) -> None:
        res = await db.execute(delete(model).where(model.user_id == user_id))
        counts[label] = res.rowcount or 0

    # 자식·무FK 테이블 먼저. users.id를 FK로 참조하는 테이블은 users 삭제 전에 모두 비워야
    # 한다(ON DELETE CASCADE 미설정 — 하나라도 행이 남으면 DELETE users가 FK 위반).
    await _del(NotePage, "note_pages")
    await _del(PdfAnnotation, "pdf_annotations")
    await _del(Feedback, "feedbacks")
    await _del(ChatMessage, "chat_messages")
    await _del(ChatSession, "chat_sessions")
    await _del(Note, "notes")
    await _del(Folder, "folders")
    await _del(AIResponseRating, "ai_response_rating")
    await _del(AIResponse, "ai_response")
    await _del(LLMUsage, "llm_usage")
    # textbook_sources → FK cascade(document_chunks·chapters·page_guides)
    await _del(TextbookSource, "textbook_sources")
    # 마지막으로 users (PK는 id — user_id 컬럼 없음)
    users_res = await db.execute(delete(User).where(User.id == user_id))
    counts["users"] = users_res.rowcount or 0

    return counts


def delete_blobs(user_id: str, blob_keys: list[str]) -> tuple[int, list[str]]:
    """커밋 후 blob 삭제: 드로잉(sync/{user_id}/*) prefix + 텍스트북 PDF.

    반환: (삭제 성공 개수, 실패한 키/prefix 목록). 실패를 **삼키지 않고** 호출자에 보고해
    "삭제 완료"로 거짓 보고되는 것을 막는다(개인정보 삭제 완전성). 이미 없는 키(FileNotFound)는
    멱등적으로 성공 취급한다.
    """
    count = 0
    failures: list[str] = []
    try:
        count += storage.delete_prefix(f"sync/{user_id}/")
    except Exception:
        # prefix 삭제 한 번의 실패 = 해당 유저 드로잉 전체 잔존 → 반드시 보고.
        log.exception("blob prefix delete failed: user=%s", user_id)
        failures.append(f"sync/{user_id}/*")
    for key in blob_keys:
        try:
            storage.delete(key)
            count += 1
        except FileNotFoundError:
            count += 1  # 이미 없음 — 멱등 성공
        except Exception:
            log.exception("blob delete failed: user=%s key=%s", user_id, key)
            failures.append(key)
    return count, failures
