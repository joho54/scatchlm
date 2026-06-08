"""온보딩 데모 교재 — 유저별 딥카피 (가이드된 첫 성공 spec §4.3 / Track A).

`/feedback`은 textbook_id 소유권을 `user_id`로 검사하므로(feedback.py) 공용/시스템 교재가
불가하다. 그래서 정적 템플릿(앱 이미지에 동봉된 demo-template.pdf + 챕터 상수)을 각 유저에게
**딥카피**해 유저가 소유하는 데모 교재를 만든다.

핵심 불변식:
- textbook_id는 결정적: ``demo-{user_id}`` (iOS가 세션 user id로 동일 규칙 계산 → 조회 불필요).
- ``ensure_demo_textbook``은 **idempotent**: 이미 있으면 no-op. 두 곳(프로비저닝 훅 + 온보딩
  진입의 사실상 동일 훅)에서 안전하게 반복 호출된다.
- 프로비저닝 훅에서 best-effort로만 호출(auth.py) — 실패해도 인증/유저생성은 절대 안 깨진다.
"""
from __future__ import annotations

import hashlib
import logging
import os

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.chapter import Chapter
from app.models.textbook import TextbookSource
from app.services.storage import storage

log = logging.getLogger(__name__)

# 정적 템플릿(소유자 없는 에셋). 앱 이미지에 동봉 — 별도 storage 사전 업로드 불필요.
# scripts/gen_demo_textbook.py 로 생성. 텍스트 레이어 PDF(스캔본 아님).
_TEMPLATE_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "assets", "demo-template.pdf")

DEMO_FILE_NAME = "ScatchLM 데모 교재.pdf"
DEMO_CHAPTER_TITLE = "Beginner English"
DEMO_TOTAL_PAGES = 2
_STORAGE_RETRY = 3


def demo_textbook_id(user_id: str) -> str:
    """유저의 데모 교재 결정적 id. iOS와 공유하는 규칙."""
    return f"demo-{user_id}"


def _read_template_bytes() -> bytes:
    with open(_TEMPLATE_PATH, "rb") as f:
        return f.read()


def _copy_template_to_storage(key: str, data: bytes) -> None:
    """스토리지 transient 대비 소폭 retry. 마지막 시도 실패는 예외 전파(호출부가 best-effort 처리)."""
    last: Exception | None = None
    for attempt in range(_STORAGE_RETRY):
        try:
            storage.save(key, data)
            return
        except Exception as e:  # noqa: BLE001 — transient I/O 재시도
            last = e
            log.warning("demo textbook storage copy failed (attempt %d/%d): %s", attempt + 1, _STORAGE_RETRY, e)
    assert last is not None
    raise last


async def ensure_demo_textbook(user_id: str, db: AsyncSession) -> str:
    """유저의 데모 교재 딥카피를 idempotent하게 보장하고 textbook_id를 반환한다.

    이미 있으면 no-op로 즉시 반환. 없으면 템플릿 PDF를 유저 소유 storage key로 복사하고
    textbook_sources + chapters(1개)를 INSERT한다. 동시 호출 경합은 PK 충돌을
    IntegrityError로 흡수(역시 idempotent).
    """
    tid = demo_textbook_id(user_id)

    existing = await db.execute(select(TextbookSource.id).where(TextbookSource.id == tid))
    if existing.scalar_one_or_none() is not None:
        return tid

    data = _read_template_bytes()
    key = f"{user_id}_demo.pdf"
    _copy_template_to_storage(key, data)

    db.add(TextbookSource(
        id=tid,
        user_id=user_id,
        file_name=DEMO_FILE_NAME,
        server_path=key,
        total_pages=DEMO_TOTAL_PAGES,
        file_size=len(data),
        content_hash=hashlib.sha256(data).hexdigest(),
        is_scanned=False,
        scan_evaluated=True,  # 텍스트 PDF — 재평가 불필요(textbook.py:34)
    ))
    db.add(Chapter(
        id=f"{tid}-ch1",
        textbook_id=tid,
        level=1,
        title=DEMO_CHAPTER_TITLE,
        page_start=1,
        page_end=DEMO_TOTAL_PAGES,
    ))

    try:
        await db.commit()
        log.info("Demo textbook created: %s", tid)
    except IntegrityError:
        # 다른 요청이 먼저 만들었다(경합). idempotent — 성공으로 취급.
        await db.rollback()
        log.info("Demo textbook already created concurrently: %s", tid)
    return tid
