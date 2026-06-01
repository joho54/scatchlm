import logging

from datetime import datetime

from fastapi import APIRouter, Depends, File, Form, UploadFile, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from anthropic import AsyncAnthropic

from app.core.auth import get_current_user_id
from app.core.config import settings
from app.core.database import get_db
from app.models.feedback import AIResponse, AIResponseRating
from app.models.textbook import TextbookSource
from app.models.usage import LLMUsage
from app.services.feedback_service import get_feedback, get_recognition
from app.services.pdf_service import extract_text as extract_pdf_text
from app.services.retrieval_service import search_relevant_chunks, format_chunks_as_context

PROMPT_CONTEXT_MAX_CHARS = 2000

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["feedback"])


class FeedbackResponse(BaseModel):
    type: str = "feedback"
    content: str = ""
    feedback_id: str | None = None
    # Legacy fields (optional, for backward compat)
    recognized_text: str = ""
    feedback: str = ""
    summary: str = ""


@router.post("/feedback", response_model=FeedbackResponse)
async def request_feedback(
    image: UploadFile = File(...),
    note_id: str = Form(...),
    language: str = Form("en"),
    response_language: str = Form("English"),
    task_type: str = Form("complex"),
    textbook_id: str | None = Form(None),
    current_page: int | None = Form(None),
    page_start: int | None = Form(None),
    page_end: int | None = Form(None),
    previous_context: str | None = Form(None),
    request_id: str | None = Form(None),
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    rid = request_id or "no-id"
    log.info("Feedback [%s]: start user=%s note=%s page=%s", rid, user_id, note_id, current_page)

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
        page_text = extract_pdf_text(source.server_path, page_start, page_end)
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
            page_text = extract_pdf_text(source.server_path, chapter.page_start, chapter.page_end or current_page)
            if page_text:
                context_parts.append(f"[{chapter.title} p.{chapter.page_start}-{chapter.page_end}]\n{page_text}")
                log.info("Context: chapter '%s' p.%d-%d", chapter.title, chapter.page_start, chapter.page_end or 0)
        else:
            page_text = extract_pdf_text(source.server_path, current_page, current_page)
            if page_text:
                context_parts.append(f"[현재 페이지 {current_page}]\n{page_text}")
                log.info("Context: current page p.%d (no chapter match)", current_page)

    # RAG 자동 검색 — 챕터 전체 텍스트가 없는 경우에만 실행
    if textbook_id and not context_parts:
        try:
            recognized = await get_recognition(image_bytes, language)
            if recognized:
                chunks = await search_relevant_chunks(db, textbook_id, recognized)
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
        log.exception("Feedback API failed: user=%s note=%s", user_id, note_id)
        db.add(LLMUsage(
            user_id=user_id,
            model="unknown",
            input_tokens=0,
            output_tokens=0,
            total_tokens=0,
            cost_usd=0,
            latency_ms=0,
            task_type=task_type,
            language=language,
            has_textbook_context=textbook_context is not None,
            error=error_msg,
        ))
        await db.commit()
        raise HTTPException(status_code=502, detail=f"LLM API error: {error_msg}")

    # usage 기록
    db.add(LLMUsage(
        user_id=user_id,
        model=result.model,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        total_tokens=result.total_tokens,
        cost_usd=result.cost_usd,
        latency_ms=result.latency_ms,
        task_type=task_type,
        language=language,
        has_textbook_context=textbook_context is not None,
    ))

    # 사용자 피드백 수집을 위한 레코드 적재
    response_content = result.data.get("content") or ""
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


@router.post("/feedback/chat", response_model=ChatResponse)
async def feedback_chat(
    req: ChatRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """피드백 후속 채팅 — RAG 지원."""
    log.info("Feedback chat: user=%s history=%d msg=%s textbook=%s",
             user_id, len(req.history), req.message[:50], req.textbook_id)

    # 현재 챕터의 전체 텍스트를 컨텍스트로 주입
    textbook_context = ""
    sources = []
    if req.textbook_id and req.current_page:
        try:
            from app.models.chapter import Chapter

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

            if chapter:
                # 챕터 전체 텍스트 추출
                page_text = extract_pdf_text(
                    (await db.execute(
                        select(TextbookSource).where(TextbookSource.id == req.textbook_id)
                    )).scalar_one().server_path,
                    chapter.page_start,
                    chapter.page_end or chapter.page_start + 10,
                )
                textbook_context = f"--- {chapter.title} (p.{chapter.page_start}-{chapter.page_end}) ---\n{page_text}"
                sources.append({
                    "page_start": chapter.page_start,
                    "page_end": chapter.page_end,
                    "preview": chapter.title,
                })
                log.info("Chat context: chapter='%s' pages=%d-%d chars=%d",
                         chapter.title, chapter.page_start, chapter.page_end or 0, len(page_text))
            else:
                # 챕터 매칭 안 되면 현재 페이지만
                source = (await db.execute(
                    select(TextbookSource).where(TextbookSource.id == req.textbook_id)
                )).scalar_one_or_none()
                if source:
                    page_text = extract_pdf_text(source.server_path, req.current_page, req.current_page)
                    textbook_context = f"--- p.{req.current_page} ---\n{page_text}"
                    log.info("Chat context: single page %d, chars=%d", req.current_page, len(page_text))
        except Exception:
            log.exception("Chat context extraction failed")

    # 시스템 프롬프트 구성
    subject_clause = f" {req.subject}" if req.subject else " their material"
    system_parts = [
        f"You are a study tutor helping a student learn{subject_clause}, often alongside their textbook. "
        "If the subject is a language, help with translation, grammar, and vocabulary; "
        "for other subjects, focus on concepts, reasoning, and terminology.",
        f"Respond in {req.response_language}. Use markdown formatting freely.",
    ]

    if textbook_context:
        system_parts.append(
            "\nTEXTBOOK REFERENCES (from the student's textbook):\n"
            + textbook_context
            + "\n\nRULES:\n"
            "1. When your answer is based on the textbook references above, cite the page number inline: [p.33]\n"
            "2. When your answer uses knowledge NOT found in the references above, clearly mark it as: 📖 교재 외 참고:\n"
            "3. Always prefer textbook content over general knowledge when both are available.\n"
            "4. Quote relevant textbook passages directly when helpful.\n"
            "5. If the references don't contain relevant information for the question, say so and provide general knowledge with the 📖 marker.\n"
            "6. If the student asks about content from a DIFFERENT chapter than what's provided, tell them: "
            "\"해당 내용은 현재 보고 계신 챕터에 없습니다. 관련 챕터로 이동한 후 다시 질문해 주세요.\" "
            "and suggest which chapter/page they should navigate to if you can infer it."
        )
    else:
        system_parts.append(
            "No textbook is connected. Answer based on your general knowledge."
        )

    client = AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

    messages = []
    for msg in req.history:
        messages.append({"role": msg.role, "content": msg.content})
    messages.append({"role": "user", "content": req.message})

    response = await client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=4096,
        system="\n".join(system_parts),
        messages=messages,
    )

    content = response.content[0].text
    log.info("Feedback chat response: tokens=%d (in=%d out=%d) content=%s",
             response.usage.input_tokens + response.usage.output_tokens,
             response.usage.input_tokens, response.usage.output_tokens,
             content[:800])

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
    )
    db.add(record)
    await db.commit()
    await db.refresh(record)

    return ChatResponse(content=content, sources=sources, feedback_id=record.id)
