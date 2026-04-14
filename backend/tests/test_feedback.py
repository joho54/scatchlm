import io
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient

from app.services.feedback_service import FeedbackResult

MOCK_RESULT = FeedbackResult(
    data={
        "recognized_text": "こんにちは",
        "corrections": [
            {"position": 1, "original": "こんにちわ", "corrected": "こんにちは", "reason": "助詞の誤り"}
        ],
        "summary": "1/1 오답. 인사말 표기를 복습하세요.",
    },
    model="claude-sonnet-4-6-20250514",
    input_tokens=800,
    output_tokens=150,
    total_tokens=950,
    cost_usd=0.00465,
    latency_ms=2340,
)


@pytest.mark.asyncio
async def test_feedback_success(client: AsyncClient, auth_header: dict):
    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=MOCK_RESULT,
    ):
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={"note_id": "note-1", "language": "ja", "task_type": "complex"},
        )
    assert res.status_code == 200
    data = res.json()
    assert data["recognized_text"] == "こんにちは"
    assert len(data["corrections"]) == 1
    assert "오답" in data["summary"]


@pytest.mark.asyncio
async def test_feedback_empty_image(client: AsyncClient, auth_header: dict):
    res = await client.post(
        "/api/feedback",
        headers=auth_header,
        files={"image": ("empty.png", io.BytesIO(b""), "image/png")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_feedback_requires_auth(client: AsyncClient):
    res = await client.post(
        "/api/feedback",
        files={"image": ("canvas.png", io.BytesIO(b"\x89PNG"), "image/png")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_feedback_with_textbook_context(client: AsyncClient, auth_header: dict):
    """교재 컨텍스트와 함께 피드백 요청."""
    import fitz

    doc = fitz.open()
    page = doc.new_page()
    page.insert_text((72, 72), "Lesson 24 vocabulary")
    pdf_bytes = doc.tobytes()
    doc.close()

    upload_res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("textbook.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    textbook_id = upload_res.json()["id"]

    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=MOCK_RESULT,
    ) as mock_fn:
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={
                "note_id": "note-1",
                "language": "ja",
                "textbook_id": textbook_id,
                "page_start": "1",
                "page_end": "1",
            },
        )
    assert res.status_code == 200
    call_kwargs = mock_fn.call_args.kwargs
    assert call_kwargs["textbook_context"] is not None
    assert "Lesson 24" in call_kwargs["textbook_context"]


@pytest.mark.asyncio
async def test_feedback_records_usage(client: AsyncClient, auth_header: dict):
    """피드백 성공 시 llm_usage 테이블에 기록되는지 확인."""
    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=MOCK_RESULT,
    ):
        await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={"note_id": "note-1", "language": "ja"},
        )

    # admin 엔드포인트로 usage 확인 (인증 필요)
    res = await client.get("/api/admin/usage?days=1", headers=auth_header)
    assert res.status_code == 200
    data = res.json()
    assert data["summary"]["total_requests"] >= 1
    assert data["summary"]["total_tokens"] >= 950
