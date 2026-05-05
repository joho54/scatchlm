import json
import logging
import re

from anthropic import AsyncAnthropic

from app.core.config import settings

log = logging.getLogger(__name__)

GUIDE_MODEL = "claude-haiku-4-5-20251001"

def _page_guide_prompt(response_language: str) -> str:
    return f"""You are a language learning tutor. Given a textbook page, produce a study guide as JSON with these fields:
- "topic": One-line summary of what this page covers (in {response_language})
- "key_points": Array of items the student must memorize, in {response_language}
- "exercises": Array of practice tasks the student can do, in {response_language}
- "connections": How this page relates to previous/next content, in {response_language}

Respond ONLY with valid JSON. No markdown, no explanation."""


async def generate_page_guide(page_text: str, response_language: str = "Korean") -> dict:
    """페이지 텍스트를 기반으로 학습 가이드를 생성한다."""
    client = AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

    response = await client.messages.create(
        model=GUIDE_MODEL,
        max_tokens=1024,
        system=_page_guide_prompt(response_language),
        messages=[
            {"role": "user", "content": page_text},
        ],
    )

    raw = response.content[0].text
    cleaned = re.sub(r"^```(?:json)?\s*", "", raw.strip())
    cleaned = re.sub(r"\s*```$", "", cleaned)

    data = json.loads(cleaned)
    log.info(
        "Guide generated: model=%s input=%d output=%d",
        GUIDE_MODEL,
        response.usage.input_tokens,
        response.usage.output_tokens,
    )
    return data


def _chapter_guide_prompt(response_language: str) -> str:
    return f"""You are a language learning tutor. Given the full text of a textbook chapter, produce a chapter study guide as JSON. Write all values in {response_language}:
{{
  "topic": "What this chapter is about (one paragraph)",
  "key_concepts": ["Major concepts/grammar/vocab introduced in this chapter"],
  "study_order": ["Recommended order to study the material"],
  "common_mistakes": ["Typical errors learners make with this material"],
  "summary": "2-3 sentence overall summary"
}}

Respond ONLY with valid JSON. No markdown, no explanation."""


async def generate_chapter_guide(chapter_text: str, response_language: str = "Korean") -> dict:
    """챕터 전체 텍스트를 기반으로 챕터 가이드를 생성한다."""
    client = AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

    response = await client.messages.create(
        model=GUIDE_MODEL,
        max_tokens=2048,
        system=_chapter_guide_prompt(response_language),
        messages=[
            {"role": "user", "content": chapter_text},
        ],
    )

    raw = response.content[0].text
    cleaned = re.sub(r"^```(?:json)?\s*", "", raw.strip())
    cleaned = re.sub(r"\s*```$", "", cleaned)

    data = json.loads(cleaned)
    log.info(
        "Chapter guide generated: model=%s input=%d output=%d",
        GUIDE_MODEL,
        response.usage.input_tokens,
        response.usage.output_tokens,
    )
    return data
