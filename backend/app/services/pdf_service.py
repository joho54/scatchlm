import os
import uuid

import fitz  # PyMuPDF
from fastapi import UploadFile

from app.core.config import settings


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
        raise ValueError(f"PDF size exceeds {settings.MAX_PDF_SIZE_MB}MB limit")

    with open(server_path, "wb") as f:
        f.write(content)

    doc = fitz.open(server_path)
    total_pages = len(doc)
    doc.close()

    return server_path, file.filename, total_pages, file_size


def extract_text(server_path: str, page_start: int, page_end: int) -> str:
    """PDF에서 지정 페이지 범위의 텍스트를 추출한다. (1-indexed)"""
    doc = fitz.open(server_path)
    total = len(doc)

    start = max(0, page_start - 1)
    end = min(total, page_end)

    texts = []
    for i in range(start, end):
        page = doc[i]
        texts.append(f"--- Page {i + 1} ---\n{page.get_text()}")

    doc.close()
    return "\n".join(texts)
