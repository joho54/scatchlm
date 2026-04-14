"""RAG 인덱싱 + 검색 테스트."""
import io
from unittest.mock import AsyncMock, patch, MagicMock

import pytest
from httpx import AsyncClient

from app.services.embedding_service import chunk_text_by_pages


# ── 청킹 단위 테스트 ──

def test_chunk_single_page():
    pages = [(1, "Hello world.\n\nThis is a test paragraph.")]
    chunks = chunk_text_by_pages(pages)
    assert len(chunks) == 1
    assert chunks[0]["page_start"] == 1
    assert chunks[0]["page_end"] == 1
    assert "Hello world" in chunks[0]["content"]


def test_chunk_multiple_pages():
    pages = [
        (1, "Page one content.\n\nMore content on page one."),
        (2, "Page two content.\n\nMore content on page two."),
        (3, "Page three content."),
    ]
    chunks = chunk_text_by_pages(pages)
    assert len(chunks) >= 1
    assert chunks[0]["page_start"] == 1
    assert chunks[-1]["page_end"] == 3


def test_chunk_splits_long_text():
    long_para = "A" * 1500
    pages = [(1, f"{long_para}\n\n{long_para}\n\n{long_para}")]
    chunks = chunk_text_by_pages(pages)
    assert len(chunks) >= 2


def test_chunk_empty_pages():
    pages = [(1, ""), (2, "   \n\n  ")]
    chunks = chunk_text_by_pages(pages)
    assert len(chunks) == 0


# ── PDF 업로드 시 인덱싱 트리거 테스트 ──

@pytest.mark.asyncio
async def test_upload_triggers_indexing(client: AsyncClient, auth_header: dict):
    """PDF 업로드 응답에 indexing 상태가 포함되는지 확인."""
    import fitz

    doc = fitz.open()
    page = doc.new_page()
    page.insert_text((72, 72), "Lesson 24 vocabulary practice")
    pdf_bytes = doc.tobytes()
    doc.close()

    with patch("app.routers.pdf._background_index", new_callable=AsyncMock):
        res = await client.post(
            "/api/pdf/upload",
            headers=auth_header,
            files={"file": ("textbook.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
            data={"note_id": "note-1"},
        )

    assert res.status_code == 200
    data = res.json()
    assert data["indexing"] == "started"


# ── RAG 자동 검색 피드백 테스트 ──

@pytest.mark.asyncio
async def test_feedback_with_rag_auto_search(client: AsyncClient, auth_header: dict):
    """textbook_id만 있고 page_start/page_end 없으면 RAG 자동 검색."""
    import fitz

    # PDF 업로드
    doc = fitz.open()
    page = doc.new_page()
    page.insert_text((72, 72), "Lesson 24: important vocabulary")
    pdf_bytes = doc.tobytes()
    doc.close()

    with patch("app.routers.pdf._background_index", new_callable=AsyncMock):
        upload_res = await client.post(
            "/api/pdf/upload",
            headers=auth_header,
            files={"file": ("textbook.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
            data={"note_id": "note-1"},
        )
    textbook_id = upload_res.json()["id"]

    from app.services.feedback_service import FeedbackResult

    mock_result = FeedbackResult(
        data={
            "recognized_text": "vocabulary test",
            "corrections": [],
            "summary": "잘 했습니다.",
        },
        model="claude-sonnet-4-6",
        input_tokens=500,
        output_tokens=100,
        total_tokens=600,
        cost_usd=0.003,
        latency_ms=1500,
    )

    with patch(
        "app.routers.feedback.get_recognition",
        new_callable=AsyncMock,
        return_value="vocabulary test",
    ), patch(
        "app.routers.feedback.search_relevant_chunks",
        new_callable=AsyncMock,
        return_value=[],  # 아직 인덱싱 안 됐으므로 빈 결과
    ), patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=mock_result,
    ) as mock_feedback:
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={
                "note_id": "note-1",
                "textbook_id": textbook_id,
                # page_start/page_end 없음 → RAG 자동 검색
            },
        )

    assert res.status_code == 200
    assert res.json()["recognized_text"] == "vocabulary test"
