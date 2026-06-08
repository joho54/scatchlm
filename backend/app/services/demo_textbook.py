"""온보딩 데모 교재 — 유저별 딥카피 (가이드된 첫 성공 spec §4.3 / Track A).

`/feedback`은 textbook_id 소유권을 `user_id`로 검사하므로(feedback.py) 공용/시스템 교재가
불가하다. 그래서 정적 템플릿(앱 이미지에 동봉된 demo-template.pdf)을 각 유저에게 **딥카피**해
유저가 소유하는 데모 교재를 만든다.

핵심 불변식:
- textbook_id는 결정적: ``demo-{user_id}`` (iOS가 세션 user id로 동일 규칙 계산 → 조회 불필요).
- ``ensure_demo_textbook``은 **idempotent + 생성 시점 동결(create-once)**:
  - 사본이 없으면 만든다(생성 시점 템플릿으로).
  - 사본이 이미 있으면 **무조건 no-op** — 템플릿이 나중에 바뀌어도 기존 사본은 갱신하지 않는다.
  - 의도: 클라이언트 PDF 캐시(`pdf_<textbookId>.pdf`, 캐시 우선)와 BE 사본이 **항상 동일본**이라
    데모 중 "보이는 문제 ≠ 피드백 근거" 불일치가 원천 차단된다. 교체는 **신규 유저에게만** 반영.
- 프로비저닝 훅에서 best-effort로만 호출(auth.py) — 실패해도 인증/유저생성은 절대 안 깨진다.

데모 PDF 교체(플레이스홀더 → 정식):
- `backend/app/assets/demo-template.pdf` 와 `ios-app/ScatchLM/Resources/demo-template.pdf` 를
  같은 PDF로 덮어쓰고 배포한다. 파일명·경로 고정 — 코드 변경 불필요. 페이지 수는 PDF에서 자동 추출.
- **이미 사본이 있는 유저는 갱신되지 않는다.** 강제 반영하려면 그 유저의 `demo-{user_id}` row와
  `{user_id}_demo.pdf` 파일을 지운 뒤 다음 요청을 받게 한다(재생성됨).
"""
from __future__ import annotations

import hashlib
import logging
import os

import fitz  # PyMuPDF — 페이지 수 추출
from sqlalchemy import select
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
    """유저의 데모 교재 딥카피를 idempotent하게 보장하고 textbook_id를 반환한다(create-once).

    이미 있으면 **무조건 no-op** — 템플릿이 나중에 바뀌어도 기존 사본은 동결(클라 캐시와 항상 일치).
    """
    tid = demo_textbook_id(user_id)

    existing = await db.execute(select(TextbookSource.id).where(TextbookSource.id == tid))
    if existing.scalar_one_or_none() is not None:
        return tid  # 동결 — 갱신하지 않음

    data, digest, pages = _template()
    key = f"{user_id}_demo.pdf"
    _copy_template_to_storage(key, data)

    try:
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
        log.info("Demo textbook created: %s (pages=%d)", tid, pages)
    except IntegrityError:
        # 다른 요청이 먼저 만들었다(PK 경합). idempotent — 성공으로 취급.
        await db.rollback()
        log.info("Demo textbook already created concurrently: %s", tid)
    return tid
