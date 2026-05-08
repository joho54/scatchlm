import base64
import json
import logging
import time
from dataclasses import dataclass

import anthropic

from app.core.config import settings

log = logging.getLogger(__name__)

client = anthropic.AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

def _build_system_prompt(response_language: str, has_textbook: bool = False) -> str:
    base = (
        "You are a foreign language learning assistant. "
        "The user submits handwritten notes as images, sometimes with textbook reference text.\n\n"
        "The image may contain text in MULTIPLE languages — the target language "
        "AND the student's native language (translations, annotations, notes). "
        "Recognize ALL text in the image and analyze the entire content holistically.\n\n"
        "If the student wrote original text + translation, evaluate BOTH. "
        "Check translations for accuracy, original text for correctness, "
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

    base += (
        "Respond ONLY with valid JSON: "
        '{"type":"feedback","content":"your full response here"}\n'
        "Put your ENTIRE response in the content field as a single string."
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
                        "source": {"type": "base64", "media_type": "image/png", "data": image_b64},
                    },
                    {
                        "type": "text",
                        "text": f"Language: {language}. Read the handwriting in this image. Return ONLY the recognized text, nothing else.",
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
        "source": {"type": "base64", "media_type": "image/png", "data": image_b64},
    })

    prompt_parts = [f"Language: {language}. Respond in {response_language}."]
    if textbook_context:
        prompt_parts.append(f"Textbook reference:\n{textbook_context}")
    if previous_context:
        prompt_parts.append(f"Previous context: {previous_context}")
    prompt_parts.append("Read the handwriting in the image and provide feedback as JSON.")

    user_content.append({"type": "text", "text": "\n".join(prompt_parts)})

    start = time.monotonic()
    response = await client.messages.create(
        model=model,
        max_tokens=4096,
        system=_build_system_prompt(response_language, has_textbook=textbook_context is not None),
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
        log.warning("LLM JSON parse failed, retrying: %s | raw=%s", e, raw_text[:200])
        # 재시도: LLM에게 JSON 수정 요청
        retry_response = await client.messages.create(
            model=model,
            max_tokens=1024,
            system="Fix the following malformed JSON. Return ONLY valid JSON, nothing else.",
            messages=[{"role": "user", "content": raw_text}],
        )
        retry_text = retry_response.content[0].text.strip()
        if retry_text.startswith("```"):
            retry_lines = retry_text.split("\n")
            retry_text = "\n".join(retry_lines[1:-1])
        try:
            data = json.loads(retry_text)
            log.info("LLM JSON retry succeeded")
        except json.JSONDecodeError:
            log.error("LLM JSON retry also failed: raw=%s", retry_text[:200])
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
