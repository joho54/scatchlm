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
async def test_feedback_forwards_intent(client: AsyncClient, auth_header: dict):
    """intent 파라미터가 get_feedback로 그대로 전달돼야 한다(채점만 하던 단일 모드 분기)."""
    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=MOCK_RESULT,
    ) as mock_fn:
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={"note_id": "note-1", "language": "ja", "intent": "ask"},
        )
    assert res.status_code == 200
    assert mock_fn.call_args.kwargs["intent"] == "ask"


@pytest.mark.asyncio
async def test_feedback_intent_defaults_to_grade(client: AsyncClient, auth_header: dict):
    """intent 미지정 = 채점(grade). 구버전 클라이언트 BC."""
    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=MOCK_RESULT,
    ) as mock_fn:
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={"note_id": "note-1", "language": "ja"},
        )
    assert res.status_code == 200
    assert mock_fn.call_args.kwargs["intent"] == "grade"


@pytest.mark.asyncio
async def test_feedback_invalid_intent_normalized_to_grade(client: AsyncClient, auth_header: dict):
    """깨진/구버전 intent 값은 라우터에서 grade로 정규화 — get_feedback에도 grade가 가야 한다."""
    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=MOCK_RESULT,
    ) as mock_fn:
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={"note_id": "note-1", "language": "ja", "intent": "bogus"},
        )
    assert res.status_code == 200
    assert mock_fn.call_args.kwargs["intent"] == "grade"


@pytest.mark.asyncio
async def test_feedback_persists_intent(client: AsyncClient, auth_header: dict, db_session):
    """피드백 응답 레코드(AIResponse)에 정규화된 intent가 적재돼야 한다(의도 분포 분석 backbone)."""
    from sqlalchemy import select
    from app.models.feedback import AIResponse

    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=MOCK_RESULT,
    ):
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={"note_id": "note-intent", "language": "ja", "intent": "hint"},
        )
    assert res.status_code == 200
    feedback_id = res.json()["feedback_id"]
    record = (await db_session.execute(
        select(AIResponse).where(AIResponse.id == feedback_id)
    )).scalar_one()
    assert record.intent == "hint"


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
async def test_feedback_records_usage(client: AsyncClient, auth_header: dict, admin_header: dict):
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

    # admin 엔드포인트로 usage 확인 (admin role 필요 — A-3)
    res = await client.get("/api/admin/usage?days=1", headers=admin_header)
    assert res.status_code == 200
    data = res.json()
    assert data["summary"]["total_requests"] >= 1
    assert data["summary"]["total_tokens"] >= 950


@pytest.mark.asyncio
async def test_feedback_chat_success(client: AsyncClient, auth_header: dict):
    """피드백 채팅이 LLM 응답을 반환하는지 확인."""
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="완료형은 과거의 행동이 현재까지 영향을 미침을 나타냅니다.")]
    mock_response.usage = AsyncMock(input_tokens=500, output_tokens=50,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

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
async def test_feedback_chat_injects_selected_text(client: AsyncClient, auth_header: dict):
    """라이브 모드 '선택 질문'이 보낸 selected_text가 system 프롬프트에 주입되는지.

    회귀: 선택 구절을 "이 부분"의 실체로 SELECTED PASSAGE 블록에 담아 보내지 않으면,
    모델이 챕터 전체만 보고 사용자가 짚은 구절을 특정하지 못한다.
    """
    passage = "Gallia est omnis divisa in partes tres"
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="이 문장은 갈리아가 세 부분으로 나뉜다는 뜻입니다.")]
    mock_response.usage = AsyncMock(input_tokens=500, output_tokens=50,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={
                "message": "선택한 부분을 설명해줘",
                "history": [],
                "response_language": "Korean",
                "selected_text": passage,
            },
        )

    assert res.status_code == 200
    # system 블록에 SELECTED PASSAGE 라벨과 선택 구절이 그대로 실려야 한다.
    system_blocks = mock_client.messages.create.call_args.kwargs["system"]
    system_text = "\n".join(b["text"] for b in system_blocks)
    assert "SELECTED PASSAGE" in system_text
    assert passage in system_text


@pytest.mark.asyncio
async def test_feedback_chat_omits_selected_passage_when_absent(client: AsyncClient, auth_header: dict):
    """selected_text가 없으면 SELECTED PASSAGE 블록도 없어야 한다(일반 채팅 경로 무회귀)."""
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="답변")]
    mock_response.usage = AsyncMock(input_tokens=500, output_tokens=50,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={"message": "안녕", "history": [], "response_language": "Korean"},
        )

    assert res.status_code == 200
    system_blocks = mock_client.messages.create.call_args.kwargs["system"]
    system_text = "\n".join(b["text"] for b in system_blocks)
    assert "SELECTED PASSAGE" not in system_text


@pytest.mark.asyncio
async def test_feedback_chat_returns_pure_answer_no_keywords(client: AsyncClient, auth_header: dict):
    """채팅 답변은 LLM 출력을 그대로 content로 담고, keyword는 응답에 싣지 않는다.

    회귀: 과거엔 같은 콜에서 답변+keyword를 받다(structured output/CUE_DELIMITER) 본문이
    keyword로 오배치·절단되는 자잘한 사고가 있었다. 단서 추출은 별도 /feedback/cues로 분리했고,
    답변 콜은 cue 지시를 system 프롬프트에 넣지 않으며 응답에 keywords 필드도 없다.
    """
    body = "완료형은 과거의 행동이 현재까지 영향을 미침을 나타냅니다.\n\n예시도 함께 보세요."
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text=body)]
    mock_response.usage = AsyncMock(input_tokens=500, output_tokens=50,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={"message": "완료형이 뭐야?", "history": [], "response_language": "Korean"},
        )

    assert res.status_code == 200
    data = res.json()
    # 본문은 통째로 보존되고, 응답엔 keywords 필드가 없다(단서는 분리 경로로만).
    assert data["content"] == body
    assert "keywords" not in data
    # 답변 콜 system 프롬프트엔 더 이상 cue/delimiter 지시가 없어야 한다.
    system_blocks = mock_client.messages.create.call_args.kwargs["system"]
    system_text = "\n".join(b["text"] for b in system_blocks)
    assert "%%CUES%%" not in system_text


@pytest.mark.asyncio
async def test_feedback_cues_endpoint_returns_keywords(client: AsyncClient, auth_header: dict):
    """POST /api/feedback/cues 는 교환 텍스트에서 추출한 단서를 반환한다(답변과 분리된 경로)."""
    with patch(
        "app.routers.feedback.extract_cues",
        new_callable=AsyncMock,
        return_value=(["역전파", "경사하강"], None),
    ):
        res = await client.post(
            "/api/feedback/cues",
            headers=auth_header,
            json={"text": "역전파와 경사하강에 대해 설명했다.", "response_language": "Korean"},
        )

    assert res.status_code == 200
    assert res.json()["keywords"] == ["역전파", "경사하강"]


@pytest.mark.asyncio
async def test_feedback_cues_endpoint_requires_auth(client: AsyncClient):
    res = await client.post("/api/feedback/cues", json={"text": "x"})
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_feedback_chat_returns_feedback_id_and_is_rateable(client: AsyncClient, auth_header: dict):
    """채팅 응답이 AIResponse로 적재되어 /feedback/{id}/rate 로 평가 가능해야 한다."""
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="assistant reply for rating")]
    mock_response.usage = AsyncMock(input_tokens=100, output_tokens=20,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

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
async def test_feedback_chat_textbook_prompt_caches_and_drops_external_badge(
    client: AsyncClient, auth_header: dict
):
    """교재 연결 채팅: 교재 컨텍스트가 cache_control system 블록으로 가고, '교재 외' badge
    발화 지시가 없어야 한다(피드백과 동일 처방의 채팅 측 회귀 가드)."""
    import io
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

    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="answer body")]
    mock_response.usage = AsyncMock(input_tokens=500, output_tokens=50,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={
                "message": "이 페이지 설명해줘",
                "history": [],
                "response_language": "Korean",
                "textbook_id": textbook_id,
                "current_page": 1,
            },
        )

    assert res.status_code == 200
    system = mock_client.messages.create.call_args.kwargs["system"]
    # 교재 컨텍스트는 cache_control:ephemeral system 블록으로 주입
    assert isinstance(system, list)
    block = system[0]
    assert block["cache_control"] == {"type": "ephemeral"}
    assert "Lesson 24" in block["text"]            # 교재 텍스트 캐시 prefix에 포함
    assert "[p.33]" in block["text"]               # 공유 커널 양의 주장 유지
    assert "mark it as" not in block["text"]       # 교재 외 badge 발화 지시 없음


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
    mock_response.usage = AsyncMock(input_tokens=100, output_tokens=20,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

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
    # system은 프롬프트 캐싱(§11 L2)을 위해 content block 리스트 형태. 텍스트에 Japanese 포함 확인.
    call_kwargs = mock_client.messages.create.call_args.kwargs
    system_block = call_kwargs["system"][0]
    assert "Japanese" in system_block["text"]
    # 캐싱 회귀 가드: system 블록에 cache_control(ephemeral)이 부착돼야 한다.
    assert system_block["cache_control"] == {"type": "ephemeral"}
    # output 상한(§11 L1)이 적용돼야 한다.
    assert call_kwargs["max_tokens"] == 2048


@pytest.mark.asyncio
async def test_feedback_chat_attaches_annotation_image(client: AsyncClient, auth_header: dict):
    """annotation_image가 오면 사용자 턴을 멀티모달(text+image)로 구성하고
    '주의/혼란 지도' system 블록을 주입하는지 회귀 가드(길 B)."""
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="ok")]
    mock_response.usage = AsyncMock(input_tokens=100, output_tokens=20,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

    # 1x1 투명 PNG 대용 — 내용은 무관, base64 문자열이 image 블록에 그대로 실리는지만 본다.
    fake_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={
                "message": "이 부분 설명해줘",
                "history": [],
                "response_language": "Korean",
                "annotation_image": fake_b64,
            },
        )

    assert res.status_code == 200
    call_kwargs = mock_client.messages.create.call_args.kwargs

    # 마지막 사용자 턴이 text+image 블록 리스트여야 한다.
    last_msg = call_kwargs["messages"][-1]
    assert last_msg["role"] == "user"
    assert isinstance(last_msg["content"], list)
    blocks = last_msg["content"]
    assert blocks[0]["type"] == "text" and blocks[0]["text"] == "이 부분 설명해줘"
    img = next(b for b in blocks if b["type"] == "image")
    assert img["source"]["type"] == "base64"
    assert img["source"]["media_type"] == "image/jpeg"
    assert img["source"]["data"] == fake_b64

    # system에 주석=주의/혼란 지도 지시가 들어가야 한다.
    system_text = call_kwargs["system"][0]["text"]
    assert "ATTENTION/CONFUSION MAP" in system_text


@pytest.mark.asyncio
async def test_feedback_chat_without_annotation_image_keeps_text_only(
    client: AsyncClient, auth_header: dict
):
    """annotation_image 미첨부면 사용자 턴은 기존대로 plain string이어야 한다(BC 회귀 가드)."""
    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="ok")]
    mock_response.usage = AsyncMock(input_tokens=100, output_tokens=20,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={"message": "hello", "history": [], "response_language": "Korean"},
        )

    assert res.status_code == 200
    call_kwargs = mock_client.messages.create.call_args.kwargs
    last_msg = call_kwargs["messages"][-1]
    assert last_msg["content"] == "hello"
    assert "ATTENTION/CONFUSION MAP" not in call_kwargs["system"][0]["text"]


@pytest.mark.asyncio
async def test_feedback_chat_textbook_rules_prioritize_question_intent(
    client: AsyncClient, auth_header: dict
):
    """교재 연결 채팅 system RULES 회귀 가드.

    실증(prod ai_response_rating): 교재 챕터 전체가 system에 깔린 상태에서
    '이거 번역해줘' 같은 생략·지시적 질문에 모델이 대화 화제가 아니라 교재
    전체로 끌려가 전체를 번역/인용하는 맥락 오류가 반복됨. 수정은 RULES를
    질문 의도 우선으로 재정렬한 것이므로, 그 핵심 지시가 system 텍스트에
    실제로 주입되는지 가드한다.
    """
    import fitz

    doc = fitz.open()
    page = doc.new_page()
    page.insert_text((72, 72), "Lesson 32 The Relative Pronoun")
    pdf_bytes = doc.tobytes()
    doc.close()

    upload_res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("grammar.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-rules"},
    )
    textbook_id = upload_res.json()["id"]

    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="ok")]
    mock_response.usage = AsyncMock(input_tokens=100, output_tokens=20,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={
                "message": "영어로 번역하면 어떤 느낌?",
                "history": [],
                "response_language": "Korean",
                "textbook_id": textbook_id,
                "current_page": 1,
            },
        )

    assert res.status_code == 200
    system_text = mock_client.messages.create.call_args.kwargs["system"][0]["text"]
    # 교재 컨텍스트 분기를 실제로 탔는지 확인 (이게 빠지면 아래 가드가 무의미).
    assert "TEXTBOOK REFERENCES" in system_text
    # 질문 의도 우선 지시가 주입돼야 한다.
    assert "ANSWER THE USER'S ACTUAL QUESTION FIRST" in system_text
    # 생략·지시적 질문은 대화에서 지시 대상을 해소하라는 지시가 있어야 한다.
    assert "elliptical or deictic" in system_text
    # 무조건적 "always prefer textbook" 문구는 제거됐어야 한다 (과당김 원인).
    assert "Always prefer textbook content" not in system_text


@pytest.mark.asyncio
async def test_feedback_requests_handwriting_structured_output_and_stores_it(
    client: AsyncClient, auth_header: dict, db_session
):
    """one-pass structured output 회귀 가드.

    피드백 Vision 호출은 transcription을 강제하는 output_config를 걸어야 하고, 반환된
    손글씨 원문은 ai_response.handwriting_transcription에 저장돼야 한다(채팅 주입의 원천).
    """
    from sqlalchemy import select
    from app.models.feedback import AIResponse

    result_with_transcription = FeedbackResult(
        data={
            "type": "feedback",
            "content": "feedback body",
            "transcription": "πιστὸς δὲ ὁ θεός",
        },
        model="claude-sonnet-4-6",
        input_tokens=800, output_tokens=150, total_tokens=950,
        cost_usd=0.0, latency_ms=10,
    )

    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=result_with_transcription,
    ):
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("canvas.png", io.BytesIO(b"\x89PNG fake"), "image/png")},
            data={"note_id": "note-hw", "language": "grc"},
        )

    assert res.status_code == 200
    fid = res.json()["feedback_id"]
    # transcription은 클라이언트 응답으로 새지 않는다(서버 전용 컨텍스트).
    assert "transcription" not in res.json()
    row = (await db_session.execute(
        select(AIResponse).where(AIResponse.id == fid)
    )).scalar_one()
    assert row.handwriting_transcription == "πιστὸς δὲ ὁ θεός"


@pytest.mark.asyncio
async def test_feedback_chat_injects_handwriting_from_parent_feedback(
    client: AsyncClient, auth_header: dict, db_session
):
    """채팅이 source 피드백의 손글씨 원문을 system에 주입하는지(틈 1 수정) 가드.

    parent_feedback_id로 조회한 transcription이 system 블록에 라벨과 함께 들어가야,
    "피드백 요청한 문장" 같은 지시가 노트 원문으로 해소된다.
    """
    from app.models.feedback import AIResponse

    parent = AIResponse(
        user_id="test-user-00000000-0000-0000-0000-000000000001",
        note_id="note-hw",
        task_type="feedback",
        language="grc",
        response_language="Korean",
        model="claude-sonnet-4-6",
        has_textbook_context=False,
        response_content="feedback body",
        handwriting_transcription="κρίνατε ὑμεῖς ὅ φημι",
    )
    db_session.add(parent)
    await db_session.commit()

    mock_response = AsyncMock()
    mock_response.content = [AsyncMock(text="ok")]
    mock_response.usage = AsyncMock(input_tokens=100, output_tokens=20,
                                    cache_read_input_tokens=0, cache_creation_input_tokens=0)

    with patch("app.routers.feedback.AsyncAnthropic") as mock_cls:
        mock_client = AsyncMock()
        mock_client.messages.create.return_value = mock_response
        mock_cls.return_value = mock_client

        res = await client.post(
            "/api/feedback/chat",
            headers=auth_header,
            json={
                "message": "피드백 요청한 문장 한국어로 무슨 뜻이야?",
                "history": [],
                "response_language": "Korean",
                "parent_feedback_id": parent.id,
            },
        )

    assert res.status_code == 200
    system_text = mock_client.messages.create.call_args.kwargs["system"][0]["text"]
    assert "HANDWRITTEN WORK" in system_text
    assert "κρίνατε ὑμεῖς ὅ φημι" in system_text
