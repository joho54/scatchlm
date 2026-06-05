"""LLMUsage 적재 공용 헬퍼 (docs/scanned-pdf-ocr-spec.md §4.3).

라우터 인라인 `db.add(LLMUsage(...))`를 대체. OCR 백그라운드 잡(라우터 밖)에서도
동일하게 비용을 기록해 기존 USD 기반 쿼터(quota.py)에 흡수되도록 한다.
"""
from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.usage import LLMUsage


async def log_llm_usage(
    db: AsyncSession,
    *,
    user_id: str,
    model: str,
    input_tokens: int,
    output_tokens: int,
    cost_usd: float,
    latency_ms: int,
    task_type: str,
    language: str = "",
    has_textbook_context: bool = False,
    error: str | None = None,
    commit: bool = False,
) -> None:
    """LLMUsage 행을 세션에 추가한다. commit=True면 즉시 커밋(백그라운드 잡 페이지별 적재용)."""
    db.add(LLMUsage(
        user_id=user_id,
        model=model,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=input_tokens + output_tokens,
        cost_usd=cost_usd,
        latency_ms=latency_ms,
        task_type=task_type,
        language=language,
        has_textbook_context=has_textbook_context,
        error=error,
    ))
    if commit:
        await db.commit()
