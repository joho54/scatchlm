"""index_textbook의 ENABLE_EMBEDDING 게이트 회귀 — DB 불필요.

플래그가 false면 청킹·임베딩·PDF 열기를 일절 하지 않고 즉시 0을 반환해야 한다.
true면 기존 인덱싱 경로(_open_pdf → chunk → embed → DB 저장)를 그대로 수행한다.
"""
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services import indexing_service


@pytest.mark.asyncio
async def test_disabled_skips_without_touching_pdf_or_embedding():
    db = MagicMock()
    with patch.object(indexing_service.settings, "ENABLE_EMBEDDING", False), \
         patch.object(indexing_service, "_open_pdf") as open_pdf, \
         patch.object(indexing_service, "chunk_text_by_pages") as chunk, \
         patch.object(indexing_service, "embed_texts", new_callable=AsyncMock) as embed:
        result = await indexing_service.index_textbook(db, "tb-1", "user-1", "/x.pdf")

    assert result == 0
    open_pdf.assert_not_called()
    chunk.assert_not_called()
    embed.assert_not_called()
    db.add.assert_not_called()


@pytest.mark.asyncio
async def test_enabled_runs_indexing_pipeline():
    # _open_pdf → 2페이지 텍스트, 청킹 1개, 임베딩 1개
    page = MagicMock()
    page.get_text.return_value = "some text"
    doc = MagicMock()
    doc.__len__.return_value = 1
    doc.__getitem__.return_value = page

    db = MagicMock()
    db.commit = AsyncMock()
    chunk_data = {"content": "some text", "page_start": 1, "page_end": 1, "chunk_index": 0}

    with patch.object(indexing_service.settings, "ENABLE_EMBEDDING", True), \
         patch.object(indexing_service, "_open_pdf", return_value=doc), \
         patch.object(indexing_service, "chunk_text_by_pages", return_value=[chunk_data]), \
         patch.object(indexing_service, "embed_texts", new_callable=AsyncMock,
                      return_value=[[0.0] * 512]) as embed:
        result = await indexing_service.index_textbook(db, "tb-1", "user-1", "/x.pdf")

    assert result == 1
    embed.assert_awaited_once()
    db.add.assert_called_once()
    db.commit.assert_awaited_once()
