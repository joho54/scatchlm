"""학습 자료 추천(Discover) 서비스 — docs/discover-feature-spec.md Track A.

홈에서 받은 자연어 질의로 Claude의 web_search/web_fetch agentic loop를 돌려
**무료 공개 학습자료**를 추천한다. 환각 방지를 위해 (1) 모델이 URL을 생성하지 않고
web_search 실결과 + web_fetch 검증으로만 추천하게 system 절대규칙으로 강제하고,
(2) 백엔드가 추천 URL을 httpx로 **독립 재검증**(모델 자기보고 불신)한다.

기존 feedback_service의 AsyncAnthropic 클라이언트·재시도 래퍼·usage 로깅을 재사용한다.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import time

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.chapter import Chapter
from app.models.textbook import TextbookSource
from app.services.feedback_service import (
    client,
    create_message_with_retry,
    estimate_cost,
)
from app.services.usage_service import log_llm_usage

log = logging.getLogger(__name__)

# 추천에 사용하는 모델 — §4.3 결정 근거. web_search_20260209 dynamic filtering 지원 티어이자
# 코드베이스 운영 표준(pricing 테이블·feedback 경로). 품질 부족 시 opus-4-8로 승격은 한 줄.
DISCOVER_MODEL = "claude-sonnet-4-6"

# 추천 후보 상한 — 비용·지연 가드(§7 Risk). 소수만 web_fetch 검증.
MAX_RECOMMENDATIONS = 5

# pause_turn(서버툴 장기 실행) 재전송 가드 — 무한 루프 방지(§4.1-3, §7).
MAX_CONTINUATIONS = 5

# 응답 토큰 상한. 추천 JSON은 작지만 server-tool turn 사이 추론 여지를 둔다.
DISCOVER_MAX_TOKENS = 2048

# web_fetch 재검증 타임아웃(초).
VERIFY_TIMEOUT = 6.0

# 유효한 enum 값(§3.2-a). 모델이 다른 값을 내면 결과에서 제외.
VALID_FORMATS = ("PDF", "웹페이지", "강의코스")
VALID_LEVELS = ("입문", "학부기초", "심화", "대학원")

# 해적/불법 복제 사이트 — web_search/web_fetch blocked_domains로 차단(§7, §6.x-3).
# 초기 소규모 하드코딩 + 운영 중 보강. 도메인만(스킴/경로 없이).
BLOCKED_DOMAINS = [
    "libgen.is",
    "libgen.rs",
    "libgen.st",
    "library.lol",
    "sci-hub.se",
    "sci-hub.st",
    "sci-hub.ru",
    "z-lib.org",
    "z-lib.io",
    "zlibrary.to",
    "annas-archive.org",
    "pdfdrive.com",
    "vdoc.pub",
    "dokumen.pub",
    "ebook777.com",
]


SYSTEM_PROMPT = """\
You are a study-material scout. The user studies a topic and wants you to find \
FREE, publicly and legally accessible learning resources (PDFs, open textbooks, \
lecture notes, courses) on the open web.

TOOLS
- You have web_search and web_fetch. You MUST ground every recommendation in REAL \
search results that you actually fetched and inspected. NEVER invent, guess, or \
reconstruct a URL from memory.
- Workflow: web_search for candidates -> web_fetch the most promising ones to \
confirm the resource is real, free to access (no paywall, no login, not pirated), \
and matches the topic/level -> recommend only what you verified.

ABSOLUTE RULES (a violation makes the whole answer useless)
1. Only recommend resources that are FREE and LEGAL to access. No paywalled, \
login-gated, or pirated copies. If you are unsure a copy is legitimate, drop it.
2. Every `url` MUST be a real URL you obtained from a search result and fetched. \
If you could not fetch/verify it, do not include it.
3. Prefer official, open-license sources: OpenStax, LibreTexts, MIT OpenCourseWare, \
other university OCW, arXiv, government/edu domains, official course pages.
4. Return AT MOST {max_recs} recommendations. Quality over quantity. It is better \
to return fewer (or zero) than to include a dead, paywalled, or off-topic link.

LEVEL CALIBRATION
- A digest of the user's current library (textbooks + table of contents) is provided. \
Infer the learner's current level from it. Recommend mostly at their CURRENT level, \
plus ONE resource one step ABOVE to stretch them.
- If the library is empty, infer level from the query alone.

LANGUAGE
- Search in the requested material languages. Write each `why` in the requested \
"recommendation reason language" — one concise sentence explaining why this resource \
fits this specific learner.

OUTPUT
- Respond with ONLY a single JSON object, no prose, no markdown code fences, matching:
  {{"recommendations": [{{"title": str, "url": str, "format": "PDF"|"웹페이지"|"강의코스", \
"level": "입문"|"학부기초"|"심화"|"대학원", "why": str}}], "note": str}}
- `format`: "PDF" for a direct downloadable PDF document, "웹페이지" for an open \
textbook/notes web page, "강의코스" for a course/lecture site.
- `note`: empty string "" when results are good. If you found few or zero legitimate \
free resources, put one honest sentence (in the recommendation reason language) \
explaining that, and return an empty recommendations array.
"""


async def build_library_digest(db: AsyncSession, user_id: str) -> str:
    """사용자 서재(보유 교재 + level<=2 ToC)를 프롬프트용 트리 텍스트로 만든다.

    title 전용 컬럼이 없어 file_name을 교재명으로 쓴다(§6 확인). 챕터는 level<=2(챕터+섹션)
    까지만, page_start 순. 서재가 비면 안내 문구를 반환해 프롬프트가 질의만으로 수준을 추정하게 한다.
    """
    src_result = await db.execute(
        select(TextbookSource.id, TextbookSource.file_name)
        .where(TextbookSource.user_id == user_id)
        .order_by(TextbookSource.created_at.asc())
    )
    sources = src_result.all()
    if not sources:
        return "(서재 비어있음 — 보유 교재 없음)"

    lines: list[str] = []
    for src_id, file_name in sources:
        lines.append(f'- "{file_name}"')
        ch_result = await db.execute(
            select(Chapter.level, Chapter.title)
            .where(Chapter.textbook_id == src_id, Chapter.level <= 2)
            .order_by(Chapter.page_start.asc())
        )
        for level, title in ch_result.all():
            indent = "    " if level <= 1 else "        "
            lines.append(f"{indent}{title}")
    return "\n".join(lines)


def _tools() -> list[dict]:
    return [
        {
            "type": "web_search_20260209",
            "name": "web_search",
            "blocked_domains": BLOCKED_DOMAINS,
            "max_uses": 6,
        },
        {
            "type": "web_fetch_20260209",
            "name": "web_fetch",
            "blocked_domains": BLOCKED_DOMAINS,
            "max_uses": 8,
        },
    ]


def _extract_text(content) -> str:
    """assistant content 블록들에서 text 블록만 이어붙인다(server_tool_use/결과 블록 무시)."""
    parts: list[str] = []
    for block in content:
        if getattr(block, "type", None) == "text":
            parts.append(block.text)
    return "\n".join(parts).strip()


def _parse_recommendations(text: str) -> dict:
    """LLM 출력에서 {recommendations, note}를 방어적으로 파싱한다.

    코드펜스 제거 후 첫 `{...}` 균형 추출 → json.loads. 실패 시 빈 결과.
    enum/필수필드 검증은 호출부(run_discovery)에서 한다.
    """
    if not text:
        return {"recommendations": [], "note": ""}
    # 코드펜스 제거
    cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip(), flags=re.MULTILINE)
    # 첫 { 부터 균형 잡힌 } 까지 추출
    start = cleaned.find("{")
    if start == -1:
        return {"recommendations": [], "note": ""}
    depth = 0
    end = -1
    in_str = False
    esc = False
    for i in range(start, len(cleaned)):
        c = cleaned[i]
        if esc:
            esc = False
            continue
        if c == "\\":
            esc = True
            continue
        if c == '"':
            in_str = not in_str
            continue
        if in_str:
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end == -1:
        return {"recommendations": [], "note": ""}
    try:
        parsed = json.loads(cleaned[start:end])
    except json.JSONDecodeError:
        return {"recommendations": [], "note": ""}
    if not isinstance(parsed, dict):
        return {"recommendations": [], "note": ""}
    return parsed


def _sanitize(parsed: dict) -> dict:
    """파싱 결과를 계약(§3.2-a)에 맞게 정규화·검증한다."""
    recs_raw = parsed.get("recommendations")
    note = parsed.get("note")
    note = note.strip() if isinstance(note, str) else ""

    out: list[dict] = []
    if isinstance(recs_raw, list):
        for item in recs_raw:
            if not isinstance(item, dict):
                continue
            title = item.get("title")
            url = item.get("url")
            fmt = item.get("format")
            level = item.get("level")
            why = item.get("why")
            if not (isinstance(title, str) and title.strip()):
                continue
            if not (isinstance(url, str) and url.strip().startswith(("http://", "https://"))):
                continue
            if fmt not in VALID_FORMATS or level not in VALID_LEVELS:
                continue
            out.append({
                "title": title.strip(),
                "url": url.strip(),
                "format": fmt,
                "level": level,
                "why": why.strip() if isinstance(why, str) else "",
            })
            if len(out) >= MAX_RECOMMENDATIONS:
                break
    return {"recommendations": out, "note": note}


async def run_discovery(
    db: AsyncSession,
    *,
    user_id: str,
    query: str,
    response_language: str,
    is_admin: bool = False,
) -> dict:
    """agentic loop를 돌려 {recommendations, note}(미검증)를 반환한다. usage도 적재한다.

    예외(업스트림 장애·파싱 불가)는 호출부에서 502로 변환하도록 raise한다.
    """
    digest = await build_library_digest(db, user_id)

    langs = "영어" if response_language.strip().lower() == "english" else f"영어, {response_language}"
    system = [
        {
            "type": "text",
            "text": SYSTEM_PROMPT.format(max_recs=MAX_RECOMMENDATIONS),
            "cache_control": {"type": "ephemeral"},
        },
    ]
    messages = [
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": f"[사용자 서재 다이제스트]\n{digest}",
                    "cache_control": {"type": "ephemeral"},
                },
                {
                    "type": "text",
                    "text": (
                        f"[자료 언어] {langs}\n"
                        f"[추천 이유 언어] {response_language}\n"
                        f"[질의] {query}"
                    ),
                },
            ],
        },
    ]

    tools = _tools()
    in_tokens = 0
    out_tokens = 0
    start = time.monotonic()
    response = None
    for cont in range(MAX_CONTINUATIONS + 1):
        response = await create_message_with_retry(
            client,
            model=DISCOVER_MODEL,
            max_tokens=DISCOVER_MAX_TOKENS,
            system=system,
            messages=messages,
            tools=tools,
        )
        usage = response.usage
        in_tokens += getattr(usage, "input_tokens", 0) or 0
        out_tokens += getattr(usage, "output_tokens", 0) or 0
        if response.stop_reason != "pause_turn":
            break
        # 서버툴 장기 실행 — assistant content를 그대로 이어붙여 재전송.
        messages.append({"role": "assistant", "content": response.content})
        if cont == MAX_CONTINUATIONS:
            log.warning("Discover: max_continuations(%d) reached, stop=%s", MAX_CONTINUATIONS, response.stop_reason)

    latency_ms = int((time.monotonic() - start) * 1000)
    cost = estimate_cost(DISCOVER_MODEL, in_tokens, out_tokens)
    log.info(
        "Discover LLM: model=%s latency=%dms in=%d out=%d cost=$%.4f stop=%s",
        DISCOVER_MODEL, latency_ms, in_tokens, out_tokens, cost, response.stop_reason if response else "none",
    )
    await log_llm_usage(
        db,
        user_id=user_id,
        model=DISCOVER_MODEL,
        input_tokens=in_tokens,
        output_tokens=out_tokens,
        cost_usd=cost,
        latency_ms=latency_ms,
        task_type="discover",
        language=response_language,
        billable=not is_admin,
    )

    text = _extract_text(response.content) if response else ""
    parsed = _parse_recommendations(text)
    result = _sanitize(parsed)
    log.info("Discover parsed: n=%d note=%r", len(result["recommendations"]), result["note"][:80])
    return result


async def _verify_one(http: httpx.AsyncClient, rec: dict) -> bool:
    """추천 URL 한 건을 재검증한다. PDF는 pdf 신호까지, 그 외는 200 도달이면 통과."""
    url = rec["url"]
    is_pdf = rec["format"] == "PDF"
    try:
        # HEAD 먼저(가벼움). 일부 서버는 HEAD 미지원(405) → GET 폴백.
        resp = await http.head(url, follow_redirects=True, timeout=VERIFY_TIMEOUT)
        if resp.status_code in (403, 405, 501) or (is_pdf and resp.status_code >= 400):
            resp = await http.get(url, follow_redirects=True, timeout=VERIFY_TIMEOUT)
    except httpx.HTTPError as exc:
        log.info("Discover verify drop (network): %s (%s)", url, type(exc).__name__)
        return False

    if resp.status_code >= 400:
        log.info("Discover verify drop (status %d): %s", resp.status_code, url)
        return False

    if is_pdf:
        ctype = resp.headers.get("content-type", "").lower()
        final_url = str(resp.url).lower()
        if "pdf" not in ctype and not final_url.endswith(".pdf"):
            log.info("Discover verify drop (not pdf ctype=%r): %s", ctype, url)
            return False
    return True


async def verify_urls(recommendations: list[dict]) -> list[dict]:
    """각 추천 URL을 병렬 재검증(개별 예외 격리)하고, 살아있는 것만 남긴다(§4.1-4)."""
    if not recommendations:
        return []
    async with httpx.AsyncClient(
        follow_redirects=True,
        timeout=VERIFY_TIMEOUT,
        headers={"User-Agent": "ScatchLM-Discover/1.0"},
    ) as http:
        results = await asyncio.gather(
            *(_verify_one(http, rec) for rec in recommendations),
            return_exceptions=True,
        )
    kept = []
    for rec, ok in zip(recommendations, results):
        if ok is True:
            kept.append(rec)
    return kept
