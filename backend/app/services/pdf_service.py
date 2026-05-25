import hashlib
import logging
import os
import time
import uuid

import fitz  # PyMuPDF
from fastapi import UploadFile

from app.core.config import settings
from app.services.storage import storage

log = logging.getLogger(__name__)


def _open_pdf(key: str) -> fitz.Document:
    """storage key 또는 (레거시) 로컬 경로로 PDF를 연다.

    기존 DB 행은 server_path가 "uploads/pdf/<file>.pdf"처럼 저장돼 있을 수 있어
    실제 파일이 존재하면 그대로 열고, 그렇지 않으면 storage에서 바이트를 가져온다.
    """
    if os.path.exists(key):
        return fitz.open(key)
    data = storage.read(key)
    return fitz.open(stream=data, filetype="pdf")


async def save_pdf(file: UploadFile, user_id: str) -> tuple[str, str, int, int, str]:
    """PDF 파일을 스토리지에 저장하고 메타데이터를 반환한다.

    Returns:
        (storage_key, file_name, total_pages, file_size, content_hash)
        storage_key는 백엔드와 무관한 논리 경로 (예: "<user>_<uuid>.pdf").
    """
    content = await file.read()
    file_size = len(content)

    if file_size > settings.MAX_PDF_SIZE_MB * 1024 * 1024:
        log.warning("PDF too large: %s (%.1fMB)", file.filename, file_size / 1024 / 1024)
        raise ValueError(f"PDF size exceeds {settings.MAX_PDF_SIZE_MB}MB limit")

    file_id = uuid.uuid4().hex
    ext = os.path.splitext(file.filename)[1] or ".pdf"
    key = f"{user_id}_{file_id}{ext}"

    storage.save(key, content)

    doc = fitz.open(stream=content, filetype="pdf")
    total_pages = len(doc)
    doc.close()

    content_hash = hashlib.sha256(content).hexdigest()

    log.info("PDF saved: %s pages=%d size=%.1fKB hash=%s key=%s",
             file.filename, total_pages, file_size / 1024, content_hash[:12], key)
    return key, file.filename, total_pages, file_size, content_hash


def extract_toc(key: str) -> list[dict]:
    """PDF에서 TOC(목차)를 추출한다. 없으면 빈 리스트 반환."""
    doc = _open_pdf(key)
    toc = doc.get_toc()
    doc.close()

    result = [{"level": lvl, "title": title, "page": page} for lvl, title, page in toc]
    log.info("PDF TOC extracted: %d entries from %s", len(result), key)
    return result


def extract_page_headers(key: str, lines_per_page: int = 5) -> list[dict]:
    """각 페이지의 상단 N줄을 추출한다. 챕터 감지용."""
    doc = _open_pdf(key)
    results = []
    for i in range(len(doc)):
        text = doc[i].get_text()
        header_lines = text.strip().split("\n")[:lines_per_page]
        header = "\n".join(header_lines).strip()
        if header:
            results.append({"page": i + 1, "header": header})
    doc.close()
    return results


def extract_text(key: str, page_start: int, page_end: int) -> str:
    """PDF에서 지정 페이지 범위의 텍스트를 추출한다. (1-indexed)"""
    t0 = time.monotonic()
    doc = _open_pdf(key)
    total = len(doc)

    start = max(0, page_start - 1)
    end = min(total, page_end)

    texts = []
    for i in range(start, end):
        page = doc[i]
        texts.append(f"--- Page {i + 1} ---\n{page.get_text()}")

    doc.close()
    result = "\n".join(texts)
    elapsed = int((time.monotonic() - t0) * 1000)
    log.info("PDF extract: pages=%d-%d chars=%d time=%dms", page_start, page_end, len(result), elapsed)
    return result
