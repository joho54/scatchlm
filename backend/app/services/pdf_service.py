import hashlib
import logging
import os
import time
import uuid

import fitz  # PyMuPDF
from fastapi import UploadFile

from app.core.config import settings

log = logging.getLogger(__name__)


async def save_pdf(file: UploadFile, user_id: str) -> tuple[str, str, int, int, str]:
    """PDF 파일을 서버에 저장하고 메타데이터를 반환한다.

    Returns:
        (server_path, file_name, total_pages, file_size, content_hash)
    """
    os.makedirs(settings.PDF_UPLOAD_DIR, exist_ok=True)

    file_id = uuid.uuid4().hex
    ext = os.path.splitext(file.filename)[1]
    server_path = os.path.join(settings.PDF_UPLOAD_DIR, f"{user_id}_{file_id}{ext}")

    content = await file.read()
    file_size = len(content)

    if file_size > settings.MAX_PDF_SIZE_MB * 1024 * 1024:
        log.warning("PDF too large: %s (%.1fMB)", file.filename, file_size / 1024 / 1024)
        raise ValueError(f"PDF size exceeds {settings.MAX_PDF_SIZE_MB}MB limit")

    with open(server_path, "wb") as f:
        f.write(content)

    doc = fitz.open(server_path)
    total_pages = len(doc)
    doc.close()

    content_hash = hashlib.sha256(content).hexdigest()

    log.info("PDF saved: %s pages=%d size=%.1fKB hash=%s path=%s", file.filename, total_pages, file_size / 1024, content_hash[:12], server_path)
    return server_path, file.filename, total_pages, file_size, content_hash


def extract_toc(server_path: str) -> list[dict]:
    """PDF에서 TOC(목차)를 추출한다. 없으면 빈 리스트 반환.

    Returns:
        [{"level": 1, "title": "Chapter 1", "page": 5}, ...]
    """
    doc = fitz.open(server_path)
    toc = doc.get_toc()  # [[level, title, page], ...]
    doc.close()

    result = [{"level": lvl, "title": title, "page": page} for lvl, title, page in toc]
    log.info("PDF TOC extracted: %d entries from %s", len(result), server_path)
    return result


def extract_page_headers(server_path: str, lines_per_page: int = 5) -> list[dict]:
    """각 페이지의 상단 N줄을 추출한다. 챕터 감지용.

    Returns:
        [{"page": 1, "header": "Chapter 1\\nIntroduction\\n..."}, ...]
    """
    doc = fitz.open(server_path)
    results = []
    for i in range(len(doc)):
        text = doc[i].get_text()
        header_lines = text.strip().split("\n")[:lines_per_page]
        header = "\n".join(header_lines).strip()
        if header:
            results.append({"page": i + 1, "header": header})
    doc.close()
    return results


def extract_text(server_path: str, page_start: int, page_end: int) -> str:
    """PDF에서 지정 페이지 범위의 텍스트를 추출한다. (1-indexed)"""
    t0 = time.monotonic()
    doc = fitz.open(server_path)
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
