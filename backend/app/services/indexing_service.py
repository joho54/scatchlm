import logging

import fitz
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.document import DocumentChunk
from app.services.embedding_service import chunk_text_by_pages, embed_texts

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
    # PDF에서 페이지별 텍스트 추출
    doc = fitz.open(server_path)
    pages = []
    for i in range(len(doc)):
        text = doc[i].get_text()
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
