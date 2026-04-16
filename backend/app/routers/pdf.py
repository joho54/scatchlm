import logging

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, UploadFile, HTTPException
from fastapi.responses import FileResponse
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
        server_path, file_name, total_pages, file_size, content_hash = await save_pdf(file, user_id)
    except ValueError as e:
        log.warning("PDF upload rejected: size limit file=%s error=%s", file.filename, e)
        raise HTTPException(status_code=413, detail=str(e))

    # 동일 내용 PDF가 이미 존재하면 기존 레코드 재사용 (임베딩 스킵)
    existing = await db.execute(
        select(TextbookSource).where(
            TextbookSource.user_id == user_id,
            TextbookSource.content_hash == content_hash,
        )
    )
    existing_source = existing.scalar_one_or_none()

    if existing_source:
        log.info("PDF duplicate: hash=%s existing_id=%s, reusing", content_hash[:12], existing_source.id)
        # 중복 파일 삭제
        import os
        try:
            os.remove(server_path)
        except OSError:
            pass
        return {
            "id": existing_source.id,
            "fileName": existing_source.file_name,
            "totalPages": existing_source.total_pages,
            "fileSize": existing_source.file_size,
            "indexing": "complete",
        }

    log.info("PDF saved: file=%s pages=%d size=%dKB path=%s", file_name, total_pages, file_size // 1024, server_path)

    source = TextbookSource(
        user_id=user_id,
        note_id=note_id,
        file_name=file_name,
        server_path=server_path,
        total_pages=total_pages,
        file_size=file_size,
        content_hash=content_hash,
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


@router.get("/{textbook_id}/file")
async def serve_pdf_file(
    textbook_id: str,
    token: str | None = None,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """PDF 파일을 직접 서빙한다 (WebView PDF 뷰어용).

    WebView에서는 Authorization 헤더를 직접 설정할 수 없으므로
    ?token=JWT 쿼리 파라미터도 허용한다.
    """
    result = await db.execute(
        select(TextbookSource).where(
            TextbookSource.id == textbook_id,
            TextbookSource.user_id == user_id,
        )
    )
    source = result.scalar_one_or_none()
    if not source:
        raise HTTPException(status_code=404, detail="Textbook not found")

    return FileResponse(
        source.server_path,
        media_type="application/pdf",
        filename=source.file_name,
    )


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
