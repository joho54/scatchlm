import io
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
