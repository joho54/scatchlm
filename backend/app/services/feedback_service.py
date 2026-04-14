import base64
import json
import logging
import time
from dataclasses import dataclass

import anthropic

from app.core.config import settings

log = logging.getLogger(__name__)

client = anthropic.AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

SYSTEM_PROMPT = (
    "You are a foreign language learning assistant. "
    "The user submits handwritten notes as images. "
    "Recognize the handwriting and provide structured feedback.\n"
    "Respond ONLY with valid JSON in this format:\n"
    '{"recognized_text":"...","corrections":[{"position":1,"original":"...","corrected":"...","reason":"..."}],"summary":"..."}\n'
    "Keep corrections concise. Write summary in Korean."
)

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


async def get_feedback(
    image_bytes: bytes,
    language: str = "en",
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
        "source": {"type": "base64", "media_type": "image/png", "data": image_b64},
    })

    prompt_parts = [f"Language: {language}."]
    if textbook_context:
        prompt_parts.append(f"Textbook reference:\n{textbook_context}")
    if previous_context:
        prompt_parts.append(f"Previous context: {previous_context}")
    prompt_parts.append("Read the handwriting in the image and provide feedback as JSON.")

    user_content.append({"type": "text", "text": "\n".join(prompt_parts)})

    start = time.monotonic()
    response = await client.messages.create(
        model=model,
        max_tokens=1024,
        system=SYSTEM_PROMPT,
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

    raw_text = response.content[0].text.strip()

    # JSON 블록 추출 (```json ... ``` 감싸진 경우 대응)
    if raw_text.startswith("```"):
        lines = raw_text.split("\n")
        raw_text = "\n".join(lines[1:-1])

    try:
        data = json.loads(raw_text)
    except json.JSONDecodeError as e:
        log.error("LLM JSON parse failed: %s | raw=%s", e, raw_text[:200])
        raise

    return FeedbackResult(
        data=data,
        model=model,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total_tokens,
        cost_usd=cost,
        latency_ms=latency_ms,
    )
