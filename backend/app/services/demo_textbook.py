"""온보딩 데모 교재 — 유저별 딥카피 (가이드된 첫 성공 spec §4.3 / Track A).

`/feedback`은 textbook_id 소유권을 `user_id`로 검사하므로(feedback.py) 공용/시스템 교재가
불가하다. 그래서 정적 템플릿(앱 이미지에 동봉된 demo-template.pdf)을 각 유저에게 **딥카피**해
유저가 소유하는 데모 교재를 만든다.

핵심 불변식:
- textbook_id는 결정적: ``demo-{user_id}`` (iOS가 세션 user id로 동일 규칙 계산 → 조회 불필요).
- ``ensure_demo_textbook``은 **idempotent + 콘텐츠 인지**:
  - 사본이 없으면 만든다.
  - 사본이 있고 템플릿 해시가 같으면 no-op.
  - 사본이 있는데 **템플릿이 바뀌면(해시 불일치) 자동 갱신**(파일 재복사 + total_pages/챕터 재생성).
    → `assets/demo-template.pdf`를 새 PDF로 교체하고 재배포하면 각 유저 다음 요청에서 사본이 교체된다.
- 프로비저닝 훅에서 best-effort로만 호출(auth.py) — 실패해도 인증/유저생성은 절대 안 깨진다.

데모 PDF 교체(플레이스홀더 → 정식):
- `backend/app/assets/demo-template.pdf` 와 `ios-app/ScatchLM/Resources/demo-template.pdf` 를
  같은 PDF로 덮어쓰고 배포한다. 파일명·경로 고정 — 코드 변경 불필요. 페이지 수는 PDF에서 자동 추출.
"""
from __future__ import annotations

import hashlib
import logging
import os

import fitz  # PyMuPDF — 페이지 수 추출
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.chapter import Chapter
from app.models.textbook import TextbookSource
from app.services.storage import storage

log = logging.getLogger(__name__)

# 정적 템플릿(소유자 없는 에셋). 앱 이미지에 동봉 — 별도 storage 사전 업로드 불필요.
# scripts/gen_demo_textbook.py 로 생성한 플레이스홀더. 정식 PDF로 덮어쓰면 자동 반영된다.
_TEMPLATE_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "assets", "demo-template.pdf")

DEMO_FILE_NAME = "ScatchLM 데모 교재.pdf"
DEMO_CHAPTER_TITLE = "Demo"
_STORAGE_RETRY = 3

# 템플릿은 런타임에 안 바뀌는 정적 에셋이라 프로세스당 1회만 읽어 캐시한다.
_template_cache: tuple[bytes, str, int] | None = None


def demo_textbook_id(user_id: str) -> str:
    """유저의 데모 교재 결정적 id. iOS와 공유하는 규칙."""
    return f"demo-{user_id}"


def _template() -> tuple[bytes, str, int]:
    """(bytes, sha256, page_count). 프로세스 캐시."""
    global _template_cache
    if _template_cache is None:
        with open(_TEMPLATE_PATH, "rb") as f:
            data = f.read()
        digest = hashlib.sha256(data).hexdigest()
        doc = fitz.open(stream=data, filetype="pdf")
        pages = len(doc)
        doc.close()
        _template_cache = (data, digest, pages)
    return _template_cache


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
    """유저의 데모 교재 딥카피를 idempotent + 콘텐츠 인지로 보장하고 textbook_id를 반환한다."""
    tid = demo_textbook_id(user_id)
    data, digest, pages = _template()

    existing = (await db.execute(
        select(TextbookSource).where(TextbookSource.id == tid)
    )).scalar_one_or_none()

    if existing is not None and existing.content_hash == digest:
        return tid  # 최신 상태 — no-op

    key = f"{user_id}_demo.pdf"
    _copy_template_to_storage(key, data)

    try:
        if existing is None:
            db.add(TextbookSource(
                id=tid,
                user_id=user_id,
                file_name=DEMO_FILE_NAME,
                server_path=key,
                total_pages=pages,
                file_size=len(data),
                content_hash=digest,
                is_scanned=False,
                scan_evaluated=True,  # 텍스트 PDF — 재평가 불필요(textbook.py:34)
            ))
            verb = "created"
        else:
            # 템플릿 교체됨 → 사본 메타 갱신(파일은 같은 key로 위에서 재복사).
            existing.server_path = key
            existing.total_pages = pages
            existing.file_size = len(data)
            existing.content_hash = digest
            existing.file_name = DEMO_FILE_NAME
            await db.execute(delete(Chapter).where(Chapter.textbook_id == tid))
            verb = "refreshed"

        # 부모(textbook_sources)를 자식(chapters)보다 **먼저** flush해 FK를 보장한다.
        # 둘 다 client-set id 문자열이고 relationship()이 없어 UOW가 부모 우선 정렬을 보장하지
        # 않는다 — 운영에서 chapters_textbook_id_fkey 위반으로 매 INSERT가 롤백된 원인.
        await db.flush()
        db.add(Chapter(
            id=f"{tid}-ch1",
            textbook_id=tid,
            level=1,
            title=DEMO_CHAPTER_TITLE,
            page_start=1,
            page_end=pages,
        ))
        await db.commit()
        log.info("Demo textbook %s: %s (pages=%d)", verb, tid, pages)
    except IntegrityError:
        # 다른 요청이 먼저 만들었다(PK 경합). idempotent — 성공으로 취급.
        await db.rollback()
        log.info("Demo textbook already created concurrently: %s", tid)
    return tid
