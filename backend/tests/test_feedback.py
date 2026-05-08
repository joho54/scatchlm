import io
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient

from app.services.feedback_service import FeedbackResult

MOCK_RESULT = FeedbackResult(
    data={
        "type": "feedback",
        "recognized_text": "こんにちは",
        "feedback": "こんにちわ → こんにちは (助詞の誤り). 인사말 표기에 주의하세요.",
        "summary": "1/1 오답. 인사말 표기를 복습하세요.",
    },
    model="claude-sonnet-4-6",
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
    assert data["type"] == "feedback"
    assert data["recognized_text"] == "こんにちは"
    assert "こんにちは" in data["feedback"]
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


@pytest.mark.asyncio
async def test_feedback_chat_success(client: AsyncClient, auth_header: dict):
    """피드백 채팅이 LLM 응답을 반환하는지 확인."""
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="완료형은 과거의 행동이 현재까지 영향을 미침을 나타냅니다.")]
    mock_response.usage = AsyncMock(input_tokens=500, output_tokens=50)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={
                "message": "완료형이 뭐야?",
                "history": [],
                "response_language": "Korean",
            },
        )

    assert res.status_code == 200
    data = res.json()
    assert "content" in data
    assert len(data["content"]) > 0


@pytest.mark.asyncio
async def test_feedback_chat_requires_auth(client: AsyncClient):
    """인증 없이 채팅 요청 시 401 반환."""
    res = await client.post(
        "/api/feedback/chat",
        json={"message": "test"},
    )
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_feedback_chat_with_response_language(client: AsyncClient, auth_header: dict):
    """response_language가 시스템 프롬프트에 반영되는지 확인."""
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="test response")]
    mock_response.usage = AsyncMock(input_tokens=100, output_tokens=20)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={
                "message": "explain this",
                "history": [],
                "response_language": "Japanese",
            },
        )

    assert res.status_code == 200
    # system prompt에 Japanese가 포함되었는지 확인
    call_kwargs = mock_client.messages.create.call_args.kwargs
    assert "Japanese" in call_kwargs["system"]
