import json
import logging

from datetime import datetime

from fastapi import APIRouter, Depends, File, Form, UploadFile, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from anthropic import AsyncAnthropic

from app.core.auth import get_current_user_id, get_role, get_tier, get_verified_payload
from app.core.config import settings
from app.core.constants import DEFAULT_SUBJECT
from app.core.database import get_db
from app.core.quota import check_daily_quota
from app.models.feedback import AIResponse, AIResponseRating
from app.models.textbook import TextbookSource
from app.core.log_sanitize import loglen
from app.services.feedback_service import (
    classify_anthropic_error,
    create_message_with_retry,
    estimate_cost_from_usage,
    get_feedback,
    get_recognition,
    _clean_keywords,
    RECOGNITION_MODEL,
)
from app.services.pdf_service import extract_text as extract_pdf_text, extract_text_async
from app.services.retrieval_service import search_relevant_chunks, format_chunks_as_context
from app.services.usage_service import log_llm_usage

PROMPT_CONTEXT_MAX_CHARS = 2000

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["feedback"])


class FeedbackResponse(BaseModel):
    type: str = "feedback"
    content: str = ""
    feedback_id: str | None = None
    keywords: list[str] = []  # DMN 단서 — 구버전 클라이언트는 무시(BC)
    # Legacy fields (optional, for backward compat)
    recognized_text: str = ""
    feedback: str = ""
    summary: str = ""


@router.post("/feedback", response_model=FeedbackResponse)
async def request_feedback(
    image: UploadFile = File(...),
    note_id: str = Form(...),
    language: str = Form(DEFAULT_SUBJECT),
    response_language: str = Form("English"),
    task_type: str = Form("complex"),
    textbook_id: str | None = Form(None),
    current_page: int | None = Form(None),
    page_start: int | None = Form(None),
    page_end: int | None = Form(None),
    previous_context: str | None = Form(None),
    request_id: str | None = Form(None),
    payload: dict = Depends(get_verified_payload),
    db: AsyncSession = Depends(get_db),
):
    user_id = payload["sub"]
    tier = get_tier(payload)
    rid = request_id or "no-id"
    log.info("Feedback [%s]: start user=%s tier=%s note=%s page=%s", rid, user_id, tier, note_id, current_page)

    # quota 체크 — 초과 시 LLM 호출 없이 429
    await check_daily_quota(user_id, tier, db, is_admin=get_role(payload) == "admin")

    image_bytes = await image.read()
    if not image_bytes:
        raise HTTPException(status_code=400, detail="Empty image")

    # 교재 컨텍스트 합산 (배타적이지 않음)
    context_parts = []
    source = None

    if textbook_id:
        result = await db.execute(
            select(TextbookSource).where(
                TextbookSource.id == textbook_id,
                TextbookSource.user_id == user_id,
            )
        )
        source = result.scalar_one_or_none()

    # 1. 수동 페이지 범위 (있으면 우선)
    if source and page_start and page_end:
        page_text = await extract_text_async(db, source, page_start, page_end)
        if page_text:
            context_parts.append(f"[페이지 {page_start}-{page_end}]\n{page_text}")
            log.info("Context: manual page range p.%d-%d", page_start, page_end)

    # 2. 현재 보고 있는 챕터 전체 (PDF 뷰어)
    elif source and current_page:
        from app.models.chapter import Chapter
        # 계층형 TOC에서는 한 페이지가 PART/Chapter/Section 등 여러 챕터에
        # 동시에 속한다. 가장 좁은(=가장 구체적인) 범위의 챕터 하나를 고른다.
        chapter_result = await db.execute(
            select(Chapter)
            .where(
                Chapter.textbook_id == textbook_id,
                Chapter.page_start <= current_page,
                Chapter.page_end >= current_page,
            )
            .order_by((Chapter.page_end - Chapter.page_start).asc())
            .limit(1)
        )
        chapter = chapter_result.scalars().first()
        if chapter:
            page_text = await extract_text_async(db, source, chapter.page_start, chapter.page_end or current_page)
            if page_text:
                context_parts.append(f"[{chapter.title} p.{chapter.page_start}-{chapter.page_end}]\n{page_text}")
                log.info("Context: chapter '%s' p.%d-%d", chapter.title, chapter.page_start, chapter.page_end or 0)
        else:
            page_text = await extract_text_async(db, source, current_page, current_page)
            if page_text:
                context_parts.append(f"[현재 페이지 {current_page}]\n{page_text}")
                log.info("Context: current page p.%d (no chapter match)", current_page)

    # RAG 자동 검색 — 챕터 전체 텍스트가 없는 경우에만 실행
    if textbook_id and not context_parts:
        try:
            recognized, rec_usage = await get_recognition(image_bytes, language)
            if rec_usage is not None:
                await log_llm_usage(
                    db, user_id=user_id, model=RECOGNITION_MODEL,
                    input_tokens=rec_usage.input_tokens, output_tokens=rec_usage.output_tokens,
                    cost_usd=estimate_cost_from_usage(RECOGNITION_MODEL, rec_usage), latency_ms=0,
                    task_type="recognition", language=language, billable=False,
                )
            if recognized:
                chunks = await search_relevant_chunks(db, textbook_id, recognized, user_id=user_id)
                if chunks:
                    rag_context = format_chunks_as_context(chunks)
                    context_parts.append(f"[관련 교재 내용]\n{rag_context}")
                    log.info("Context: RAG fallback, %d chunks found", len(chunks))
        except Exception:
            log.exception("RAG search failed, proceeding without RAG context")

    textbook_context = "\n\n".join(context_parts) if context_parts else None

    error_msg = None
    try:
        result = await get_feedback(
            image_bytes=image_bytes,
            language=language,
            response_language=response_language,
            textbook_context=textbook_context,
            previous_context=previous_context,
            task_type=task_type,
        )
    except Exception as e:
        error_msg = str(e)
        error_kind = classify_anthropic_error(e)
        log.exception("Feedback API failed: user=%s note=%s kind=%s", user_id, note_id, error_kind)
        await log_llm_usage(
            db, user_id=user_id, model="unknown",
            input_tokens=0, output_tokens=0, cost_usd=0, latency_ms=0,
            task_type=task_type, language=language,
            has_textbook_context=textbook_context is not None, error=error_msg,
        )
        await db.commit()
        raise HTTPException(status_code=502, detail=f"LLM API error: {error_msg}")

    # usage 기록
    await log_llm_usage(
        db, user_id=user_id, model=result.model,
        input_tokens=result.input_tokens, output_tokens=result.output_tokens,
        cost_usd=result.cost_usd, latency_ms=result.latency_ms,
        task_type=task_type, language=language,
        has_textbook_context=textbook_context is not None,
    )

    # 사용자 피드백 수집을 위한 레코드 적재
    response_content = result.data.get("content") or ""
    # 손글씨 transcription은 응답 본문이 아니라 후속 채팅 컨텍스트용 — 별도 컬럼에 저장하고
    # 클라이언트 응답(FeedbackResponse) spread에선 빼낸다.
    handwriting_transcription = (result.data.pop("transcription", "") or "")[:PROMPT_CONTEXT_MAX_CHARS] or None
    keywords = result.data.get("keywords") or []  # 응답 spread에도 남겨두고 저장도 한다
    record = AIResponse(
        user_id=user_id,
        note_id=note_id,
        task_type=task_type,
        language=language,
        response_language=response_language,
        model=result.model,
        textbook_id=textbook_id,
        current_page=current_page,
        has_textbook_context=textbook_context is not None,
        prompt_context_snippet=(textbook_context or "")[:PROMPT_CONTEXT_MAX_CHARS] or None,
        previous_context=(previous_context or "")[:PROMPT_CONTEXT_MAX_CHARS] or None,
        response_content=response_content,
        handwriting_transcription=handwriting_transcription,
        keywords=keywords,
        request_id=request_id,
    )
    db.add(record)
    await db.commit()
    await db.refresh(record)

    log.info("Feedback [%s]: done latency=%dms feedback_id=%s", rid, result.latency_ms, record.id)
    return FeedbackResponse(feedback_id=record.id, **result.data)


class RatingRequest(BaseModel):
    rating: int = Field(..., description="-1 (👎) or 1 (👍)")
    reason_tags: list[str] = Field(default_factory=list)
    comment: str | None = None
    client_ts: datetime | None = None


@router.post("/feedback/{feedback_id}/rate", status_code=204)
async def rate_feedback(
    feedback_id: str,
    body: RatingRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    if body.rating not in (-1, 1):
        raise HTTPException(status_code=400, detail="rating must be -1 or 1")
    if body.comment and len(body.comment) > 2000:
        raise HTTPException(status_code=400, detail="comment too long (max 2000)")

    record = (await db.execute(
        select(AIResponse).where(AIResponse.id == feedback_id)
    )).scalar_one_or_none()
    if record is None:
        raise HTTPException(status_code=404, detail="feedback not found")
    if record.user_id != user_id:
        raise HTTPException(status_code=403, detail="not your feedback")

    existing = (await db.execute(
        select(AIResponseRating).where(AIResponseRating.response_id == feedback_id)
    )).scalar_one_or_none()

    if existing is None:
        db.add(AIResponseRating(
            response_id=feedback_id,
            user_id=user_id,
            rating=body.rating,
            reason_tags=body.reason_tags or [],
            comment=body.comment,
            client_ts=body.client_ts.replace(tzinfo=None) if body.client_ts else None,
        ))
    else:
        existing.rating = body.rating
        existing.reason_tags = body.reason_tags or []
        existing.comment = body.comment
        if body.client_ts:
            existing.client_ts = body.client_ts.replace(tzinfo=None)

    await db.commit()
    log.info("Feedback rating: user=%s feedback=%s rating=%d tags=%s",
             user_id, feedback_id, body.rating, body.reason_tags)
    return None


class ChatMessage(BaseModel):
    role: str  # "user" or "assistant"
    content: str

class ChatRequest(BaseModel):
    message: str
    history: list[ChatMessage] = []
    response_language: str = "Korean"
    subject: str | None = None  # 학습 분야 (언어/물리/역사 등). 없으면 분야 중립 튜터
    textbook_id: str | None = None
    current_page: int | None = None
    note_id: str | None = None
    parent_feedback_id: str | None = None  # 부모 피드백/응답 id (rating 분석용 컨텍스트)

class ChatResponse(BaseModel):
    content: str
    sources: list[dict] = []  # [{"page_start": 33, "page_end": 34, "preview": "..."}]
    feedback_id: str | None = None  # 채팅 응답의 AIResponse id — 평가 대상
    keywords: list[str] = []  # DMN 단서 — 구버전 클라이언트는 무시(BC)


# 채팅 structured output 스키마. content(마크다운 답변)와 keywords(DMN 인출 단서)를 한 호출로 받는다.
# 별도 추출 호출을 붙이지 않으려는 의도 — 한계비용(출력 토큰 몇 개)으로 단서를 얻는다.
# 주의: 잘림(max_tokens)·비-JSON 응답이면 raw text 폴백으로 content를 채우고 keywords는 비운다(BC).
CHAT_OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {
        "content": {
            "type": "string",
            "description": (
                "Your full tutor response to the user, in markdown, in the requested response language. "
                "This is the ONLY thing shown to the user — put the entire answer here, following all the "
                "formatting/citation rules in the system prompt."
            ),
        },
        "keywords": {
            "type": "array",
            "items": {"type": "string"},
            "description": (
                "0-5 rest-time retrieval cues — load-bearing concepts from THIS exchange the learner should recall later. "
                "Each MUST be a SINGLE short term: one noun or a tight compound, ideally <=6 characters in Korean. "
                "NO phrases, NO clauses, NO descriptions, NO space-joined word lists. "
                "Good: '역전파', '베이즈정리', '경사하강'. "
                "Bad: '자음 어간 동사 변화', '구개음·입술음·치음 + σ 변형' (these are phrases — split into single terms or drop). "
                "Not a summary. Empty array if the exchange is chit-chat or has no substantive concept."
            ),
        },
    },
    "required": ["content"],
    "additionalProperties": False,
}


@router.post("/feedback/chat", response_model=ChatResponse)
async def feedback_chat(
    req: ChatRequest,
    payload: dict = Depends(get_verified_payload),
    db: AsyncSession = Depends(get_db),
):
    """피드백 후속 채팅 — RAG 지원."""
    user_id = payload["sub"]
    tier = get_tier(payload)
    log.info("Feedback chat: user=%s tier=%s history=%d msg=%s textbook=%s note=%s",
             user_id, tier, len(req.history), len(req.message), req.textbook_id, req.note_id)

    # quota 체크 — 초과 시 LLM 호출 없이 429
    await check_daily_quota(user_id, tier, db, is_admin=get_role(payload) == "admin")

    # 현재 챕터의 전체 텍스트를 컨텍스트로 주입
    textbook_context = ""
    sources = []
    if req.textbook_id and req.current_page:
        try:
            from app.models.chapter import Chapter

            source = (await db.execute(
                select(TextbookSource).where(
                    TextbookSource.id == req.textbook_id,
                    TextbookSource.user_id == user_id,
                )
            )).scalar_one_or_none()

            # 현재 페이지가 속한 챕터 찾기 (계층형 TOC면 가장 좁은 범위 우선)
            chapter_result = await db.execute(
                select(Chapter)
                .where(
                    Chapter.textbook_id == req.textbook_id,
                    Chapter.page_start <= req.current_page,
                    Chapter.page_end >= req.current_page,
                )
                .order_by((Chapter.page_end - Chapter.page_start).asc())
                .limit(1)
            )
            chapter = chapter_result.scalars().first()

            if source and chapter:
                # 챕터 전체 텍스트 추출 (OCR-aware)
                page_text = await extract_text_async(
                    db, source, chapter.page_start, chapter.page_end or chapter.page_start + 10
                )
                textbook_context = f"--- {chapter.title} (p.{chapter.page_start}-{chapter.page_end}) ---\n{page_text}"
                sources.append({
                    "page_start": chapter.page_start,
                    "page_end": chapter.page_end,
                    "preview": chapter.title,
                })
                log.info("Chat context: chapter='%s' pages=%d-%d chars=%d",
                         chapter.title, chapter.page_start, chapter.page_end or 0, len(page_text))
            elif source:
                # 챕터 매칭 안 되면 현재 페이지만
                page_text = await extract_text_async(db, source, req.current_page, req.current_page)
                textbook_context = f"--- p.{req.current_page} ---\n{page_text}"
                log.info("Chat context: single page %d, chars=%d", req.current_page, len(page_text))
        except Exception:
            log.exception("Chat context extraction failed")

    # 손글씨 원문 주입(best-effort). 채팅 시점엔 노트 이미지가 없어 "피드백 요청한 문장"의 실체가
    # 프롬프트에 없던 틈을 메운다 — 세션을 연 source 피드백의 transcription을 조회해 라벨 블록으로 넣는다.
    # 가이드 등 transcription이 없는 응답이면 그냥 건너뛴다.
    handwriting = ""
    if req.parent_feedback_id:
        try:
            handwriting = (await db.execute(
                select(AIResponse.handwriting_transcription).where(
                    AIResponse.id == req.parent_feedback_id,
                    AIResponse.user_id == user_id,
                )
            )).scalar_one_or_none() or ""
            if handwriting:
                log.info("Chat context: handwriting transcription chars=%d", len(handwriting))
        except Exception:
            log.exception("Handwriting transcription lookup failed")

    # 시스템 프롬프트 구성
    subject_clause = f" {req.subject}" if req.subject else " their material"
    system_parts = [
        f"You are a study tutor helping the user learn{subject_clause}, often alongside their textbook. "
        "If the subject is a language, help with translation, grammar, and vocabulary; "
        "for other subjects, focus on concepts, reasoning, and terminology. "
        "ADDRESS THE USER DIRECTLY in the second person; do NOT refer to them with a "
        "third-person label such as \"the student\"/\"학생\".",
        f"Respond in {req.response_language}. Use markdown formatting freely. "
        "For math, use LaTeX with dollar delimiters ONLY: $...$ for inline math, "
        "and $$...$$ on their own lines for display math (matrices, fractions, aligned equations). "
        "Never use \\( \\) or \\[ \\] delimiters.",
    ]

    if handwriting:
        system_parts.append(
            "\nTHE USER'S HANDWRITTEN WORK (what they wrote and asked for feedback on — this is the "
            "subject of the conversation; when they say \"이 문장\"/\"피드백 요청한 문장\"/\"this sentence\" "
            "they mean something in here, NOT the textbook):\n"
            + handwriting
        )

    if textbook_context:
        system_parts.append(
            "\nTEXTBOOK REFERENCES (from the user's textbook):\n"
            + textbook_context
            + "\n\nRULES:\n"
            "1. ANSWER THE USER'S ACTUAL QUESTION FIRST. The textbook references are SUPPORTING MATERIAL, "
            "not the subject of the conversation. Determine what the user is asking, then answer exactly that "
            "scope — do not expand a narrow question into a summary/translation of the whole reference text.\n"
            "2. If the question is elliptical or deictic (e.g. \"이거 번역해줘\", \"무슨 뜻이야?\", \"어떤 느낌?\"), "
            "the referent lives in the CONVERSATION, not the textbook. Resolve it from the immediately preceding "
            "turns. If you genuinely cannot tell what the user is pointing at, ASK a one-line clarifying question "
            "instead of translating/summarizing the entire reference passage.\n"
            "3. When your answer is based on the textbook references above, cite the page number inline: [p.33]\n"
            "4. When your answer uses knowledge NOT found in the references above, clearly mark it as: 📖 교재 외 참고:\n"
            "5. Use textbook content as the preferred source of facts when it is relevant to the question — but "
            "relevance to the user's question comes first. Quote a passage only when it directly supports the answer; "
            "do not quote or reproduce reference text just because it is present.\n"
            "6. If the references don't contain relevant information for the question, say so and provide general knowledge with the 📖 marker.\n"
            "7. If the user asks about content from a DIFFERENT chapter than what's provided, tell them: "
            "\"해당 내용은 현재 보고 계신 챕터에 없습니다. 관련 챕터로 이동한 후 다시 질문해 주세요.\" "
            "and suggest which chapter/page they should navigate to if you can infer it."
        )
    else:
        system_parts.append(
            "No textbook is connected. Answer based on your general knowledge."
        )

    client = AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY, max_retries=0)

    messages = []
    for msg in req.history:
        messages.append({"role": msg.role, "content": msg.content})
    messages.append({"role": "user", "content": req.message})

    # 프롬프트 캐싱(§11 L2): system 블록(교재 RAG 컨텍스트 포함)은 같은 대화의 turn마다
    # prefix로 그대로 재사용된다 → cache_control로 5분 내 재요청 시 0.1× 과금(KV 캐시 재사용).
    # 교재 컨텍스트가 큰 경우 효과가 크다(미연결/짧은 system은 최소 캐시 길이 미만이면 무시되며 무해).
    system_blocks = [{
        "type": "text",
        "text": "\n".join(system_parts),
        "cache_control": {"type": "ephemeral"},
    }]

    try:
        response = await create_message_with_retry(
            client,
            model="claude-sonnet-4-6",
            max_tokens=2048,  # §11 L1: chat output 상한(설명형이라 피드백보다 넉넉히)
            system=system_blocks,
            messages=messages,
            output_config={"format": {"type": "json_schema", "schema": CHAT_OUTPUT_SCHEMA}},
        )
    except Exception as e:
        log.exception("Feedback chat API failed: user=%s kind=%s", user_id, classify_anthropic_error(e))
        raise HTTPException(status_code=502, detail=f"LLM API error: {e}")

    raw = response.content[0].text.strip()
    # structured output → {content, keywords}. 잘림(max_tokens)·비-JSON이면 raw를 그대로 답변으로 쓰고
    # keywords는 비운다(BC: 구 동작과 동일, 단서만 생략).
    keywords: list[str] = []
    try:
        parsed = json.loads(raw)
        content = (parsed.get("content") or "").strip() or raw
        keywords = _clean_keywords(parsed.get("keywords"), limit=5)
    except (json.JSONDecodeError, AttributeError):
        log.warning("Chat structured output parse failed (stop=%s); falling back to raw text", response.stop_reason)
        content = raw

    log.info("Chat keywords: n=%d %s", len(keywords), keywords)
    usage = response.usage
    cache_read = getattr(usage, "cache_read_input_tokens", 0) or 0
    cache_write = getattr(usage, "cache_creation_input_tokens", 0) or 0
    log.info("Feedback chat response: tokens=%d (in=%d out=%d cache_read=%d cache_write=%d) content=%s",
             usage.input_tokens + usage.output_tokens,
             usage.input_tokens, usage.output_tokens, cache_read, cache_write,
             loglen(content))

    # usage 기록 — 채팅 비용도 일일 quota에 합산되도록 적재. 캐시 적중분을 반영한 정확한 비용(§11 L2).
    chat_model = "claude-sonnet-4-6"
    await log_llm_usage(
        db, user_id=user_id, model=chat_model,
        input_tokens=usage.input_tokens, output_tokens=usage.output_tokens,
        cost_usd=estimate_cost_from_usage(chat_model, usage), latency_ms=0,
        task_type="chat", language="",
        has_textbook_context=bool(textbook_context),
    )

    # AIResponse 적재 — 채팅 응답도 평가 대상으로 관리
    record = AIResponse(
        user_id=user_id,
        note_id=req.note_id,
        task_type="chat",
        language="",
        response_language=req.response_language,
        model="claude-sonnet-4-6",
        textbook_id=req.textbook_id,
        current_page=req.current_page,
        has_textbook_context=bool(textbook_context),
        prompt_context_snippet=(textbook_context or "")[:PROMPT_CONTEXT_MAX_CHARS] or None,
        previous_context=req.parent_feedback_id,
        response_content=content,
        keywords=keywords,
    )
    db.add(record)
    await db.commit()
    await db.refresh(record)

    return ChatResponse(content=content, sources=sources, feedback_id=record.id, keywords=keywords)
