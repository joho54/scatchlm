import base64
import json
import logging
import time
from dataclasses import dataclass

import anthropic

from app.core.config import settings
from app.core.log_sanitize import loglen

log = logging.getLogger(__name__)


def classify_anthropic_error(exc: Exception) -> str:
    """Anthropic 예외를 분류 라벨로 반환(로그 태깅용, O12/C6)."""
    if isinstance(exc, anthropic.RateLimitError):
        return "rate_limit_429"
    if isinstance(exc, anthropic.APITimeoutError):
        return "timeout"
    if isinstance(exc, anthropic.APIStatusError):
        code = getattr(exc, "status_code", None)
        if code == 529:
            return "overloaded_529"
        return f"api_status_{code}"
    if isinstance(exc, anthropic.APIConnectionError):
        return "connection"
    return "unknown"

client = anthropic.AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

def _build_system_prompt(subject: str, response_language: str, has_textbook: bool = False) -> str:
    # 주제가 비면(즉시 생성 노트 등) 분야 중립 튜터로 동작 — chat 경로와 동일한 처리.
    subject_phrase = subject.strip() if subject and subject.strip() else "their study material"
    base = (
        f"You are a study assistant helping the user learn {subject_phrase}. "
        "The user submits handwritten notes as images, sometimes with textbook reference text.\n\n"
        "The image may contain text in MULTIPLE languages — the subject's language "
        "AND the user's native language (translations, annotations, notes). "
        "Recognize ALL text in the image and analyze the entire content holistically.\n\n"
        "If the subject is a language and the user wrote original text + translation, "
        "evaluate BOTH — check translation accuracy, grammar, and spelling. "
        "For non-language subjects, focus on conceptual correctness, reasoning, and terminology. "
        "Adapt your feedback to what the subject requires, "
        "and compare with textbook content if provided.\n\n"
        f"Respond naturally in {response_language} as a helpful tutor. "
        "Be specific about what is correct and what needs fixing. "
        "ADDRESS THE USER DIRECTLY. Do NOT refer to them with a third-person label "
        "such as \"the student\"/\"학생\"; speak to them in the second person and refer "
        "to their work directly (e.g. in Korean \"작성하신 필기\"/\"여기 번역은\" rather than \"학생 필기\"). "
        "Use markdown formatting (bold, strikethrough) freely.\n"
        "For math, use LaTeX with dollar delimiters ONLY: $...$ for inline math, "
        "and $$...$$ on their own lines for display math (matrices, fractions, aligned equations). "
        "Never use \\( \\) or \\[ \\] delimiters.\n\n"
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


def estimate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    pricing = MODEL_PRICING.get(model, {"input": 3.0, "output": 15.0})
    return (input_tokens * pricing["input"] + output_tokens * pricing["output"]) / 1_000_000


def estimate_cost_from_usage(model: str, usage) -> float:
    """prompt caching(§11 L2)을 반영한 정확한 비용.

    Anthropic은 캐시 적중분을 별도 필드로 보고한다(`input_tokens`는 비캐시 신규 입력만):
    - cache_read_input_tokens  → **0.1×** 단가
    - cache_creation_input_tokens → **1.25×** 단가(쓰기 오버헤드)
    캐시 미사용 응답이면 두 필드가 0/없음이라 estimate_cost와 동일하게 동작.
    """
    pricing = MODEL_PRICING.get(model, {"input": 3.0, "output": 15.0})
    input_tokens = getattr(usage, "input_tokens", 0) or 0
    output_tokens = getattr(usage, "output_tokens", 0) or 0
    cache_read = getattr(usage, "cache_read_input_tokens", 0) or 0
    cache_write = getattr(usage, "cache_creation_input_tokens", 0) or 0
    return (
        input_tokens * pricing["input"]
        + cache_read * pricing["input"] * 0.1
        + cache_write * pricing["input"] * 1.25
        + output_tokens * pricing["output"]
    ) / 1_000_000


# 하위호환 별칭
_estimate_cost = estimate_cost

# 피드백 응답 output 상한 (§11 L1). 전형 피드백은 ~600토큰이라 평균엔 영향 없고
# 롱테일/폭주 응답 비용만 상한한다(output은 $15/1M로 비용의 ~55%).
FEEDBACK_MAX_TOKENS = 1536


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
                        "text": (
                            (f"Subject: {language}. " if language and language.strip() else "")
                            + "Read the handwriting in this image. Return ONLY the recognized text, nothing else."
                        ),
                    },
                ],
            }],
        )
        text = response.content[0].text.strip()
        log.info("Recognition (Haiku): %s", loglen(text))
        return text
    except Exception as e:
        log.exception("Recognition failed: error=%s", classify_anthropic_error(e))
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
        max_tokens=FEEDBACK_MAX_TOKENS,
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
