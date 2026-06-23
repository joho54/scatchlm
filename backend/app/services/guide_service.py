import json
import logging
import re

from anthropic import AsyncAnthropic

from app.core.config import settings
from app.services.feedback_service import create_message_with_retry

log = logging.getLogger(__name__)

GUIDE_MODEL = "claude-haiku-4-5-20251001"

def _page_guide_prompt(response_language: str) -> str:
    return (
        f"You are helping the user understand a textbook page. "
        f"Explain the page content clearly and faithfully in {response_language}. "
        f"When the source text is in another language, translate key terms and examples; "
        f"make the content accessible regardless of subject. "
        f"Use markdown formatting freely. Be thorough — cover everything on the page. "
        f"When you address the reader, speak to them directly in the second person; "
        f"do NOT use a third-person label such as \"the student\"/\"학생\". "
        f"CRITICAL: If the page contains exercises, practice problems, quizzes, or assignments "
        f"(anything the user is expected to solve themselves), do NOT reveal the answers. "
        f"Instead, explain the underlying concepts needed, clarify what the problem is asking, "
        f"and offer approach hints or worked-out *similar* examples — never the actual solution. "
        f"Worked examples that the textbook itself already solves are fine to explain. "
        f"For math, use LaTeX with dollar delimiters ONLY: $...$ for inline math, "
        f"and $$...$$ on their own lines for display math (matrices, fractions, aligned equations). "
        f"Never use \\( \\) or \\[ \\] delimiters."
    )


async def generate_page_guide(page_text: str, response_language: str = "Korean") -> tuple[dict, object]:
    """페이지 텍스트를 기반으로 학습 가이드를 생성한다. (data, usage)를 반환한다."""
    client = AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY, max_retries=0)

    response = await create_message_with_retry(
        client,
        model=GUIDE_MODEL,
        max_tokens=4096,
        system=_page_guide_prompt(response_language),
        messages=[
            {"role": "user", "content": page_text},
        ],
    )

    content = response.content[0].text
    log.info(
        "Guide generated: model=%s input=%d output=%d",
        GUIDE_MODEL,
        response.usage.input_tokens,
        response.usage.output_tokens,
    )
    return {"topic": "", "content": content}, response.usage


def _chapter_guide_prompt(response_language: str) -> str:
    return f"""You are a study tutor. Given the full text of a textbook chapter, produce a chapter study guide as JSON. Write all values in {response_language}:
{{
  "topic": "What this chapter is about (one paragraph)",
  "key_concepts": ["Major concepts, terms, or skills introduced in this chapter"],
  "study_order": ["Recommended order to study the material"],
  "common_mistakes": ["Common misunderstandings or mistakes learners make with this material"],
  "summary": "2-3 sentence overall summary"
}}

Respond ONLY with valid JSON. No markdown, no explanation."""


async def generate_chapter_guide(chapter_text: str, response_language: str = "Korean") -> tuple[dict, object]:
    """챕터 전체 텍스트를 기반으로 챕터 가이드를 생성한다. (data, usage)를 반환한다."""
    client = AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY, max_retries=0)

    response = await create_message_with_retry(
        client,
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
    return data, response.usage
