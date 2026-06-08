"""온보딩 데모 교재 딥카피(ensure_demo_textbook) 테스트 — 가이드된 첫 성공 spec §4.3."""
import io
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.models.chapter import Chapter
from app.models.textbook import TextbookSource
from app.models.user import User
from app.services.demo_textbook import demo_textbook_id, ensure_demo_textbook
from app.services.storage import storage
from tests.conftest import TEST_USER_ID

pytestmark = pytest.mark.asyncio

_UID = "demo-test-user-0000-0000"


async def _seed_user(db) -> None:
    db.add(User(id=_UID, email="demo@scatchlm.com"))
    await db.commit()


async def test_ensure_creates_textbook_and_chapter(db_session):
    await _seed_user(db_session)

    tid = await ensure_demo_textbook(_UID, db_session)
    assert tid == demo_textbook_id(_UID) == f"demo-{_UID}"

    tb = (await db_session.execute(
        select(TextbookSource).where(TextbookSource.id == tid)
    )).scalar_one()
    assert tb.user_id == _UID
    assert tb.total_pages == 2
    assert tb.is_scanned is False
    assert tb.scan_evaluated is True

    # 파일이 유저 소유 key로 복사됐고 PDF 바이트가 실재한다.
    assert tb.server_path == f"{_UID}_demo.pdf"
    data = storage.read(tb.server_path)
    assert data[:4] == b"%PDF"

    # 챕터 1개(전체 페이지 범위)가 생성됐다 → current_page 컨텍스트 주입 가능.
    ch = (await db_session.execute(
        select(Chapter).where(Chapter.textbook_id == tid)
    )).scalars().all()
    assert len(ch) == 1
    assert ch[0].level == 1
    assert ch[0].page_start == 1
    assert ch[0].page_end == 2


async def test_ensure_is_idempotent(db_session):
    await _seed_user(db_session)

    tid1 = await ensure_demo_textbook(_UID, db_session)
    tid2 = await ensure_demo_textbook(_UID, db_session)
    assert tid1 == tid2

    # 중복 row가 없다 — 정확히 1 textbook + 1 chapter.
    tbs = (await db_session.execute(
        select(TextbookSource).where(TextbookSource.id == tid1)
    )).scalars().all()
    assert len(tbs) == 1
    chs = (await db_session.execute(
        select(Chapter).where(Chapter.textbook_id == tid1)
    )).scalars().all()
    assert len(chs) == 1


# --- 프로비저닝 훅 통합 (auth.py:_ensure_user_exists) ---

async def test_authenticated_request_ensures_demo_textbook(client: AsyncClient, auth_header: dict, db_session):
    """인증된 요청 한 번이면 프로비저닝 훅이 데모 교재를 보장한다(백스톱 겸용)."""
    res = await client.post(
        "/api/feedback",
        headers=auth_header,
        files={"image": ("c.png", io.BytesIO(b""), "image/png")},
        data={"note_id": "n1"},
    )
    assert res.status_code == 400  # 인증 통과(빈 이미지 400)

    tid = demo_textbook_id(TEST_USER_ID)
    tb = (await db_session.execute(
        select(TextbookSource).where(TextbookSource.id == tid)
    )).scalar_one_or_none()
    assert tb is not None and tb.user_id == TEST_USER_ID


async def test_ensure_failure_does_not_block_auth(client: AsyncClient, auth_header: dict):
    """데모 교재 보장이 실패해도 인증/요청 처리는 절대 차단되지 않는다(best-effort)."""
    with patch(
        "app.services.demo_textbook.ensure_demo_textbook",
        new_callable=AsyncMock,
        side_effect=RuntimeError("storage down"),
    ):
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("c.png", io.BytesIO(b""), "image/png")},
            data={"note_id": "n1"},
        )
    # 500이 아니라 인증 통과 후 빈 이미지 400 — 훅 실패가 요청을 죽이지 않음.
    assert res.status_code == 400
