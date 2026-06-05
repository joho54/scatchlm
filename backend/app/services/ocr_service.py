"""스캔본(이미지) PDF OCR 서비스 (docs/scanned-pdf-ocr-spec.md §4.2).

PyMuPDF로 페이지를 렌더 → Claude Haiku Vision으로 "원문만" 추출.
이미 통합된 anthropic SDK를 재사용하므로 신규 벤더·인증이 0.
"""
from __future__ import annotations

import base64
import logging
import time
from dataclasses import dataclass

import anthropic
import fitz  # PyMuPDF

from app.core.config import settings
from app.core.log_sanitize import loglen
from app.services.feedback_service import estimate_cost_from_usage

log = logging.getLogger(__name__)

OCR_MODEL = "claude-haiku-4-5-20251001"
OCR_MAX_TOKENS = 4096
# Claude 이미지 리사이즈 상한과 일치(토큰 절약). 장변 기준 픽셀.
RENDER_MAX_PX = 1568

client = anthropic.AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

# "원문만" 추출 — 설명/요약/마크다운/코드펜스 금지.
OCR_SYSTEM_PROMPT = (
    "You are an OCR engine. Extract the text in the image VERBATIM, preserving the original "
    "language(s), wording, line order, and reading order.\n"
    "Output ONLY the extracted text — NO explanations, summaries, translations, commentary, "
    "markdown formatting, or code fences.\n"
    "Render tables and mathematical formulas as plain text as faithfully as possible.\n"
    "If the page is blank or contains no readable text, output an empty string."
)


@dataclass
class OcrResult:
    text: str
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    latency_ms: int


def render_page(doc: fitz.Document, page_idx: int) -> bytes:
    """페이지를 장변 ~RENDER_MAX_PX의 JPEG으로 렌더한다. (0-indexed)"""
    page = doc[page_idx]
    rect = page.rect
    longest = max(rect.width, rect.height) or 1.0
    # 작은 페이지의 과확대 방지를 위해 배율 상한(4x)을 둔다.
    scale = min(RENDER_MAX_PX / longest, 4.0)
    if scale <= 0:
        scale = 1.0
    pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale))
    return pix.tobytes("jpeg")


async def ocr_page(image_bytes: bytes) -> OcrResult:
    """단일 페이지 이미지를 Haiku Vision으로 OCR한다. 비용·토큰 포함 반환."""
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")
    start = time.monotonic()
    response = await client.messages.create(
        model=OCR_MODEL,
        max_tokens=OCR_MAX_TOKENS,
        system=OCR_SYSTEM_PROMPT,
        messages=[{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {"type": "base64", "media_type": "image/jpeg", "data": image_b64},
                },
                {"type": "text", "text": "Extract the text from this page."},
            ],
        }],
    )
    latency_ms = int((time.monotonic() - start) * 1000)
    usage = response.usage
    text = response.content[0].text.strip() if response.content else ""
    cost = estimate_cost_from_usage(OCR_MODEL, usage)
    log.info(
        "OCR page: latency=%dms tokens=(in=%d out=%d) cost=$%.4f text=%s",
        latency_ms, usage.input_tokens, usage.output_tokens, cost, loglen(text),
    )
    return OcrResult(
        text=text,
        model=OCR_MODEL,
        input_tokens=usage.input_tokens,
        output_tokens=usage.output_tokens,
        cost_usd=cost,
        latency_ms=latency_ms,
    )
