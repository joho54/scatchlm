import asyncio
import base64
import json
import logging
import random
import time
from dataclasses import dataclass

import anthropic

from app.core.config import settings
from app.core.constants import DEFAULT_SUBJECT
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


# 일시적 업스트림 장애로 간주해 재시도하는 HTTP 상태(529=Overloaded, 5xx=내부/게이트웨이 오류).
# 429(RateLimit)는 제외 — quota/paywall 경로에서 별도로 다루며, 무지성 재시도는 압박만 키운다.
_RETRYABLE_STATUS = {500, 502, 503, 504, 529}


def _is_retryable(exc: Exception) -> bool:
    if isinstance(exc, (anthropic.APITimeoutError, anthropic.APIConnectionError)):
        return True
    if isinstance(exc, anthropic.APIStatusError):
        return getattr(exc, "status_code", None) in _RETRYABLE_STATUS
    return False


async def create_message_with_retry(
    client: "anthropic.AsyncAnthropic",
    *,
    max_attempts: int = 4,
    base_delay: float = 0.5,
    **kwargs,
):
    """`client.messages.create`를 일시적 업스트림 장애에 한해 지수 백오프로 재시도한다.

    재시도 대상: 529(Overloaded)·5xx·timeout·connection. 429/4xx 등 비일시적 에러는 즉시 raise해
    기존 except 핸들러(분류·502/Paywall)가 그대로 동작한다. 최종 시도까지 실패하면 마지막 예외를 raise.

    호출하는 client는 `max_retries=0`으로 생성해 SDK 내부 재시도와 증폭되지 않게 한다
    (이 헬퍼가 단일 재시도 주체). 백오프는 ~0.5/1/2초 + 지터로 최악 ~6초 추가에 그친다 —
    짧은 과부하 블립을 흡수하는 게 목적이고, 장시간 장애는 어차피 사용자에게 에러로 노출된다.
    """
    last_exc: Exception | None = None
    for attempt in range(max_attempts):
        try:
            return await client.messages.create(**kwargs)
        except Exception as exc:
            if not _is_retryable(exc) or attempt == max_attempts - 1:
                raise
            last_exc = exc
            delay = base_delay * (2 ** attempt) + random.uniform(0, base_delay)
            log.warning(
                "Anthropic transient error (%s), retry %d/%d in %.2fs",
                classify_anthropic_error(exc), attempt + 1, max_attempts - 1, delay,
            )
            await asyncio.sleep(delay)
    raise last_exc  # pragma: no cover — 루프가 마지막 시도에서 raise함


client = anthropic.AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY, max_retries=0)

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
# 과금은 실제 output_tokens 기준이라 상한을 올려도 짧은 응답 비용은 불변 — 1536은
# 교재 컨텍스트 + 정정 많은 손글씨 같은 긴 케이스에서 stop_reason=max_tokens로 응답을
# 문장 중간에 잘랐다(prod에서 output_tokens=1536 절단 2건 확인). sonnet-4-6 단일 응답
# 한도는 64K이므로 넉넉히 상향한다.
FEEDBACK_MAX_TOKENS = 4096

# 손글씨 피드백 structured output 스키마(§one-pass).
# 같은 Vision 호출이 (a) 사용자가 손으로 쓴 원문 transcription과 (b) 피드백을 함께 반환하게 강제한다.
# transcription은 후속 채팅 컨텍스트 주입에 쓰인다 — 채팅 시점엔 이미지가 없어 노트 원문을 알 길이 없던 틈을 메운다.
# 주의: additionalProperties:false 필수, minLength 등 제약은 미지원(structured outputs 스키마 제한).
FEEDBACK_OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {
        "transcription": {
            "type": "string",
            "description": (
                "Verbatim transcription of the handwriting in the image, preserving the original "
                "language(s) and line breaks. This is the user's OWN written work, not the textbook. "
                "Empty string if the image has no legible handwriting."
            ),
        },
        "feedback": {
            "type": "string",
            "description": "The tutor feedback itself, in markdown, written in the requested response language.",
        },
        "keywords": {
            "type": "array",
            "items": {"type": "string"},
            "description": (
                "3-7 key concepts or terms a learner should be able to recall after this work, "
                "as short noun phrases in the response language. These are rest-time retrieval cues, "
                "NOT a summary: pick the load-bearing concepts (e.g. '역전파', '베이즈 정리'), not filler words. "
                "Each cue should stand alone as a recall prompt. Omit if nothing substantive."
            ),
        },
    },
    "required": ["transcription", "feedback"],
    "additionalProperties": False,
}


def _clean_keywords(raw: object, limit: int = 7) -> list[str]:
    """LLM이 돌려준 keywords를 정규화: 문자열만, 공백 정리, 중복 제거, 상한.
    길이 컷은 두지 않는다 — 표시(클라이언트) 책임. 비-list/비-str은 조용히 버린다."""
    if not isinstance(raw, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        if not isinstance(item, str):
            continue
        kw = item.strip()
        if not kw or kw in seen:
            continue
        seen.add(kw)
        out.append(kw)
        if len(out) >= limit:
            break
    return out


@dataclass
class FeedbackResult:
    data: dict
    model: str
    input_tokens: int
    output_tokens: int
    total_tokens: int
    cost_usd: float
    latency_ms: int


RECOGNITION_MODEL = "claude-haiku-4-5-20251001"


async def get_recognition(
    image_bytes: bytes, language: str = DEFAULT_SUBJECT
) -> tuple[str | None, object | None]:
    """손글씨 이미지에서 텍스트만 인식한다 (RAG 쿼리용, 저비용 Haiku). (text, usage)를 반환한다."""
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")
    try:
        response = await create_message_with_retry(
            client,
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
        return text, response.usage
    except Exception as e:
        log.exception("Recognition failed: error=%s", classify_anthropic_error(e))
        return None, None


async def get_feedback(
    image_bytes: bytes,
    language: str = DEFAULT_SUBJECT,
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
    response = await create_message_with_retry(
        client,
        model=model,
        max_tokens=FEEDBACK_MAX_TOKENS,
        system=_build_system_prompt(language, response_language, has_textbook=textbook_context is not None),
        messages=[{"role": "user", "content": user_content}],
        output_config={"format": {"type": "json_schema", "schema": FEEDBACK_OUTPUT_SCHEMA}},
    )
    latency_ms = int((time.monotonic() - start) * 1000)

    usage = response.usage
    input_tokens = usage.input_tokens
    output_tokens = usage.output_tokens
    total_tokens = input_tokens + output_tokens
    cost = _estimate_cost(model, input_tokens, output_tokens)

    log.info(
        "LLM response: model=%s latency=%dms tokens=%d (in=%d out=%d) cost=$%.4f stop=%s",
        model, latency_ms, total_tokens, input_tokens, output_tokens, cost,
        response.stop_reason,
    )

    # max_tokens 도달 = 응답이 문장 중간에 잘려 저장됨(침묵 절단). 상한을 넘기는
    # 트래픽이 다시 생기면 바로 보이도록 경보로 남긴다.
    if response.stop_reason == "max_tokens":
        log.warning(
            "LLM response truncated at max_tokens: model=%s out=%d (FEEDBACK_MAX_TOKENS=%d)",
            model, output_tokens, FEEDBACK_MAX_TOKENS,
        )

    raw = response.content[0].text.strip()

    # structured output → {transcription, feedback}. 잘림(max_tokens)이나 예외적 비-JSON 응답이면
    # best-effort 폴백: 원문을 그대로 피드백으로 쓰고 transcription은 비운다(채팅 주입은 단지 생략됨).
    transcription = ""
    keywords: list[str] = []
    try:
        parsed = json.loads(raw)
        content = (parsed.get("feedback") or "").strip()
        transcription = (parsed.get("transcription") or "").strip()
        keywords = _clean_keywords(parsed.get("keywords"))
        if not content:
            content = raw
    except (json.JSONDecodeError, AttributeError):
        log.warning("Feedback structured output parse failed (stop=%s); falling back to raw text", response.stop_reason)
        content = raw

    data = {"type": "feedback", "content": content, "transcription": transcription, "keywords": keywords}
    log.info("Feedback keywords: n=%d %s", len(keywords), keywords)

    return FeedbackResult(
        data=data,
        model=model,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total_tokens,
        cost_usd=cost,
        latency_ms=latency_ms,
    )
