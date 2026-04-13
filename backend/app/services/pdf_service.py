import logging
import os
import time
import uuid

import fitz  # PyMuPDF
from fastapi import UploadFile

from app.core.config import settings

log = logging.getLogger(__name__)


async def save_pdf(file: UploadFile, user_id: str) -> tuple[str, str, int, int]:
    """PDF 파일을 서버에 저장하고 메타데이터를 반환한다.

    Returns:
        (server_path, file_name, total_pages, file_size)
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

    log.info("PDF saved: %s pages=%d size=%.1fKB path=%s", file.filename, total_pages, file_size / 1024, server_path)
    return server_path, file.filename, total_pages, file_size


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
