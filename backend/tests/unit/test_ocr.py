"""OCR 스캔본 지원 회귀 — DB 불필요(순수/IO 함수만).

scanned-pdf-ocr-spec.md: 스캔 감지(§4.4)와 OCR 헤더 추출(§4.6)이 핵심 분기다.
"""
from unittest.mock import AsyncMock

import anthropic
import fitz  # PyMuPDF
import httpx
import pytest

from app.core.config import settings
from app.services import ocr_service
from app.services.pdf_service import (
    extract_text,
    extract_text_async,
    has_no_text_layer,
    headers_from_ocr_rows,
)


@pytest.mark.asyncio
async def test_ocr_page_blocked_on_400(monkeypatch):
    """콘텐츠 필터/잘못된 이미지 400(BadRequestError)은 잡을 죽이지 않고 blocked 결과로 격리.
    같은 이미지를 다시 보내도 같은 결과라 재시도 무의미 → 빈 페이지로 박제."""
    req = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    resp = httpx.Response(400, request=req)
    err = anthropic.BadRequestError(
        "Output blocked by content filtering policy", response=resp, body=None
    )
    monkeypatch.setattr(ocr_service.client.messages, "create", AsyncMock(side_effect=err))

    result = await ocr_service.ocr_page(b"\xff\xd8fake-jpeg")
    assert result.blocked is True
    assert result.text == ""
    assert result.cost_usd == 0.0  # 차단된 요청은 비용 미기록


@pytest.mark.asyncio
async def test_ocr_page_transient_error_propagates(monkeypatch):
    """일시 오류(연결 등)는 blocked로 삼키지 않고 전파 → 잡 error → 스위퍼 재개."""
    monkeypatch.setattr(
        ocr_service.client.messages, "create",
        AsyncMock(side_effect=anthropic.APIConnectionError(request=httpx.Request("POST", "https://x"))),
    )
    with pytest.raises(anthropic.APIConnectionError):
        await ocr_service.ocr_page(b"\xff\xd8fake-jpeg")


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


def test_ocr_monthly_limits_free_lt_pro():
    """월 OCR 건수는 per-file 천장과 함께 비용 상한을 형성. free < pro."""
    assert settings.OCR_MONTHLY_FILES_FREE < settings.OCR_MONTHLY_FILES_PRO
    assert settings.OCR_MAX_PAGES_PER_FILE > 0


def test_ocr_monthly_limit_for_tier():
    from app.core.quota import _ocr_monthly_limit_for_tier
    assert _ocr_monthly_limit_for_tier("pro") == settings.OCR_MONTHLY_FILES_PRO
    assert _ocr_monthly_limit_for_tier("normal") == settings.OCR_MONTHLY_FILES_FREE
    assert _ocr_monthly_limit_for_tier("anything-else") == settings.OCR_MONTHLY_FILES_FREE


def test_kst_month_bounds_rolls_over_year():
    """KST 달력 월 경계: 12월이면 다음 달은 이듬해 1월. 하한은 naive UTC."""
    from datetime import datetime, timezone
    from app.core.quota import _kst_month_bounds
    # 2026-12-15 09:00 UTC = 2026-12-15 18:00 KST → 월초 2026-12-01 KST, 다음달 2027-01-01 KST
    since, nxt = _kst_month_bounds(datetime(2026, 12, 15, 9, 0, tzinfo=timezone.utc))
    assert nxt.year == 2027 and nxt.month == 1 and nxt.day == 1
    assert since.tzinfo is None  # naive UTC (ocr_started_at 컬럼과 비교용)
    # 2026-12-01 00:00 KST == 2026-11-30 15:00 UTC
    assert (since.year, since.month, since.day, since.hour) == (2026, 11, 30, 15)


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


def test_has_no_text_layer_false_for_text_layer(tmp_path):
    doc = fitz.open()
    for _ in range(12):
        page = doc.new_page()
        page.insert_text((72, 72), "Plenty of extractable text on this page. " * 4)
    path = str(tmp_path / "text.pdf")
    doc.save(path)
    doc.close()
    assert has_no_text_layer(path, 12) is False


def test_has_no_text_layer_false_for_sparse_text(tmp_path):
    """텍스트가 적어도(과거엔 임계값 미만으로 스캔본 오인) 텍스트 레이어가 있으면 False — 이진 판정."""
    doc = fitz.open()
    for _ in range(12):
        page = doc.new_page()
        page.insert_text((72, 72), "x")  # 페이지당 1자 — 과거 30자 임계값이면 오탐
    path = str(tmp_path / "sparse.pdf")
    doc.save(path)
    doc.close()
    assert has_no_text_layer(path, 12) is False


def test_has_no_text_layer_true_for_blank_pages(tmp_path):
    """텍스트 레이어 없는(스캔본 모사) 빈 페이지 → OCR 제안 대상."""
    doc = fitz.open()
    for _ in range(12):
        doc.new_page()
    path = str(tmp_path / "blank.pdf")
    doc.save(path)
    doc.close()
    assert has_no_text_layer(path, 12) is True
