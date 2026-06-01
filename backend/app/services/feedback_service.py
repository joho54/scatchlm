import base64
import json
import logging
import time
from dataclasses import dataclass

import anthropic

from app.core.config import settings

log = logging.getLogger(__name__)

client = anthropic.AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

def _build_system_prompt(subject: str, response_language: str, has_textbook: bool = False) -> str:
    base = (
        f"You are a study assistant helping a student learn {subject}. "
        "The user submits handwritten notes as images, sometimes with textbook reference text.\n\n"
        "The image may contain text in MULTIPLE languages — the subject's language "
        "AND the student's native language (translations, annotations, notes). "
        "Recognize ALL text in the image and analyze the entire content holistically.\n\n"
        "If the subject is a language and the student wrote original text + translation, "
        "evaluate BOTH — check translation accuracy, grammar, and spelling. "
        "For non-language subjects, focus on conceptual correctness, reasoning, and terminology. "
        "Adapt your feedback to what the subject requires, "
        "and compare with textbook content if provided.\n\n"
        f"Respond naturally in {response_language} as a helpful tutor. "
        "Be specific about what is correct and what needs fixing. "
        "Use markdown formatting (bold, strikethrough) freely.\n\n"
    )

    if has_textbook:
        base += (
            "SOURCE CITATION RULES:\n"
            "1. When your feedback references textbook content, cite the page inline: [p.33]\n"
            "2. When you use knowledge NOT from the provided textbook context, mark it as: 📖 교재 외 참고:\n"
            "3. Prefer textbook content over general knowledge when available.\n\n"
        )

    return base

# 모델별 토큰 단가 (USD per 1M tokens)
MODEL_PRICING = {
    "claude-haiku-4-5-20251001": {"input": 0.25, "output": 1.25},
    "claude-sonnet-4-6": {"input": 3.0, "output": 15.0},
}


def _select_model(task_type: str) -> str:
    if task_type == "simple":
        return "claude-haiku-4-5-20251001"
    return "claude-sonnet-4-6"


def _estimate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    pricing = MODEL_PRICING.get(model, {"input": 3.0, "output": 15.0})
    return (input_tokens * pricing["input"] + output_tokens * pricing["output"]) / 1_000_000


@dataclass
class FeedbackResult:
    data: dict
    model: str
    input_tokens: int
    output_tokens: int
    total_tokens: int
    cost_usd: float
    latency_ms: int


async def get_recognition(image_bytes: bytes, language: str = "en") -> str | None:
    """손글씨 이미지에서 텍스트만 인식한다 (RAG 쿼리용, 저비용 Haiku)."""
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")
    try:
        response = await client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=256,
            messages=[{
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {"type": "base64", "media_type": "image/jpeg" if image_bytes[:2] == b'\xff\xd8' else "image/png", "data": image_b64},
                    },
                    {
                        "type": "text",
                        "text": f"Subject: {language}. Read the handwriting in this image. Return ONLY the recognized text, nothing else.",
                    },
                ],
            }],
        )
        text = response.content[0].text.strip()
        log.info("Recognition (Haiku): '%s'", text[:100])
        return text
    except Exception:
        log.exception("Recognition failed")
        return None


async def get_feedback(
    image_bytes: bytes,
    language: str = "en",
    response_language: str = "English",
    textbook_context: str | None = None,
    previous_context: str | None = None,
    task_type: str = "complex",
) -> FeedbackResult:
    """캔버스 이미지를 Claude Vision API에 전송하여 피드백을 받는다."""
    model = _select_model(task_type)
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")
    image_size_kb = len(image_bytes) / 1024

    log.info(
        "LLM request: model=%s task=%s lang=%s image=%.1fKB context=%s prev=%s",
        model, task_type, language,
        image_size_kb,
        bool(textbook_context),
        bool(previous_context),
    )

    user_content = []
    user_content.append({
        "type": "image",
        "source": {"type": "base64", "media_type": "image/jpeg" if image_bytes[:2] == b'\xff\xd8' else "image/png", "data": image_b64},
    })

    prompt_parts = [f"Subject: {language}. Respond in {response_language}."]
    if textbook_context:
        prompt_parts.append(f"Textbook reference:\n{textbook_context}")
    if previous_context:
        prompt_parts.append(f"Previous context: {previous_context}")
    prompt_parts.append("Read the handwriting in the image and provide detailed feedback.")

    user_content.append({"type": "text", "text": "\n".join(prompt_parts)})

    start = time.monotonic()
    response = await client.messages.create(
        model=model,
        max_tokens=4096,
        system=_build_system_prompt(language, response_language, has_textbook=textbook_context is not None),
        messages=[{"role": "user", "content": user_content}],
    )
    latency_ms = int((time.monotonic() - start) * 1000)

    usage = response.usage
    input_tokens = usage.input_tokens
    output_tokens = usage.output_tokens
    total_tokens = input_tokens + output_tokens
    cost = _estimate_cost(model, input_tokens, output_tokens)

    log.info(
        "LLM response: model=%s latency=%dms tokens=%d (in=%d out=%d) cost=$%.4f",
        model, latency_ms, total_tokens, input_tokens, output_tokens, cost,
    )

    content = response.content[0].text.strip()

    data = {"type": "feedback", "content": content}

    return FeedbackResult(
        data=data,
        model=model,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total_tokens,
        cost_usd=cost,
        latency_ms=latency_ms,
    )
