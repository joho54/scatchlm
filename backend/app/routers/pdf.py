import json
import logging
import os
import uuid

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, UploadFile, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.auth import get_current_user_id
from app.core.database import get_db, async_session
from app.models.textbook import TextbookSource
from app.models.guide import PageGuide
from app.models.chapter import Chapter
from app.services.pdf_service import save_pdf, extract_text as extract_pdf_text, extract_toc
from app.services.indexing_service import index_textbook
from app.services.guide_service import generate_page_guide, generate_chapter_guide
from app.services.chapter_service import detect_chapters
from app.services.storage import storage

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


async def _background_detect_chapters(textbook_id: str, server_path: str, total_pages: int):
    """TOC가 없을 때 LLM으로 챕터 구조를 감지한다."""
    async with async_session() as db:
        try:
            entries = await detect_chapters(server_path)
            for i, entry in enumerate(entries):
                next_page = None
                for j in range(i + 1, len(entries)):
                    if entries[j]["level"] <= entry["level"]:
                        next_page = entries[j]["page"] - 1
                        break
                chapter = Chapter(
                    id=str(uuid.uuid4()),
                    textbook_id=textbook_id,
                    level=entry["level"],
                    title=entry["title"],
                    page_start=entry["page"],
                    page_end=next_page or total_pages,
                )
                db.add(chapter)
            await db.commit()
            log.info("Background chapter detection done: textbook=%s chapters=%d", textbook_id, len(entries))
        except Exception:
            log.exception("Background chapter detection failed: textbook=%s", textbook_id)


@router.post("/upload")
async def upload_pdf(
    file: UploadFile = File(...),
    note_id: str | None = Form(None),
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
        # 방금 업로드한 중복본 삭제 (server_path는 이번 업로드의 storage key)
        storage.delete(server_path)
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

    # TOC 추출 및 저장
    toc_entries = extract_toc(server_path)
    if toc_entries:
        for i, entry in enumerate(toc_entries):
            next_page = None
            for j in range(i + 1, len(toc_entries)):
                if toc_entries[j]["level"] <= entry["level"]:
                    next_page = toc_entries[j]["page"] - 1
                    break
            chapter = Chapter(
                id=str(uuid.uuid4()),
                textbook_id=source.id,
                level=entry["level"],
                title=entry["title"],
                page_start=entry["page"],
                page_end=next_page or total_pages,
            )
            db.add(chapter)
        await db.commit()
        log.info("TOC saved: textbook=%s chapters=%d", source.id, len(toc_entries))
    else:
        # TOC 없으면 LLM으로 백그라운드 감지
        background_tasks.add_task(_background_detect_chapters, source.id, server_path, total_pages)

    background_tasks.add_task(_background_index, source.id, user_id, server_path)

    return {
        "id": source.id,
        "fileName": file_name,
        "totalPages": total_pages,
        "fileSize": file_size,
        "chapters": len(toc_entries),
        "indexing": "started",
    }


@router.get("/textbooks")
async def list_textbooks(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(TextbookSource)
        .where(TextbookSource.user_id == user_id)
        .order_by(TextbookSource.created_at.desc())
    )
    sources = result.scalars().all()
    return [
        {
            "id": s.id,
            "fileName": s.file_name,
            "totalPages": s.total_pages,
            "fileSize": s.file_size,
            "createdAt": s.created_at.isoformat() if s.created_at else None,
        }
        for s in sources
    ]


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

    # 로컬 스토리지(또는 레거시 경로)면 FileResponse, S3면 StreamingResponse
    local = storage.local_path(source.server_path)
    if local and os.path.exists(local):
        return FileResponse(local, media_type="application/pdf", filename=source.file_name)
    if os.path.exists(source.server_path):  # 레거시 행: server_path가 실제 파일 경로
        return FileResponse(source.server_path, media_type="application/pdf", filename=source.file_name)
    return StreamingResponse(
        storage.stream(source.server_path),
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="{source.file_name}"'},
    )


@router.get("/{textbook_id}/chapters")
async def get_chapters(
    textbook_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """교재의 챕터(TOC) 목록을 반환한다."""
    result = await db.execute(
        select(TextbookSource).where(
            TextbookSource.id == textbook_id,
            TextbookSource.user_id == user_id,
        )
    )
    if not result.scalar_one_or_none():
        raise HTTPException(status_code=404, detail="Textbook not found")

    chapters_result = await db.execute(
        select(Chapter)
        .where(Chapter.textbook_id == textbook_id)
        .order_by(Chapter.page_start)
    )
    chapters = chapters_result.scalars().all()
    return [
        {
            "id": c.id,
            "level": c.level,
            "title": c.title,
            "pageStart": c.page_start,
            "pageEnd": c.page_end,
        }
        for c in chapters
    ]


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


class PageGuideResponse(BaseModel):
    page: int
    topic: str = ""
    content: str = ""
    # Legacy fields (backward compat)
    key_points: list[str] = []
    exercises: list[str] = []
    connections: str = ""
    cached: bool


@router.get("/{textbook_id}/guide", response_model=PageGuideResponse)
async def get_page_guide(
    textbook_id: str,
    page: int,
    response_language: str = "Korean",
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """페이지별 학습 가이드 조회 (lazy 캐싱)."""
    log.info("Guide request: user=%s textbook=%s page=%d", user_id, textbook_id, page)

    # 교재 조회
    result = await db.execute(
        select(TextbookSource).where(
            TextbookSource.id == textbook_id,
            TextbookSource.user_id == user_id,
        )
    )
    source = result.scalar_one_or_none()
    if not source:
        raise HTTPException(status_code=404, detail="Textbook not found")

    if page < 1 or page > source.total_pages:
        raise HTTPException(status_code=400, detail="Invalid page number")

    # 캐시 확인
    cached_result = await db.execute(
        select(PageGuide).where(
            PageGuide.textbook_id == textbook_id,
            PageGuide.page == page,
        )
    )
    cached = cached_result.scalar_one_or_none()
    if cached:
        log.info("Guide cache hit: textbook=%s page=%d", textbook_id, page)
        data = json.loads(cached.content)
        # LLM이 connections를 dict로 반환한 경우 문자열로 변환
        if isinstance(data.get("connections"), dict):
            data["connections"] = json.dumps(data["connections"], ensure_ascii=False)
        return PageGuideResponse(page=page, cached=True, **data)

    # 캐시 미스: 페이지 텍스트 추출 → LLM 생성
    page_text = extract_pdf_text(source.server_path, page, page)
    if not page_text.strip():
        raise HTTPException(status_code=400, detail="Page has no extractable text")

    data = await generate_page_guide(page_text, response_language=response_language)
    if isinstance(data.get("connections"), dict):
        data["connections"] = json.dumps(data["connections"], ensure_ascii=False)

    # 캐시 저장
    guide = PageGuide(
        id=str(uuid.uuid4()),
        textbook_id=textbook_id,
        page=page,
        content=json.dumps(data, ensure_ascii=False),
    )
    db.add(guide)
    await db.commit()
    log.info("Guide generated and cached: textbook=%s page=%d", textbook_id, page)

    return PageGuideResponse(page=page, cached=False, **data)


class ChapterGuideResponse(BaseModel):
    chapter_id: str
    title: str
    page_start: int
    page_end: int
    topic: str
    key_concepts: list[str]
    study_order: list[str]
    common_mistakes: list[str]
    summary: str
    cached: bool


@router.get("/{textbook_id}/chapter-guide")
async def get_chapter_guide(
    textbook_id: str,
    chapter_id: str,
    response_language: str = "Korean",
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """챕터별 학습 가이드 조회 (lazy 캐싱)."""
    log.info("Chapter guide request: user=%s textbook=%s chapter=%s", user_id, textbook_id, chapter_id)

    # 챕터 조회
    result = await db.execute(
        select(Chapter).where(
            Chapter.id == chapter_id,
            Chapter.textbook_id == textbook_id,
        )
    )
    chapter = result.scalar_one_or_none()
    if not chapter:
        raise HTTPException(status_code=404, detail="Chapter not found")

    # 교재 조회 (서버 경로 필요)
    tb_result = await db.execute(
        select(TextbookSource).where(
            TextbookSource.id == textbook_id,
            TextbookSource.user_id == user_id,
        )
    )
    source = tb_result.scalar_one_or_none()
    if not source:
        raise HTTPException(status_code=404, detail="Textbook not found")

    # 캐시 확인 (page_guides 테이블 재활용, page=-1*chapter_page_start 로 구분)
    cache_key = -(chapter.page_start)  # 음수 page로 챕터 가이드 캐시 구분
    cached_result = await db.execute(
        select(PageGuide).where(
            PageGuide.textbook_id == textbook_id,
            PageGuide.page == cache_key,
        )
    )
    cached = cached_result.scalar_one_or_none()
    if cached:
        log.info("Chapter guide cache hit: chapter=%s", chapter_id)
        data = json.loads(cached.content)
        return ChapterGuideResponse(
            chapter_id=chapter_id,
            title=chapter.title,
            page_start=chapter.page_start,
            page_end=chapter.page_end or source.total_pages,
            cached=True,
            **data,
        )

    # 캐시 미스: 챕터 텍스트 추출 → LLM
    chapter_text = extract_pdf_text(
        source.server_path, chapter.page_start, chapter.page_end or source.total_pages
    )
    if not chapter_text.strip():
        raise HTTPException(status_code=400, detail="Chapter has no extractable text")

    data = await generate_chapter_guide(chapter_text, response_language=response_language)

    # 캐시 저장
    guide = PageGuide(
        id=str(uuid.uuid4()),
        textbook_id=textbook_id,
        page=cache_key,
        content=json.dumps(data, ensure_ascii=False),
    )
    db.add(guide)
    await db.commit()
    log.info("Chapter guide generated and cached: chapter=%s", chapter_id)

    return ChapterGuideResponse(
        chapter_id=chapter_id,
        title=chapter.title,
        page_start=chapter.page_start,
        page_end=chapter.page_end or source.total_pages,
        cached=False,
        **data,
    )
