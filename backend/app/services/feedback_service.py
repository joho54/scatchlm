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

# 피드백 의도(인지 연산). 같은 손글씨 이미지라도 사용자가 원하는 출력 행동이 다르다 —
# 도메인(수식/언어/다이어그램)이 아니라 "무엇을 시키나"로 가른다:
#   grade: 필기를 "답안"으로 보고 채점·교정 (기본값 = 구버전 클라이언트 동작, BC)
#   ask:   필기를 "질문/물음"으로 보고 답·설명 (채점하지 않음)
#   hint:  답을 숨기고 다음 한 걸음만 밀어줌 (해답 비공개)
# 모델은 이미지만으로 이 의도를 안정적으로 구분 못 한다(질문 필기를 미완성 답안으로 읽음) —
# 그래서 사용자가 명시적으로 지정한다.
DEFAULT_INTENT = "grade"
VALID_INTENTS = ("grade", "ask", "hint")


def _normalize_intent(intent: str | None) -> str:
    return intent if intent in VALID_INTENTS else DEFAULT_INTENT


# 의도별 task 블록(시스템 프롬프트). 채점에 고정돼 있던 부분을 여기로 분리했다 —
# 나머지(인식·언어·스타일·인용)는 의도 중립.
_INTENT_TASK = {
    "grade": (
        "Treat the handwriting as the user's OWN attempt or answer, and GRADE it. "
        "If the subject is a language and the user wrote original text + translation, "
        "evaluate BOTH — check translation accuracy, grammar, and spelling. "
        "For non-language subjects, focus on conceptual correctness, reasoning, and terminology. "
        "Be specific about what is correct and what needs fixing.\n\n"
    ),
    "ask": (
        "Treat the handwriting as a QUESTION or prompt the user is addressing TO you — "
        "NOT an answer to be graded. Do NOT score it or hunt for mistakes. "
        "Work out what they are asking and answer it directly and completely, "
        "explaining the reasoning where it aids understanding. "
        "If what they want is ambiguous, answer the most likely question and add at most "
        "one short clarifying line.\n\n"
    ),
    "hint": (
        "Treat the handwriting as work-in-progress on something the user is stuck on. "
        "Do NOT reveal the final answer or a full correction. Give ONE step of help: "
        "point to the relevant concept, rule, or the exact spot to re-examine, or ask a "
        "guiding question that nudges them forward. Withhold the solution so they can try "
        "again themselves. Keep it short — a nudge, not a lecture.\n\n"
    ),
}

# 의도별 user 턴 마지막 지시(이미지와 함께 보낼 한 줄).
_INTENT_USER_INSTRUCTION = {
    "grade": "Read the handwriting in the image and grade it — say what is correct and what needs fixing.",
    "ask": "Read the handwriting in the image and answer the question it poses. Do not grade it.",
    "hint": "Read the handwriting in the image and give a hint that moves me forward — do not reveal the full answer.",
}


def source_citation_rules() -> list[str]:
    """피드백·채팅이 공유하는 출처/인용 정책 절(clause).

    두 프롬프트에 같은 규칙이 중복돼 있다가 한쪽만 고쳐 drift날 뻔한 이력이 있어 단일 출처로
    추출한다. 태스크가 달라(이미지 채점 vs 대화 Q&A) 프롬프트 전체는 합치지 않고 이 커널만 공유 —
    각 호출부가 자기 규칙 목록 번호로 감싸 쓴다.

    핵심: 양의 주장(본문에 있는 것 → [p.X])만 groundable이라 유지하고, 음의 주장(교재 외 단정)은
    챕터만 주입된 상태에선 '다른 챕터 vs 교재 밖'을 구분할 수 없어 부당하므로 금지한다.
    """
    return [
        "When you reference content present in the provided textbook text, cite the page inline: [p.33].",
        "The provided text is only the CURRENT chapter, NOT the whole textbook. For anything not in the "
        "provided text, do NOT assert its provenance — you cannot tell whether it appears elsewhere in this "
        "textbook or is outside it. Present it plainly with no citation (its absence already signals it is "
        "not in the shown text), and never attach a 교재 외 참고 / 'outside textbook' label.",
    ]


def _build_system_prompt(
    subject: str, response_language: str, has_textbook: bool = False, intent: str = DEFAULT_INTENT
) -> str:
    # 주제가 비면(즉시 생성 노트 등) 분야 중립 튜터로 동작 — chat 경로와 동일한 처리.
    subject_phrase = subject.strip() if subject and subject.strip() else "their study material"
    intent = _normalize_intent(intent)

    # (1) 의도 중립 도입부 — 누구/무엇을 받나, 다언어 인식.
    base = (
        f"You are a study assistant helping the user learn {subject_phrase}. "
        "The user submits handwritten notes as images, sometimes with textbook reference text.\n\n"
        "The image may contain text in MULTIPLE languages — the subject's language "
        "AND the user's native language (translations, annotations, notes). "
        "Recognize ALL text in the image and analyze the entire content holistically.\n\n"
    )

    # (2) 의도별 task — 같은 이미지에 대해 채점/응답/힌트 중 무엇을 할지 결정.
    base += _INTENT_TASK[intent]

    # (3) 의도 중립 스타일/포맷 — 응답 언어, 2인칭 지칭, 마크다운/LaTeX, 교재 대조.
    base += (
        f"Respond naturally in {response_language} as a helpful tutor. "
        "Compare with the textbook content when it is provided. "
        "ADDRESS THE USER DIRECTLY. Do NOT refer to them with a third-person label "
        "such as \"the student\"/\"학생\"; speak to them in the second person and refer "
        "to their work directly (e.g. in Korean \"작성하신 필기\"/\"여기 번역은\" rather than \"학생 필기\"). "
        "Use markdown formatting (bold, strikethrough) freely.\n"
        "For math, use LaTeX with dollar delimiters ONLY: $...$ for inline math, "
        "and $$...$$ on their own lines for display math (matrices, fractions, aligned equations). "
        "Never use \\( \\) or \\[ \\] delimiters.\n\n"
    )

    if has_textbook:
        cite = source_citation_rules()
        base += (
            "SOURCE CITATION RULES:\n"
            f"1. {cite[0]}\n"
            f"2. {cite[1]}\n"
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
                "3-7 rest-time retrieval cues — the load-bearing concepts a learner should recall after this work. "
                "Each MUST be a SINGLE short term: one noun or a tight compound, ideally <=6 characters in Korean. "
                "NO phrases, NO clauses, NO descriptions, NO space-joined word lists. "
                "Good: '역전파', '베이즈정리', '경사하강'. "
                "Bad: '자음 어간 동사 변화', '구개음·입술음·치음 + σ 변형' (these are phrases — split into single terms or drop). "
                "Not a summary. Omit if nothing substantive."
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
    intent: str = DEFAULT_INTENT,
) -> FeedbackResult:
    """캔버스 이미지를 Claude Vision API에 전송하여 피드백을 받는다."""
    model = _select_model(task_type)
    intent = _normalize_intent(intent)
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")
    image_size_kb = len(image_bytes) / 1024

    log.info(
        "LLM request: model=%s task=%s intent=%s lang=%s image=%.1fKB context=%s prev=%s",
        model, task_type, intent, language,
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
    if previous_context:
        prompt_parts.append(f"Previous context: {previous_context}")
    prompt_parts.append(_INTENT_USER_INSTRUCTION[intent])

    user_content.append({"type": "text", "text": "\n".join(prompt_parts)})

    # 프롬프트 캐싱(§11 L2): 교재 컨텍스트(챕터 전문)는 같은 페이지를 반복 채점할 때
    # 호출마다 동일한 prefix다 → system 블록으로 올리고 cache_control을 걸어 5분 내
    # 재요청 시 0.1× 과금(KV 캐시 재사용). 변동분(손글씨 이미지·intent 지시·이전 컨텍스트)은
    # user 메시지에 남겨 캐시 prefix 뒤로 둔다 — 호출마다 이미지가 달라도 system 캐시는 안 깨진다.
    # 교재 미연결이면 캐시할 큰 prefix가 없어 평문 system을 그대로 쓴다(무캐시·무해).
    system_text = _build_system_prompt(
        language, response_language, has_textbook=textbook_context is not None, intent=intent
    )
    if textbook_context:
        system = [
            {"type": "text", "text": system_text},
            {
                "type": "text",
                "text": f"Textbook reference:\n{textbook_context}",
                "cache_control": {"type": "ephemeral"},
            },
        ]
    else:
        system = system_text

    start = time.monotonic()
    response = await create_message_with_retry(
        client,
        model=model,
        max_tokens=FEEDBACK_MAX_TOKENS,
        system=system,
        messages=[{"role": "user", "content": user_content}],
        output_config={"format": {"type": "json_schema", "schema": FEEDBACK_OUTPUT_SCHEMA}},
    )
    latency_ms = int((time.monotonic() - start) * 1000)

    usage = response.usage
    input_tokens = usage.input_tokens
    output_tokens = usage.output_tokens
    total_tokens = input_tokens + output_tokens
    cache_read = getattr(usage, "cache_read_input_tokens", 0) or 0
    cache_write = getattr(usage, "cache_creation_input_tokens", 0) or 0
    # 캐시 적중분을 반영한 정확한 비용(§11 L2). input_tokens는 비캐시 신규분만이라
    # 평면 estimate_cost는 캐시 write(1.25×)·read(0.1×)를 누락한다. 캐시 미사용이면 동일.
    cost = estimate_cost_from_usage(model, usage)

    log.info(
        "LLM response: model=%s latency=%dms tokens=%d (in=%d out=%d cache_read=%d cache_write=%d) cost=$%.4f stop=%s",
        model, latency_ms, total_tokens, input_tokens, output_tokens, cache_read, cache_write, cost,
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
