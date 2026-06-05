import asyncio
import json
import logging
import os
import uuid
from datetime import datetime, timezone, timedelta
from urllib.parse import quote

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, UploadFile, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, update

from app.core.auth import get_current_user_id, get_verified_payload, get_tier, get_role
from app.core.config import settings
from app.core.database import get_db, async_session
from app.core.quota import check_daily_quota, check_ocr_quota
from app.models.textbook import TextbookSource
from app.models.guide import PageGuide
from app.models.chapter import Chapter
from app.models.feedback import AIResponse
from app.models.document import DocumentChunk
from app.models.ocr import OcrPageText
from app.services.pdf_service import (
    save_pdf,
    extract_text as extract_pdf_text,
    extract_text_async,
    extract_toc,
    is_scanned_pdf,
    get_ocr_pages,
    headers_from_ocr_rows,
    _open_pdf,
)
from app.services.indexing_service import index_textbook
from app.services.guide_service import generate_page_guide, generate_chapter_guide
from app.services.chapter_service import detect_chapters
from app.services.ocr_service import render_page, ocr_page
from app.services.usage_service import log_llm_usage
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


def _save_detected_chapters(db, textbook_id: str, entries: list[dict], total_pages: int) -> None:
    """감지된 챕터 엔트리를 page_end 계산과 함께 세션에 추가한다(커밋은 호출부)."""
    for i, entry in enumerate(entries):
        next_page = None
        for j in range(i + 1, len(entries)):
            if entries[j]["level"] <= entry["level"]:
                next_page = entries[j]["page"] - 1
                break
        db.add(Chapter(
            id=str(uuid.uuid4()),
            textbook_id=textbook_id,
            level=entry["level"],
            title=entry["title"],
            page_start=entry["page"],
            page_end=next_page or total_pages,
        ))


async def _background_detect_chapters(textbook_id: str, server_path: str, total_pages: int):
    """TOC가 없을 때 LLM으로 챕터 구조를 감지한다(텍스트 레이어 PDF)."""
    async with async_session() as db:
        try:
            entries = await detect_chapters(server_path)
            _save_detected_chapters(db, textbook_id, entries, total_pages)
            await db.commit()
            log.info("Background chapter detection done: textbook=%s chapters=%d", textbook_id, len(entries))
        except Exception:
            log.exception("Background chapter detection failed: textbook=%s", textbook_id)


async def _detect_chapters_from_ocr(db, textbook_id: str, server_path: str, total_pages: int) -> None:
    """OCR된 페이지 텍스트에서 챕터 구조를 감지해 저장한다(스캔본). 이미 챕터가 있으면 호출되지 않음."""
    rows = (await db.execute(
        select(OcrPageText).where(OcrPageText.textbook_id == textbook_id).order_by(OcrPageText.page)
    )).scalars().all()
    headers = headers_from_ocr_rows(rows)
    if not headers:
        return
    entries = await detect_chapters(server_path, headers=headers)
    _save_detected_chapters(db, textbook_id, entries, total_pages)
    await db.commit()
    log.info("OCR chapter detection done: textbook=%s chapters=%d", textbook_id, len(entries))


# OCR 스위퍼(자동 재개) 파라미터.
OCR_STALE_MINUTES = 15          # running이 이만큼 갱신 안 되면 프로세스 사망으로 판별 → error로 강등
OCR_SWEEP_INTERVAL_SEC = 600    # 스위퍼 주기(10분). 예산은 KST 자정에 풀리므로 그 안에 재개됨
OCR_SWEEP_MAX_PER_CYCLE = 10    # 한 사이클 동시 재개 상한(스탬피드 방지)


def _utcnow():
    """모델의 naive UTC 컬럼과 맞춘 현재 시각."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _tier_from_cap(cap: int | None) -> str:
    """저장된 ocr_cap으로 tier를 역추론(스위퍼는 JWT가 없음)."""
    return "normal" if cap == settings.OCR_FREE_CAP_PAGES else "pro"


async def _background_ocr(textbook_id: str, user_id: str, tier: str):
    """스캔본 PDF를 페이지 순차 OCR한다. 매 페이지 즉시 커밋 → 중단돼도 손실 0, 재개 가능.

    시작 시 ocr_status를 원자적으로 claim('running')해서 워커 2개 환경의 중복 실행을 막는다.
    종료 상태: complete / capped(free 캡) / paused(예산 초과) / error(예외).
    paused·error·stale-running은 _ocr_sweeper_loop가 자동 재개한다.
    """
    async with async_session() as db:
        # 원자적 claim — pending/paused/error만 running으로 전이. 이미 running/complete/capped면 0행 → 타 워커가 처리 중.
        claimed = (await db.execute(
            update(TextbookSource)
            .where(
                TextbookSource.id == textbook_id,
                TextbookSource.ocr_status.in_(["pending", "paused", "error"]),
            )
            .values(ocr_status="running", ocr_updated_at=_utcnow())
            .returning(TextbookSource.id)
        )).first()
        await db.commit()
        if claimed is None:
            log.info("OCR job: not claimable (handled elsewhere or done): textbook=%s", textbook_id)
            return

        source = (await db.execute(
            select(TextbookSource).where(TextbookSource.id == textbook_id)
        )).scalar_one_or_none()
        if not source:
            log.warning("OCR job: textbook not found id=%s", textbook_id)
            return

        cap = source.ocr_cap or settings.OCR_MAX_PAGES_PER_BOOK
        target = min(source.total_pages, cap)
        is_capped_tier = tier != "pro" and target < source.total_pages

        try:
            done_pages = set((await db.execute(
                select(OcrPageText.page).where(OcrPageText.textbook_id == textbook_id)
            )).scalars().all())

            doc = _open_pdf(source.server_path)
            status = "complete"
            try:
                for page in range(1, target + 1):
                    if page in done_pages:
                        continue
                    if await check_ocr_quota(user_id, db):
                        status = "paused"
                        log.info("OCR job paused (quota): textbook=%s at page=%d", textbook_id, page)
                        break
                    image_bytes = render_page(doc, page - 1)
                    result = await ocr_page(image_bytes)
                    db.add(OcrPageText(
                        textbook_id=textbook_id,
                        page=page,
                        content=(result.text or "").replace("\x00", ""),
                    ))
                    source.ocr_pages_done = (source.ocr_pages_done or 0) + 1
                    source.ocr_updated_at = _utcnow()  # 하트비트
                    await log_llm_usage(
                        db, user_id=user_id, model=result.model,
                        input_tokens=result.input_tokens, output_tokens=result.output_tokens,
                        cost_usd=result.cost_usd, latency_ms=result.latency_ms,
                        task_type="ocr",
                    )
                    await db.commit()  # 매 페이지 즉시 커밋 → 손실 0 / 재개
            finally:
                doc.close()

            if status == "complete" and is_capped_tier:
                status = "capped"
            source.ocr_status = status
            source.ocr_updated_at = _utcnow()
            await db.commit()
            log.info("OCR job done: textbook=%s status=%s done=%d target=%d",
                     textbook_id, status, source.ocr_pages_done, target)

            # 충분히 OCR되면(complete/capped) 챕터 감지 — TOC/기존 챕터가 없을 때만.
            if status in ("complete", "capped"):
                existing = await db.scalar(
                    select(func.count()).select_from(Chapter).where(Chapter.textbook_id == textbook_id)
                )
                if not existing:
                    await _detect_chapters_from_ocr(db, textbook_id, source.server_path, source.total_pages)
        except Exception:
            log.exception("Background OCR failed: textbook=%s", textbook_id)
            try:
                source.ocr_status = "error"
                source.ocr_updated_at = _utcnow()
                await db.commit()
            except Exception:
                log.exception("OCR job: failed to mark error: textbook=%s", textbook_id)


async def _ocr_sweep_once():
    """재개 가능한 스캔본을 한 번 스윕한다: stale-running 강등 → paused(예산 회복)·error 재개.

    워커 2개 환경에서도 _background_ocr의 원자 claim과 stale UPDATE의 행 잠금으로 중복은 무해하다.
    """
    async with async_session() as db:
        # 1) 하트비트가 끊긴 running(프로세스 사망)을 error로 강등 → 재개 대상화.
        await db.execute(
            update(TextbookSource)
            .where(
                TextbookSource.ocr_status == "running",
                TextbookSource.ocr_updated_at < _utcnow() - timedelta(minutes=OCR_STALE_MINUTES),
            )
            .values(ocr_status="error")
        )
        await db.commit()
        # 2) 재개 후보 수집.
        rows = (await db.execute(
            select(
                TextbookSource.id, TextbookSource.user_id,
                TextbookSource.ocr_status, TextbookSource.ocr_cap,
            ).where(
                TextbookSource.is_scanned.is_(True),
                TextbookSource.ocr_status.in_(["paused", "error"]),
            )
        )).all()

    resumed = 0
    for tid, uid, status, cap in rows:
        if resumed >= OCR_SWEEP_MAX_PER_CYCLE:
            log.info("OCR sweep: per-cycle cap hit, deferring %d candidates", len(rows) - resumed)
            break
        # paused(예산)는 예산이 회복됐을 때만 재개. error는 항상 재시도.
        if status == "paused":
            async with async_session() as db2:
                if await check_ocr_quota(uid, db2):
                    continue  # 아직 예산 초과 → 다음 사이클
        asyncio.create_task(_background_ocr(tid, uid, _tier_from_cap(cap)))
        resumed += 1
    if resumed:
        log.info("OCR sweep: resumed=%d", resumed)


async def _ocr_sweeper_loop():
    """앱 시작 시 기동되는 주기적 OCR 재개 루프. ENABLE_OCR일 때만 main에서 띄운다."""
    log.info("OCR sweeper started: interval=%ds stale=%dmin", OCR_SWEEP_INTERVAL_SEC, OCR_STALE_MINUTES)
    while True:
        try:
            await _ocr_sweep_once()
        except Exception:
            log.exception("OCR sweep cycle failed")
        await asyncio.sleep(OCR_SWEEP_INTERVAL_SEC)


@router.post("/upload")
async def upload_pdf(
    file: UploadFile = File(...),
    note_id: str | None = Form(None),
    background_tasks: BackgroundTasks = BackgroundTasks(),
    payload: dict = Depends(get_verified_payload),
    db: AsyncSession = Depends(get_db),
):
    user_id = payload["sub"]
    tier = get_tier(payload)
    log.info("PDF upload: user=%s tier=%s note=%s file=%s", user_id, tier, note_id, file.filename)

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

        # 기존 인덱싱이 비어있으면 (이전 백그라운드 인덱싱 실패) 재트리거
        chunk_count = await db.scalar(
            select(func.count()).select_from(DocumentChunk).where(
                DocumentChunk.textbook_id == existing_source.id
            )
        )
        indexing_status = "complete"
        if not chunk_count:
            log.warning(
                "PDF duplicate has 0 chunks, re-triggering indexing: textbook=%s",
                existing_source.id,
            )
            background_tasks.add_task(
                _background_index,
                existing_source.id,
                existing_source.user_id,
                existing_source.server_path,
            )
            indexing_status = "started"

        # 스캔본이 미완(pending/paused/error)인 채 멈춰 있으면 재업로드로 즉시 재개한다.
        # (주기 스위퍼도 결국 재개하지만, 재업로드는 즉시 트리거. 원자 claim으로 중복 무해.)
        if existing_source.is_scanned and existing_source.ocr_status in ("pending", "paused", "error"):
            log.info("PDF duplicate scanned, resuming OCR: textbook=%s status=%s",
                     existing_source.id, existing_source.ocr_status)
            background_tasks.add_task(
                _background_ocr, existing_source.id, existing_source.user_id, tier
            )

        return {
            "id": existing_source.id,
            "fileName": existing_source.file_name,
            "totalPages": existing_source.total_pages,
            "fileSize": existing_source.file_size,
            "is_scanned": existing_source.is_scanned,
            "ocr_status": existing_source.ocr_status,
            "indexing": indexing_status,
        }

    log.info("PDF saved: file=%s pages=%d size=%dKB path=%s", file_name, total_pages, file_size // 1024, server_path)

    # 스캔본(이미지) PDF 감지 — ENABLE_OCR 토글이 꺼져 있으면 항상 텍스트 PDF로 취급(기존 흐름).
    is_scanned = settings.ENABLE_OCR and is_scanned_pdf(server_path, total_pages)
    ocr_cap = None
    if is_scanned:
        ocr_cap = settings.OCR_FREE_CAP_PAGES if tier != "pro" else settings.OCR_MAX_PAGES_PER_BOOK

    source = TextbookSource(
        user_id=user_id,
        note_id=note_id,
        file_name=file_name,
        server_path=server_path,
        total_pages=total_pages,
        file_size=file_size,
        content_hash=content_hash,
        is_scanned=is_scanned,
        ocr_status="pending" if is_scanned else None,
        ocr_cap=ocr_cap,
    )
    db.add(source)
    try:
        await db.commit()
        await db.refresh(source)
        log.info("PDF record created: id=%s user=%s note=%s", source.id, user_id, note_id)
    except Exception:
        log.exception("DB commit failed: user=%s note=%s file=%s", user_id, note_id, file_name)
        raise HTTPException(status_code=500, detail="Database error")

    # TOC 추출 및 저장 (bookmarks — 스캔본도 임베디드 TOC가 있으면 동작)
    toc_entries = extract_toc(server_path)
    if toc_entries:
        _save_detected_chapters(db, source.id, toc_entries, total_pages)
        await db.commit()
        log.info("TOC saved: textbook=%s chapters=%d", source.id, len(toc_entries))
    elif not is_scanned:
        # TOC 없는 텍스트 PDF → LLM으로 백그라운드 감지.
        # 스캔본은 텍스트 레이어가 비어 있으므로 OCR 잡 완료 후에 감지(_background_ocr 참고).
        background_tasks.add_task(_background_detect_chapters, source.id, server_path, total_pages)

    if is_scanned:
        background_tasks.add_task(_background_ocr, source.id, user_id, tier)

    background_tasks.add_task(_background_index, source.id, user_id, server_path)

    return {
        "id": source.id,
        "fileName": file_name,
        "totalPages": total_pages,
        "fileSize": file_size,
        "chapters": len(toc_entries),
        "is_scanned": is_scanned,
        "ocr_status": source.ocr_status,
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
            "is_scanned": s.is_scanned,
            "ocr_status": s.ocr_status,
            "ocr_pages_done": s.ocr_pages_done or 0,
            "ocr_pages_total": (min(s.total_pages, s.ocr_cap) if s.ocr_cap else s.total_pages) if s.is_scanned else 0,
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
    # Content-Disposition 헤더는 latin-1로만 인코딩되므로(RFC 7230) 비-ASCII 파일명은
    # RFC 5987 방식(filename*=UTF-8''<percent-encoded>)으로 실어야 한다.
    # FileResponse는 starlette가 내부에서 처리하지만 StreamingResponse는 직접 만들어야 한다.
    return StreamingResponse(
        storage.stream(source.server_path),
        media_type="application/pdf",
        headers={
            "Content-Disposition": f"inline; filename*=UTF-8''{quote(source.file_name)}"
        },
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


class PdfStatusResponse(BaseModel):
    is_scanned: bool
    ocr_status: str | None = None  # 텍스트 PDF는 null
    ocr_pages_done: int = 0
    ocr_pages_total: int = 0
    total_pages: int
    capped: bool = False
    cap_limit: int | None = None  # 적용된 캡 (free=50, pro=null)
    chapters_ready: bool = False


@router.get("/{textbook_id}/status", response_model=PdfStatusResponse)
async def get_pdf_status(
    textbook_id: str,
    payload: dict = Depends(get_verified_payload),
    db: AsyncSession = Depends(get_db),
):
    """OCR/인덱싱 진행 상태 (docs/scanned-pdf-ocr-spec.md §3.2-b). iOS 폴링용."""
    user_id = payload["sub"]
    source = (await db.execute(
        select(TextbookSource).where(
            TextbookSource.id == textbook_id,
            TextbookSource.user_id == user_id,
        )
    )).scalar_one_or_none()
    if not source:
        raise HTTPException(status_code=404, detail="Textbook not found")

    chapters_ready = bool(await db.scalar(
        select(func.count()).select_from(Chapter).where(Chapter.textbook_id == textbook_id)
    ))

    if not source.is_scanned:
        return PdfStatusResponse(
            is_scanned=False,
            ocr_status=None,
            total_pages=source.total_pages,
            chapters_ready=chapters_ready,
        )

    tier = get_tier(payload)
    cap = source.ocr_cap
    ocr_pages_total = min(source.total_pages, cap) if cap else source.total_pages
    return PdfStatusResponse(
        is_scanned=True,
        ocr_status=source.ocr_status,
        ocr_pages_done=source.ocr_pages_done or 0,
        ocr_pages_total=ocr_pages_total,
        total_pages=source.total_pages,
        capped=source.ocr_status == "capped",
        cap_limit=cap if tier != "pro" else None,
        chapters_ready=chapters_ready,
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

    text = await extract_text_async(db, source, page_start, page_end)
    log.info("PDF extract done: textbook=%s pages=%d-%d chars=%d", textbook_id, page_start, page_end, len(text))
    return {"text": text, "pages": f"{page_start}-{page_end}"}


def _raise_ocr_incomplete(source: TextbookSource, page: int | None):
    """스캔본 OCR 미완 시 409 ocr_incomplete (capped면 Pro 업셀 트리거)."""
    capped = source.ocr_status == "capped"
    raise HTTPException(
        status_code=409,
        detail={
            "detail": "OCR not complete for this page/chapter",
            "code": "ocr_incomplete",
            "ocr_status": source.ocr_status,
            "capped": capped,
            "page": page,
        },
    )


class PageGuideResponse(BaseModel):
    page: int
    topic: str = ""
    content: str = ""
    # Legacy fields (backward compat)
    key_points: list[str] = []
    exercises: list[str] = []
    connections: str = ""
    cached: bool
    feedback_id: str | None = None  # AIResponse id — 평가 대상


@router.get("/{textbook_id}/guide", response_model=PageGuideResponse)
async def get_page_guide(
    textbook_id: str,
    page: int,
    response_language: str = "Korean",
    payload: dict = Depends(get_verified_payload),
    db: AsyncSession = Depends(get_db),
):
    """페이지별 학습 가이드 조회 (lazy 캐싱)."""
    user_id = payload["sub"]
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
            PageGuide.response_language == response_language,
        )
    )
    cached = cached_result.scalar_one_or_none()
    if cached:
        log.info("Guide cache hit: textbook=%s page=%d lang=%s", textbook_id, page, response_language)
        data = json.loads(cached.content)
        # LLM이 connections를 dict로 반환한 경우 문자열로 변환
        if isinstance(data.get("connections"), dict):
            data["connections"] = json.dumps(data["connections"], ensure_ascii=False)
        return PageGuideResponse(page=page, cached=True, feedback_id=cached.ai_response_id, **data)

    # 캐시 미스: 생성 비용 발생 → 쿼터 체크
    await check_daily_quota(user_id, get_tier(payload), db, is_admin=get_role(payload) == "admin")

    # 텍스트 추출 (스캔본은 OCR 캐시). 미OCR 페이지면 409 ocr_incomplete.
    if source.is_scanned:
        present = await get_ocr_pages(db, textbook_id, page, page)
        if page not in present:
            _raise_ocr_incomplete(source, page)
        page_text = await extract_text_async(db, source, page, page)
    else:
        page_text = extract_pdf_text(source.server_path, page, page)
    if not page_text.strip():
        raise HTTPException(status_code=400, detail="Page has no extractable text")

    data = await generate_page_guide(page_text, response_language=response_language)
    if isinstance(data.get("connections"), dict):
        data["connections"] = json.dumps(data["connections"], ensure_ascii=False)

    # AIResponse 적재 — 평가 대상
    ai_resp = AIResponse(
        user_id=user_id,
        note_id=None,
        task_type="page_guide",
        language="",
        response_language=response_language,
        model="page-guide",
        textbook_id=textbook_id,
        current_page=page,
        has_textbook_context=True,
        response_content=json.dumps(data, ensure_ascii=False),
    )
    db.add(ai_resp)
    await db.flush()  # ai_resp.id 확보

    # 캐시 저장
    guide = PageGuide(
        id=str(uuid.uuid4()),
        textbook_id=textbook_id,
        page=page,
        response_language=response_language,
        content=json.dumps(data, ensure_ascii=False),
        ai_response_id=ai_resp.id,
    )
    db.add(guide)
    await db.commit()
    log.info("Guide generated and cached: textbook=%s page=%d lang=%s", textbook_id, page, response_language)

    return PageGuideResponse(page=page, cached=False, feedback_id=ai_resp.id, **data)


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
    feedback_id: str | None = None


@router.get("/{textbook_id}/chapter-guide")
async def get_chapter_guide(
    textbook_id: str,
    chapter_id: str,
    response_language: str = "Korean",
    payload: dict = Depends(get_verified_payload),
    db: AsyncSession = Depends(get_db),
):
    """챕터별 학습 가이드 조회 (lazy 캐싱)."""
    user_id = payload["sub"]
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
            PageGuide.response_language == response_language,
        )
    )
    cached = cached_result.scalar_one_or_none()
    if cached:
        log.info("Chapter guide cache hit: chapter=%s lang=%s", chapter_id, response_language)
        data = json.loads(cached.content)
        return ChapterGuideResponse(
            chapter_id=chapter_id,
            title=chapter.title,
            page_start=chapter.page_start,
            page_end=chapter.page_end or source.total_pages,
            cached=True,
            feedback_id=cached.ai_response_id,
            **data,
        )

    # 캐시 미스: 생성 비용 발생 → 쿼터 체크
    await check_daily_quota(user_id, get_tier(payload), db, is_admin=get_role(payload) == "admin")

    page_end = chapter.page_end or source.total_pages
    # 텍스트 추출 (스캔본은 OCR 캐시). CoT는 챕터 전체 텍스트가 필요하므로
    # 1차는 챕터 전체가 OCR 완료됐을 때만 생성, 그 외엔 409 ocr_incomplete (§6.x-5).
    if source.is_scanned:
        present = await get_ocr_pages(db, textbook_id, chapter.page_start, page_end)
        missing = [p for p in range(chapter.page_start, page_end + 1) if p not in present]
        if missing:
            _raise_ocr_incomplete(source, None)
        chapter_text = await extract_text_async(db, source, chapter.page_start, page_end)
    else:
        chapter_text = extract_pdf_text(source.server_path, chapter.page_start, page_end)
    if not chapter_text.strip():
        raise HTTPException(status_code=400, detail="Chapter has no extractable text")

    data = await generate_chapter_guide(chapter_text, response_language=response_language)

    # AIResponse 적재
    ai_resp = AIResponse(
        user_id=user_id,
        note_id=None,
        task_type="chapter_guide",
        language="",
        response_language=response_language,
        model="chapter-guide",
        textbook_id=textbook_id,
        current_page=chapter.page_start,
        has_textbook_context=True,
        response_content=json.dumps(data, ensure_ascii=False),
    )
    db.add(ai_resp)
    await db.flush()

    # 캐시 저장
    guide = PageGuide(
        id=str(uuid.uuid4()),
        textbook_id=textbook_id,
        page=cache_key,
        response_language=response_language,
        content=json.dumps(data, ensure_ascii=False),
        ai_response_id=ai_resp.id,
    )
    db.add(guide)
    await db.commit()
    log.info("Chapter guide generated and cached: chapter=%s lang=%s", chapter_id, response_language)

    return ChapterGuideResponse(
        chapter_id=chapter_id,
        title=chapter.title,
        page_start=chapter.page_start,
        page_end=chapter.page_end or source.total_pages,
        cached=False,
        feedback_id=ai_resp.id,
        **data,
    )
