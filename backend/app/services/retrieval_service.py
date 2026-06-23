import logging
import re

from anthropic import AsyncAnthropic
from sqlalchemy import select, and_
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.log_sanitize import loglen
from app.models.document import DocumentChunk
from app.models.chapter import Chapter
from app.services.embedding_service import embed_query

log = logging.getLogger(__name__)

DEFAULT_TOP_K = 3


REWRITE_MODEL = "claude-haiku-4-5-20251001"


async def rewrite_query_for_search(
    user_query: str,
    db: AsyncSession | None = None,
    textbook_id: str | None = None,
) -> tuple[str, object | None]:
    """LLM으로 사용자 질문을 검색에 최적화된 쿼리로 변환한다. (Haiku, 저비용). (query, usage)를 반환."""
    try:
        # 교재 목차를 컨텍스트로 제공
        toc_context = ""
        if db and textbook_id:
            result = await db.execute(
                select(Chapter)
                .where(Chapter.textbook_id == textbook_id)
                .order_by(Chapter.page_start)
            )
            chapters = result.scalars().all()
            if chapters:
                toc_lines = [f"- {ch.title} (p.{ch.page_start}-{ch.page_end or '?'})" for ch in chapters]
                toc_context = "TEXTBOOK TABLE OF CONTENTS:\n" + "\n".join(toc_lines)

        client = AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)
        system_prompt = (
            "Rewrite the user's question into an optimal search query for finding relevant sections "
            "in a textbook. Output ONLY the search query, nothing else.\n"
            "Use the table of contents below to map section/chapter numbers to actual topics.\n"
            "Keep the query in the same language as the question and textbook. "
            "Keep it concise (under 30 words)."
        )
        if toc_context:
            system_prompt += "\n\n" + toc_context

        response = await client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=200,
            system=system_prompt,
            messages=[{"role": "user", "content": user_query}],
        )
        rewritten = response.content[0].text.strip()
        log.info("Query rewrite: %s → %s", loglen(user_query), loglen(rewritten))
        return rewritten, response.usage
    except Exception:
        log.exception("Query rewrite failed, using original")
        return user_query, None


def _detect_chapter_reference(query: str) -> str | None:
    """쿼리에서 챕터/과 번호를 감지한다. 예: '23과', 'chapter 3', 'lesson 5'"""
    patterns = [
        r'(\d+)\s*과',
        r'(\d+)\s*장',
        r'(?:chapter|ch\.?|lesson|unit)\s*(\d+)',
        r'제\s*(\d+)\s*(?:과|장|단원)',
    ]
    for pattern in patterns:
        match = re.search(pattern, query, re.IGNORECASE)
        if match:
            # 마지막 그룹 (일부 패턴은 group(2)에 숫자가 있음)
            return match.group(match.lastindex)
    return None


def _detect_page_or_section(query: str) -> int | None:
    """쿼리에서 페이지/섹션 번호를 감지한다. 예: '179 섹션', 'p.93', '§179'"""
    patterns = [
        r'(\d+)\s*(?:섹션|절|section|sec)',
        r'(?:§|p\.?|페이지|page)\s*(\d+)',
        r'(\d+)\s*페이지',
    ]
    for pattern in patterns:
        match = re.search(pattern, query, re.IGNORECASE)
        if match:
            return int(match.group(match.lastindex))
    return None


async def search_by_chapter(
    db: AsyncSession,
    textbook_id: str,
    chapter_number: str,
) -> list[DocumentChunk]:
    """챕터 번호로 해당 페이지 범위의 청크를 검색한다."""
    # chapters 테이블에서 해당 챕터 찾기
    result = await db.execute(
        select(Chapter).where(
            Chapter.textbook_id == textbook_id,
            Chapter.title.ilike(f"%{chapter_number}%"),
        )
    )
    chapters = result.scalars().all()

    if not chapters:
        log.info("Chapter search: no chapter found for '%s'", chapter_number)
        return []

    # 첫 번째 매칭 챕터의 페이지 범위로 청크 가져오기
    chapter = chapters[0]
    page_end = chapter.page_end or 9999

    chunk_result = await db.execute(
        select(DocumentChunk)
        .where(
            DocumentChunk.textbook_id == textbook_id,
            DocumentChunk.page_start >= chapter.page_start,
            DocumentChunk.page_start <= page_end,
        )
        .order_by(DocumentChunk.page_start, DocumentChunk.chunk_index)
    )
    chunks = chunk_result.scalars().all()

    log.info(
        "Chapter search: chapter='%s' pages=%d-%d chunks=%d",
        chapter.title, chapter.page_start, page_end, len(chunks),
    )
    return chunks


async def search_by_page(
    db: AsyncSession,
    textbook_id: str,
    page_num: int,
) -> list[DocumentChunk]:
    """특정 페이지 번호를 포함하는 청크를 검색한다."""
    result = await db.execute(
        select(DocumentChunk)
        .where(
            DocumentChunk.textbook_id == textbook_id,
            DocumentChunk.page_start <= page_num,
            DocumentChunk.page_end >= page_num,
        )
        .order_by(DocumentChunk.chunk_index)
    )
    chunks = result.scalars().all()

    # 정확한 매칭이 없으면 인접 페이지도 검색
    if not chunks:
        result = await db.execute(
            select(DocumentChunk)
            .where(
                DocumentChunk.textbook_id == textbook_id,
                DocumentChunk.page_start >= page_num - 1,
                DocumentChunk.page_start <= page_num + 1,
            )
            .order_by(DocumentChunk.page_start, DocumentChunk.chunk_index)
        )
        chunks = result.scalars().all()

    log.info("Page search: page=%d chunks=%d", page_num, len(chunks))
    return chunks


async def search_by_text(
    db: AsyncSession,
    textbook_id: str,
    query_text: str,
    limit: int = 5,
) -> list[DocumentChunk]:
    """청크 본문에서 키워드/숫자를 직접 검색한다."""
    # 숫자 추출 (섹션 번호 등)
    numbers = re.findall(r'\d+', query_text)
    if not numbers:
        return []

    chunks = []
    for num in numbers:
        if int(num) < 10:
            continue  # 너무 작은 숫자는 스킵
        # 섹션 번호 패턴: §179, 179., (179), "179 " 등
        patterns = [f"§{num}", f"{num}.", f"({num})", f" {num} "]
        for pat in patterns:
            result = await db.execute(
                select(DocumentChunk)
                .where(
                    DocumentChunk.textbook_id == textbook_id,
                    DocumentChunk.content.contains(pat),
                )
                .order_by(DocumentChunk.page_start)
                .limit(limit)
            )
            found = result.scalars().all()
            if found:
                chunks.extend(found)
                log.info("Text search: pattern='%s' found %d chunks", pat, len(found))
                break  # 첫 매칭 패턴에서 중단

    # 중복 제거
    seen = set()
    unique = []
    for c in chunks:
        if c.id not in seen:
            seen.add(c.id)
            unique.append(c)

    return unique[:limit]


async def search_relevant_chunks(
    db: AsyncSession,
    textbook_id: str,
    query_text: str,
    top_k: int = DEFAULT_TOP_K,
    *,
    user_id: str | None = None,
) -> list[DocumentChunk]:
    """하이브리드 검색: 챕터 → 페이지/섹션 → 의미 유사도.

    user_id가 주어지면 쿼리 리라이트(Haiku) 비용을 llm_usage에 기록한다(billable=False —
    quota 미차감, 관측 전용). RAG fallback 경로라 정상 UX에선 거의 도달하지 않는다.
    """
    # LLM 쿼리 리라이트 (목차 컨텍스트 포함) + 의미 유사도 검색
    rewritten, rewrite_usage = await rewrite_query_for_search(query_text, db=db, textbook_id=textbook_id)
    if user_id and rewrite_usage is not None:
        from app.services.feedback_service import estimate_cost_from_usage
        from app.services.usage_service import log_llm_usage
        await log_llm_usage(
            db, user_id=user_id, model=REWRITE_MODEL,
            input_tokens=rewrite_usage.input_tokens, output_tokens=rewrite_usage.output_tokens,
            cost_usd=estimate_cost_from_usage(REWRITE_MODEL, rewrite_usage), latency_ms=0,
            task_type="query_rewrite", billable=False,
        )
    query_embedding = await embed_query(rewritten)

    result = await db.execute(
        select(DocumentChunk)
        .where(
            DocumentChunk.textbook_id == textbook_id,
            DocumentChunk.embedding.isnot(None),
        )
        .order_by(DocumentChunk.embedding.cosine_distance(query_embedding))
        .limit(top_k)
    )
    chunks = result.scalars().all()

    log.info(
        "RAG semantic search: textbook=%s original='%s' rewritten='%s' results=%d",
        textbook_id, query_text[:30], rewritten[:30], len(chunks),
    )
    return chunks


def format_chunks_as_context(chunks: list[DocumentChunk]) -> str:
    """검색된 청크를 LLM 컨텍스트 문자열로 포매팅한다."""
    parts = []
    for chunk in chunks:
        parts.append(
            f"--- Reference (p.{chunk.page_start}-{chunk.page_end}) ---\n{chunk.content}"
        )
    return "\n\n".join(parts)
