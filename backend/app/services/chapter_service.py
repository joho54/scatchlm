import json
import logging
import re

from anthropic import AsyncAnthropic

from app.core.config import settings
from app.services.pdf_service import extract_page_headers

log = logging.getLogger(__name__)

CHAPTER_MODEL = "claude-haiku-4-5-20251001"

SYSTEM_PROMPT = """You are analyzing a textbook's page headers to identify chapter/section boundaries.

Given a list of page numbers and their header text (first few lines), identify the chapters and sections.

Respond ONLY with a JSON array:
[
  {"level": 1, "title": "Chapter title", "page": 5},
  {"level": 2, "title": "Section title", "page": 7},
  ...
]

Rules:
- level 1 = major chapter/unit
- level 2 = section within a chapter
- Only include actual structural boundaries, not every page
- Use the exact title text from the headers
- Skip preface, table of contents, index pages if identifiable"""


async def detect_chapters(
    server_path: str, headers: list[dict] | None = None
) -> tuple[list[dict], object | None]:
    """LLM을 사용하여 PDF의 챕터 구조를 감지한다. (chapters, usage|None)를 반환한다.

    headers가 주어지면(스캔본 OCR 경로) 그것을 사용하고, 없으면 텍스트 레이어에서 추출한다.
    LLM 호출이 없었던 경우(헤더 없음) usage는 None.
    """
    if headers is None:
        headers = extract_page_headers(server_path)
    if not headers:
        return [], None

    # 페이지 헤더를 텍스트로 조합
    input_text = "\n".join(
        f"[p.{h['page']}] {h['header']}" for h in headers
    )

    client = AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)
    response = await client.messages.create(
        model=CHAPTER_MODEL,
        max_tokens=2048,
        system=SYSTEM_PROMPT,
        messages=[
            {"role": "user", "content": input_text},
        ],
    )

    raw = response.content[0].text
    cleaned = re.sub(r"^```(?:json)?\s*", "", raw.strip())
    cleaned = re.sub(r"\s*```$", "", cleaned)

    chapters = json.loads(cleaned)
    log.info(
        "Chapter detection: model=%s input=%d output=%d chapters=%d",
        CHAPTER_MODEL,
        response.usage.input_tokens,
        response.usage.output_tokens,
        len(chapters),
    )
    return chapters, response.usage
