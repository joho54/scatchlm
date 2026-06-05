"""OCR 스캔본 지원 회귀 — DB 불필요(순수/IO 함수만).

scanned-pdf-ocr-spec.md: 스캔 감지(§4.4)와 OCR 헤더 추출(§4.6)이 핵심 분기다.
"""
import fitz  # PyMuPDF
import pytest

from app.core.config import settings
from app.services.pdf_service import (
    extract_text,
    extract_text_async,
    headers_from_ocr_rows,
    is_scanned_pdf,
)


class _Row:
    """OcrPageText 대역(page/content만 사용)."""
    def __init__(self, page: int, content: str):
        self.page = page
        self.content = content


class _Source:
    """TextbookSource 대역(extract_text_async가 읽는 필드만)."""
    def __init__(self, server_path: str, is_scanned: bool):
        self.id = "tb-test"
        self.server_path = server_path
        self.is_scanned = is_scanned


@pytest.mark.asyncio
async def test_extract_text_async_text_pdf_matches_legacy(tmp_path):
    """회귀(스펙 Risk): 텍스트 PDF 경로는 동작 불변 — 시그니처 변경 후에도
    extract_text_async가 기존 extract_text와 동일 결과를 내고 DB를 건드리지 않아야 한다."""
    doc = fitz.open()
    for _ in range(3):
        page = doc.new_page()
        page.insert_text((72, 72), "Same extraction path as before. " * 3)
    path = str(tmp_path / "text.pdf")
    doc.save(path)
    doc.close()

    source = _Source(path, is_scanned=False)
    # db=None: 비스캔본 경로는 DB를 절대 await하지 않음(접근 시 AttributeError로 실패).
    result = await extract_text_async(None, source, 1, 3)
    assert result == extract_text(path, 1, 3)


def test_enable_ocr_off_by_default():
    """기능 토글은 기본 비활성 — 켜기 전 OCR 예산 설정 강제(§1.4)."""
    assert settings.ENABLE_OCR is False


def test_tier_from_cap_roundtrip():
    """스위퍼는 JWT가 없어 저장된 ocr_cap으로 tier를 역추론한다."""
    from app.routers.pdf import _tier_from_cap
    assert _tier_from_cap(settings.OCR_FREE_CAP_PAGES) == "normal"
    assert _tier_from_cap(settings.OCR_MAX_PAGES_PER_BOOK) == "pro"
    assert _tier_from_cap(None) == "pro"  # cap 미상 → pro(백스톱)로 취급


def test_headers_from_ocr_rows_skips_blank_and_truncates():
    rows = [
        _Row(1, "Chapter 1\nIntroduction\n\nbody1\nbody2\nbody3\nbody4"),
        _Row(2, "   \n  \n"),  # 빈 헤더 → 제외
    ]
    headers = headers_from_ocr_rows(rows, lines_per_page=5)
    assert len(headers) == 1
    assert headers[0]["page"] == 1
    # 빈 줄 제거 후 상위 5줄까지만 → 최대 4개의 개행
    assert headers[0]["header"].count("\n") <= 4
    assert "Chapter 1" in headers[0]["header"]


def test_is_scanned_pdf_false_for_text_layer(tmp_path):
    doc = fitz.open()
    for _ in range(12):
        page = doc.new_page()
        page.insert_text((72, 72), "Plenty of extractable text on this page. " * 4)
    path = str(tmp_path / "text.pdf")
    doc.save(path)
    doc.close()
    assert is_scanned_pdf(path, 12) is False


def test_is_scanned_pdf_true_for_blank_pages(tmp_path):
    """텍스트 레이어 없는(스캔본 모사) 빈 페이지 → 스캔본 판정."""
    doc = fitz.open()
    for _ in range(12):
        doc.new_page()
    path = str(tmp_path / "blank.pdf")
    doc.save(path)
    doc.close()
    assert is_scanned_pdf(path, 12) is True
