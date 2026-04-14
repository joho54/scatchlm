import logging

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, UploadFile, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.auth import get_current_user_id
from app.core.database import get_db, async_session
from app.models.textbook import TextbookSource
from app.services.pdf_service import save_pdf, extract_text as extract_pdf_text
from app.services.indexing_service import index_textbook

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api/pdf", tags=["pdf"])


async def _background_index(textbook_id: str, user_id: str, server_path: str):
    """백그라운드에서 PDF를 인덱싱한다."""
    async with async_session() as db:
        try:
            count = await index_textbook(db, textbook_id, user_id, server_path)
            log.info("Background indexing done: textbook=%s chunks=%d", textbook_id, count)
        except Exception:
            log.exception("Background indexing failed: textbook=%s", textbook_id)


@router.post("/upload")
async def upload_pdf(
    file: UploadFile = File(...),
    note_id: str = Form(...),
    background_tasks: BackgroundTasks = BackgroundTasks(),
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    log.info("PDF upload: user=%s note=%s file=%s", user_id, note_id, file.filename)

    if not file.filename.endswith(".pdf"):
        log.warning("PDF upload rejected: not a PDF file=%s", file.filename)
        raise HTTPException(status_code=400, detail="Only PDF files are allowed")

    try:
        server_path, file_name, total_pages, file_size = await save_pdf(file, user_id)
    except ValueError as e:
        log.warning("PDF upload rejected: size limit file=%s error=%s", file.filename, e)
        raise HTTPException(status_code=413, detail=str(e))

    log.info("PDF saved: file=%s pages=%d size=%dKB path=%s", file_name, total_pages, file_size // 1024, server_path)

    source = TextbookSource(
        user_id=user_id,
        note_id=note_id,
        file_name=file_name,
        server_path=server_path,
        total_pages=total_pages,
        file_size=file_size,
    )
    db.add(source)
    try:
        await db.commit()
        await db.refresh(source)
        log.info("PDF record created: id=%s user=%s note=%s", source.id, user_id, note_id)
    except Exception:
        log.exception("DB commit failed: user=%s note=%s file=%s", user_id, note_id, file_name)
        raise HTTPException(status_code=500, detail="Database error")

    background_tasks.add_task(_background_index, source.id, user_id, server_path)

    return {
        "id": source.id,
        "fileName": file_name,
        "totalPages": total_pages,
        "fileSize": file_size,
        "indexing": "started",
    }


@router.get("/extract")
async def extract_text(
    textbook_id: str,
    page_start: int,
    page_end: int,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    log.info("PDF extract: user=%s textbook=%s pages=%d-%d", user_id, textbook_id, page_start, page_end)

    result = await db.execute(
        select(TextbookSource).where(
            TextbookSource.id == textbook_id,
            TextbookSource.user_id == user_id,
        )
    )
    source = result.scalar_one_or_none()
    if not source:
        log.warning("PDF extract: textbook not found id=%s user=%s", textbook_id, user_id)
        raise HTTPException(status_code=404, detail="Textbook not found")

    if page_start < 1 or page_end > source.total_pages or page_start > page_end:
        log.warning("PDF extract: invalid range pages=%d-%d total=%d", page_start, page_end, source.total_pages)
        raise HTTPException(status_code=400, detail="Invalid page range")

    text = extract_pdf_text(source.server_path, page_start, page_end)
    log.info("PDF extract done: textbook=%s pages=%d-%d chars=%d", textbook_id, page_start, page_end, len(text))
    return {"text": text, "pages": f"{page_start}-{page_end}"}
