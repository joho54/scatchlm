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
    recognized_text: str
    feedback: str
    summary: str


@router.post("/feedback", response_model=FeedbackResponse)
async def request_feedback(
    image: UploadFile = File(...),
    note_id: str = Form(...),
    language: str = Form("en"),
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

    # 2. 현재 보고 있는 페이지 (PDF 뷰어)
    elif source and current_page:
        page_text = extract_pdf_text(source.server_path, current_page, current_page)
        if page_text:
            context_parts.append(f"[현재 페이지 {current_page}]\n{page_text}")
            log.info("Context: current page p.%d", current_page)

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
