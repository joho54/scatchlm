import io
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient

from app.services.pdf_service import extract_text


def make_test_pdf() -> bytes:
    """PyMuPDF로 간단한 테스트 PDF를 생성한다."""
    import fitz

    doc = fitz.open()
    for i in range(3):
        page = doc.new_page()
        page.insert_text((72, 72), f"Page {i + 1} content: hello world")
    data = doc.tobytes()
    doc.close()
    return data


@pytest.mark.asyncio
async def test_upload_pdf(client: AsyncClient, auth_header: dict):
    pdf_bytes = make_test_pdf()
    res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("test.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 200
    data = res.json()
    assert data["totalPages"] == 3
    assert data["fileName"] == "test.pdf"
    assert "id" in data


@pytest.mark.asyncio
async def test_upload_non_pdf(client: AsyncClient, auth_header: dict):
    res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("test.txt", io.BytesIO(b"hello"), "text/plain")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_upload_and_extract(client: AsyncClient, auth_header: dict):
    pdf_bytes = make_test_pdf()
    upload_res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("test.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    textbook_id = upload_res.json()["id"]

    res = await client.get(
        "/api/pdf/extract",
        headers=auth_header,
        params={"textbook_id": textbook_id, "page_start": 1, "page_end": 2},
    )
    assert res.status_code == 200
    assert "hello world" in res.json()["text"]


@pytest.mark.asyncio
async def test_extract_invalid_page_range(client: AsyncClient, auth_header: dict):
    pdf_bytes = make_test_pdf()
    upload_res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("test.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    textbook_id = upload_res.json()["id"]

    res = await client.get(
        "/api/pdf/extract",
        headers=auth_header,
        params={"textbook_id": textbook_id, "page_start": 1, "page_end": 10},
    )
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_upload_requires_auth(client: AsyncClient):
    res = await client.post(
        "/api/pdf/upload",
        files={"file": ("test.pdf", io.BytesIO(b"%PDF"), "application/pdf")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 401


MOCK_PAGE_GUIDE = {"topic": "테스트 주제", "content": "테스트 가이드 본문"}


async def _upload_test_pdf(client: AsyncClient, auth_header: dict) -> str:
    # 백그라운드 인덱싱은 테스트 트랜잭션 밖에서 실행돼 FK 위반을 일으키므로 무력화
    with patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_detect_chapters", new_callable=AsyncMock):
        res = await client.post(
            "/api/pdf/upload",
            headers=auth_header,
            files={"file": ("g.pdf", io.BytesIO(make_test_pdf()), "application/pdf")},
            data={"note_id": "note-g"},
        )
    assert res.status_code == 200
    return res.json()["id"]


@pytest.mark.asyncio
async def test_page_guide_returns_feedback_id_cache_miss_then_hit(
    client: AsyncClient, auth_header: dict
):
    """페이지 가이드 응답은 평가 대상 AIResponse id를 반환하고, 캐시 히트 시에도 동일 id."""
    textbook_id = await _upload_test_pdf(client, auth_header)

    with patch(
        "app.routers.pdf.generate_page_guide",
        new_callable=AsyncMock,
        return_value=MOCK_PAGE_GUIDE,
    ):
        miss = await client.get(
            f"/api/pdf/{textbook_id}/guide",
            headers=auth_header,
            params={"page": 1, "response_language": "Korean"},
        )
    assert miss.status_code == 200
    miss_data = miss.json()
    assert miss_data["cached"] is False
    miss_id = miss_data.get("feedback_id")
    assert isinstance(miss_id, str) and len(miss_id) > 0

    # 두 번째 호출은 캐시 히트 — generate_page_guide 호출 없이도 동일 feedback_id 반환
    hit = await client.get(
        f"/api/pdf/{textbook_id}/guide",
        headers=auth_header,
        params={"page": 1, "response_language": "Korean"},
    )
    assert hit.status_code == 200
    hit_data = hit.json()
    assert hit_data["cached"] is True
    assert hit_data["feedback_id"] == miss_id

    # 반환된 id로 평가 가능해야 함
    rate = await client.post(
        f"/api/feedback/{miss_id}/rate",
        headers=auth_header,
        json={"rating": 1, "reason_tags": []},
    )
    assert rate.status_code == 204


@pytest.mark.asyncio
async def test_page_guide_cache_keyed_by_response_language(
    client: AsyncClient, auth_header: dict
):
    """Track H: 캐시 키에 response_language 포함 — 언어 전환 시 stale 가이드 대신 신규 생성."""
    textbook_id = await _upload_test_pdf(client, auth_header)

    with patch(
        "app.routers.pdf.generate_page_guide",
        new_callable=AsyncMock,
        return_value=MOCK_PAGE_GUIDE,
    ) as gen:
        # Korean 최초 → 생성(miss)
        ko_miss = await client.get(
            f"/api/pdf/{textbook_id}/guide", headers=auth_header,
            params={"page": 1, "response_language": "Korean"},
        )
        # Korean 재요청 → 캐시 히트(생성 안 함)
        ko_hit = await client.get(
            f"/api/pdf/{textbook_id}/guide", headers=auth_header,
            params={"page": 1, "response_language": "Korean"},
        )
        # English 요청 → 같은 page지만 언어가 달라 신규 생성(stale Korean 아님)
        en_miss = await client.get(
            f"/api/pdf/{textbook_id}/guide", headers=auth_header,
            params={"page": 1, "response_language": "English"},
        )
        # English 재요청 → 캐시 히트
        en_hit = await client.get(
            f"/api/pdf/{textbook_id}/guide", headers=auth_header,
            params={"page": 1, "response_language": "English"},
        )

    assert ko_miss.json()["cached"] is False
    assert ko_hit.json()["cached"] is True
    assert en_miss.json()["cached"] is False   # 언어 차원이 작동 → 신규 생성
    assert en_hit.json()["cached"] is True
    # 생성은 Korean 1회 + English 1회 = 2회 (언어별 캐시)
    assert gen.await_count == 2


MOCK_CHAPTER_GUIDE = {
    "topic": "ch topic",
    "key_concepts": ["a"],
    "study_order": ["1. read"],
    "common_mistakes": ["x"],
    "summary": "요약",
}


@pytest.mark.asyncio
async def test_chapter_guide_returns_feedback_id_cache_miss_then_hit(
    client: AsyncClient, auth_header: dict, engine
):
    """챕터 가이드도 동일 — feedback_id 반환, 캐시 히트 시 동일 id, 평가 가능."""
    import uuid
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
    from app.models.chapter import Chapter

    textbook_id = await _upload_test_pdf(client, auth_header)
    chapter_id = str(uuid.uuid4())
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with session_factory() as db:
        db.add(Chapter(
            id=chapter_id,
            textbook_id=textbook_id,
            level=1,
            title="Ch 1",
            page_start=1,
            page_end=3,
        ))
        await db.commit()

    with patch(
        "app.routers.pdf.generate_chapter_guide",
        new_callable=AsyncMock,
        return_value=MOCK_CHAPTER_GUIDE,
    ):
        miss = await client.get(
            f"/api/pdf/{textbook_id}/chapter-guide",
            headers=auth_header,
            params={"chapter_id": chapter_id, "response_language": "Korean"},
        )
    assert miss.status_code == 200
    miss_data = miss.json()
    assert miss_data["cached"] is False
    miss_id = miss_data.get("feedback_id")
    assert isinstance(miss_id, str) and len(miss_id) > 0

    hit = await client.get(
        f"/api/pdf/{textbook_id}/chapter-guide",
        headers=auth_header,
        params={"chapter_id": chapter_id, "response_language": "Korean"},
    )
    assert hit.status_code == 200
    hit_data = hit.json()
    assert hit_data["cached"] is True
    assert hit_data["feedback_id"] == miss_id

    rate = await client.post(
        f"/api/feedback/{miss_id}/rate",
        headers=auth_header,
        json={"rating": -1, "reason_tags": ["tone_off"]},
    )
    assert rate.status_code == 204
