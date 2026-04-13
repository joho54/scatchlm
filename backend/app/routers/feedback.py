from fastapi import APIRouter, Depends, File, Form, UploadFile, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.auth import get_current_user
from app.core.database import get_db
from app.models.user import User
from app.models.textbook import TextbookSource
from app.services.feedback_service import get_feedback
from app.services.pdf_service import extract_text as extract_pdf_text

router = APIRouter(prefix="/api", tags=["feedback"])


class FeedbackResponse(BaseModel):
    recognized_text: str
    corrections: list[dict]
    summary: str


@router.post("/feedback", response_model=FeedbackResponse)
async def request_feedback(
    image: UploadFile = File(...),
    note_id: str = Form(...),
    language: str = Form("en"),
    task_type: str = Form("complex"),
    textbook_id: str | None = Form(None),
    page_start: int | None = Form(None),
    page_end: int | None = Form(None),
    previous_context: str | None = Form(None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    image_bytes = await image.read()
    if not image_bytes:
        raise HTTPException(status_code=400, detail="Empty image")

    # 교재 컨텍스트 조회
    textbook_context = None
    if textbook_id and page_start and page_end:
        result = await db.execute(
            select(TextbookSource).where(
                TextbookSource.id == textbook_id,
                TextbookSource.user_id == user.id,
            )
        )
        source = result.scalar_one_or_none()
        if source:
            textbook_context = extract_pdf_text(source.server_path, page_start, page_end)

    try:
        result = await get_feedback(
            image_bytes=image_bytes,
            language=language,
            textbook_context=textbook_context,
            previous_context=previous_context,
            task_type=task_type,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"LLM API error: {e}")

    return FeedbackResponse(**result)
