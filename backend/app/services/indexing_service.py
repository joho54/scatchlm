import logging

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.document import DocumentChunk
from app.services.embedding_service import chunk_text_by_pages, embed_texts
from app.services.pdf_service import _open_pdf

log = logging.getLogger(__name__)


async def index_textbook(
    db: AsyncSession,
    textbook_id: str,
    user_id: str,
    server_path: str,
) -> int:
    """PDF를 청킹하고 임베딩하여 document_chunks에 저장한다.

    Returns:
        생성된 청크 수
    """
    # 임베딩 인덱싱 비활성화 시 즉시 스킵 (Voyage 비용·지연 제거).
    # RAG 검색 경로는 그대로 두되 소비할 청크가 없을 뿐이다. settings.ENABLE_EMBEDDING 참고.
    if not settings.ENABLE_EMBEDDING:
        log.info("Embedding indexing disabled (ENABLE_EMBEDDING=false), skip textbook %s", textbook_id)
        return 0

    # PDF에서 페이지별 텍스트 추출
    doc = _open_pdf(server_path)
    pages = []
    for i in range(len(doc)):
        text = doc[i].get_text().replace("\x00", "")
        if text.strip():
            pages.append((i + 1, text))
    doc.close()

    if not pages:
        log.warning("No text extracted from PDF: %s", server_path)
        return 0

    # 청킹
    chunks = chunk_text_by_pages(pages)
    if not chunks:
        return 0

    # 임베딩 (배치)
    texts = [c["content"] for c in chunks]
    embeddings = await embed_texts(texts)

    # DB 저장
    for chunk_data, embedding in zip(chunks, embeddings):
        db.add(DocumentChunk(
            textbook_id=textbook_id,
            user_id=user_id,
            chunk_index=chunk_data["chunk_index"],
            page_start=chunk_data["page_start"],
            page_end=chunk_data["page_end"],
            content=chunk_data["content"],
            embedding=embedding,
        ))
    await db.commit()

    log.info("Indexed textbook %s: %d chunks", textbook_id, len(chunks))
    return len(chunks)
