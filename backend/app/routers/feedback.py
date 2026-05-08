import logging

from fastapi import APIRouter, Depends, File, Form, UploadFile, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.textbook import TextbookSource
from app.models.usage import LLMUsage
from app.services.feedback_service import get_feedback, get_recognition
from app.services.pdf_service import extract_text as extract_pdf_text
from app.services.retrieval_service import search_relevant_chunks, format_chunks_as_context

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["feedback"])


class FeedbackResponse(BaseModel):
    type: str = "feedback"
    content: str = ""
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
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
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
        chapter_result = await db.execute(
            select(Chapter).where(
                Chapter.textbook_id == textbook_id,
                Chapter.page_start <= current_page,
                Chapter.page_end >= current_page,
            )
        )
        chapter = chapter_result.scalar_one_or_none()
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

    # 3. RAG 자동 검색 (교재 연결 시 항상 실행)
    if textbook_id:
        try:
            recognized = await get_recognition(image_bytes, language)
            if recognized:
                chunks = await search_relevant_chunks(db, textbook_id, recognized)
                if chunks:
                    rag_context = format_chunks_as_context(chunks)
                    context_parts.append(f"[관련 교재 내용]\n{rag_context}")
                    log.info("Context: RAG auto-search, %d chunks found", len(chunks))
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
    await db.commit()

    return FeedbackResponse(**result.data)


class ChatMessage(BaseModel):
    role: str  # "user" or "assistant"
    content: str

class ChatRequest(BaseModel):
    message: str
    history: list[ChatMessage] = []
    response_language: str = "Korean"
    textbook_id: str | None = None
    current_page: int | None = None

class ChatResponse(BaseModel):
    content: str
    sources: list[dict] = []  # [{"page_start": 33, "page_end": 34, "preview": "..."}]


@router.post("/feedback/chat", response_model=ChatResponse)
async def feedback_chat(
    req: ChatRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """피드백 후속 채팅 — RAG 지원."""
    from anthropic import AsyncAnthropic
    from app.core.config import settings

    log.info("Feedback chat: user=%s history=%d msg=%s textbook=%s",
             user_id, len(req.history), req.message[:50], req.textbook_id)

    # 현재 챕터의 전체 텍스트를 컨텍스트로 주입
    textbook_context = ""
    sources = []
    if req.textbook_id and req.current_page:
        try:
            from app.models.chapter import Chapter

            # 현재 페이지가 속한 챕터 찾기
            chapter_result = await db.execute(
                select(Chapter).where(
                    Chapter.textbook_id == req.textbook_id,
                    Chapter.page_start <= req.current_page,
                    Chapter.page_end >= req.current_page,
                )
            )
            chapter = chapter_result.scalar_one_or_none()

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
    system_parts = [
        f"You are a language learning tutor helping a student study with their textbook.",
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
    return ChatResponse(content=content, sources=sources)
