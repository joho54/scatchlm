import logging

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.document import DocumentChunk
from app.services.embedding_service import embed_query

log = logging.getLogger(__name__)

DEFAULT_TOP_K = 3


async def search_relevant_chunks(
    db: AsyncSession,
    textbook_id: str,
    query_text: str,
    top_k: int = DEFAULT_TOP_K,
) -> list[DocumentChunk]:
    """쿼리 텍스트와 가장 유사한 청크를 검색한다."""
    query_embedding = await embed_query(query_text)

    result = await db.execute(
        select(DocumentChunk)
        .where(
            DocumentChunk.textbook_id == textbook_id,
            DocumentChunk.embedding.isnot(None),
        )
        .order_by(DocumentChunk.embedding.cosine_distance(query_embedding))
        .limit(top_k)
    )
    chunks = result.scalars().all()

    log.info(
        "RAG search: textbook=%s query='%s' results=%d",
        textbook_id, query_text[:50], len(chunks),
    )
    return chunks


def format_chunks_as_context(chunks: list[DocumentChunk]) -> str:
    """검색된 청크를 LLM 컨텍스트 문자열로 포매팅한다."""
    parts = []
    for chunk in chunks:
        parts.append(
            f"--- Reference (p.{chunk.page_start}-{chunk.page_end}) ---\n{chunk.content}"
        )
    return "\n\n".join(parts)
