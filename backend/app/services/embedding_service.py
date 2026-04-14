import logging
import re
import time

import voyageai

from app.core.config import settings

log = logging.getLogger(__name__)

CHUNK_TARGET_TOKENS = 400  # 목표 청크 크기 (토큰 ≈ 단어 * 1.3)
CHUNK_MAX_CHARS = 2000  # 최대 문자 수 (안전 상한)
EMBEDDING_MODEL = "voyage-3-lite"


def _get_voyage_client() -> voyageai.Client:
    return voyageai.Client(api_key=settings.VOYAGE_API_KEY)


def chunk_text_by_pages(pages: list[tuple[int, str]]) -> list[dict]:
    """페이지별 텍스트를 단락 기반으로 청킹한다.

    Args:
        pages: [(page_number, text), ...]

    Returns:
        [{"content": str, "page_start": int, "page_end": int, "chunk_index": int}, ...]
    """
    chunks = []
    current_chunk = ""
    current_page_start = 0
    current_page_end = 0
    chunk_index = 0

    for page_num, page_text in pages:
        page_text = page_text.replace("\x00", "")  # PostgreSQL 호환
        paragraphs = re.split(r"\n{2,}", page_text.strip())

        for para in paragraphs:
            para = para.strip()
            if not para:
                continue

            if len(current_chunk) + len(para) > CHUNK_MAX_CHARS and current_chunk:
                chunks.append({
                    "content": current_chunk.strip(),
                    "page_start": current_page_start,
                    "page_end": current_page_end,
                    "chunk_index": chunk_index,
                })
                chunk_index += 1
                current_chunk = ""
                current_page_start = page_num

            if not current_chunk:
                current_page_start = page_num

            current_chunk += para + "\n\n"
            current_page_end = page_num

    if current_chunk.strip():
        chunks.append({
            "content": current_chunk.strip(),
            "page_start": current_page_start,
            "page_end": current_page_end,
            "chunk_index": chunk_index,
        })

    log.info("Chunking: %d pages → %d chunks", len(pages), len(chunks))
    return chunks


async def embed_texts(texts: list[str]) -> list[list[float]]:
    """텍스트 리스트를 Voyage AI로 임베딩한다."""
    client = _get_voyage_client()
    t0 = time.monotonic()
    result = client.embed(texts, model=EMBEDDING_MODEL, input_type="document")
    elapsed = int((time.monotonic() - t0) * 1000)
    log.info("Embedding: %d texts, model=%s, time=%dms", len(texts), EMBEDDING_MODEL, elapsed)
    return result.embeddings


async def embed_query(text: str) -> list[float]:
    """검색 쿼리를 임베딩한다."""
    client = _get_voyage_client()
    result = client.embed([text], model=EMBEDDING_MODEL, input_type="query")
    return result.embeddings[0]
