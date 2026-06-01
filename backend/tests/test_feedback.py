import io
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient

from app.services.feedback_service import FeedbackResult

MOCK_RESULT = FeedbackResult(
    data={
        "type": "feedback",
        "content": "こんにちわ → こんにちは (助詞の誤り). 인사말 표기에 주의하세요.\n\n1/1 오답. 인사말 표기를 복습하세요.",
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
    assert "content" in data
    assert "こんにちは" in data["content"]


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
async def test_feedback_with_overlapping_chapters_picks_narrowest(
    client: AsyncClient, auth_header: dict, db_session
):
    """계층형 TOC: 한 페이지가 여러 챕터에 속해도 500 없이 가장 좁은 챕터를 고른다.

    회귀: scalar_one_or_none()이 MultipleResultsFound로 터지던 버그(feedback.py).
    """
    import fitz

    from app.models.chapter import Chapter

    doc = fitz.open()
    for _ in range(3):
        doc.new_page()
    page = doc[1]  # 2페이지(인덱스 1)에 텍스트
    page.insert_text((72, 72), "Keys section content")
    pdf_bytes = doc.tobytes()
    doc.close()

    upload_res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("textbook.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    textbook_id = upload_res.json()["id"]

    # 2페이지를 동시에 포함하는 중첩 챕터 3개 (PART > Chapter > Section)
    db_session.add_all([
        Chapter(id="ch-part", textbook_id=textbook_id, level=1, title="PART ONE", page_start=1, page_end=3),
        Chapter(id="ch-2", textbook_id=textbook_id, level=2, title="Chapter 2", page_start=1, page_end=2),
        Chapter(id="ch-23", textbook_id=textbook_id, level=3, title="2.3 Keys", page_start=2, page_end=2),
    ])
    await db_session.commit()

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
                "textbook_id": textbook_id,
                "current_page": "2",
            },
        )
    assert res.status_code == 200
    # 가장 좁은 챕터(2.3 Keys)가 컨텍스트로 선택됐는지 확인
    ctx = mock_fn.call_args.kwargs["textbook_context"]
    assert ctx is not None
    assert "2.3 Keys" in ctx


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
async def test_feedback_chat_returns_feedback_id_and_is_rateable(client: AsyncClient, auth_header: dict):
    """채팅 응답이 AIResponse로 적재되어 /feedback/{id}/rate 로 평가 가능해야 한다."""
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="assistant reply for rating")]
    mock_response.usage = AsyncMock(input_tokens=100, output_tokens=20)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        chat_res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={"message": "hi", "history": [], "response_language": "Korean"},
        )

    assert chat_res.status_code == 200
    chat_id = chat_res.json().get("feedback_id")
    assert isinstance(chat_id, str) and len(chat_id) > 0

    rate_res = await client.post(
        f"/api/feedback/{chat_id}/rate",
        headers=auth_header,
        json={"rating": 1, "reason_tags": []},
    )
    assert rate_res.status_code == 204


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
