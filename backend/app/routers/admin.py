import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.models.usage import LLMUsage

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api/admin", tags=["admin"])


class UsageSummary(BaseModel):
    total_requests: int
    total_tokens: int
    total_input_tokens: int
    total_output_tokens: int
    total_cost_usd: float
    avg_latency_ms: float
    error_count: int


class ModelBreakdown(BaseModel):
    model: str
    request_count: int
    total_tokens: int
    total_cost_usd: float
    avg_latency_ms: float


class RecentRequest(BaseModel):
    id: str
    user_id: str
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    latency_ms: int
    task_type: str
    language: str
    error: str | None
    created_at: datetime


class UsageDashboard(BaseModel):
    summary: UsageSummary
    by_model: list[ModelBreakdown]
    recent: list[RecentRequest]


@router.get("/usage", response_model=UsageDashboard)
async def get_usage_dashboard(
    days: int = Query(7, ge=1, le=90),
    user_id: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    """개발용 LLM 사용량 대시보드."""
    since = datetime.now(timezone.utc).replace(tzinfo=None)
    since = since.replace(hour=0, minute=0, second=0, microsecond=0)
    from datetime import timedelta
    since -= timedelta(days=days)

    base_filter = LLMUsage.created_at >= since
    if user_id:
        base_filter = (LLMUsage.created_at >= since) & (LLMUsage.user_id == user_id)

    # 전체 요약
    summary_q = select(
        func.count().label("total_requests"),
        func.coalesce(func.sum(LLMUsage.total_tokens), 0).label("total_tokens"),
        func.coalesce(func.sum(LLMUsage.input_tokens), 0).label("total_input_tokens"),
        func.coalesce(func.sum(LLMUsage.output_tokens), 0).label("total_output_tokens"),
        func.coalesce(func.sum(LLMUsage.cost_usd), 0).label("total_cost_usd"),
        func.coalesce(func.avg(LLMUsage.latency_ms), 0).label("avg_latency_ms"),
        func.count().filter(LLMUsage.error.isnot(None)).label("error_count"),
    ).where(base_filter)

    result = await db.execute(summary_q)
    row = result.one()

    summary = UsageSummary(
        total_requests=row.total_requests,
        total_tokens=int(row.total_tokens),
        total_input_tokens=int(row.total_input_tokens),
        total_output_tokens=int(row.total_output_tokens),
        total_cost_usd=float(row.total_cost_usd),
        avg_latency_ms=float(row.avg_latency_ms),
        error_count=int(row.error_count or 0),
    )

    # 모델별 분석
    model_q = (
        select(
            LLMUsage.model,
            func.count().label("request_count"),
            func.coalesce(func.sum(LLMUsage.total_tokens), 0).label("total_tokens"),
            func.coalesce(func.sum(LLMUsage.cost_usd), 0).label("total_cost_usd"),
            func.coalesce(func.avg(LLMUsage.latency_ms), 0).label("avg_latency_ms"),
        )
        .where(base_filter)
        .group_by(LLMUsage.model)
        .order_by(func.sum(LLMUsage.cost_usd).desc())
    )
    result = await db.execute(model_q)
    by_model = [
        ModelBreakdown(
            model=r.model,
            request_count=r.request_count,
            total_tokens=int(r.total_tokens),
            total_cost_usd=float(r.total_cost_usd),
            avg_latency_ms=float(r.avg_latency_ms),
        )
        for r in result.all()
    ]

    # 최근 요청
    recent_q = (
        select(LLMUsage)
        .where(base_filter)
        .order_by(LLMUsage.created_at.desc())
        .limit(50)
    )
    result = await db.execute(recent_q)
    recent = [
        RecentRequest(
            id=r.id,
            user_id=r.user_id,
            model=r.model,
            input_tokens=r.input_tokens,
            output_tokens=r.output_tokens,
            cost_usd=r.cost_usd,
            latency_ms=r.latency_ms,
            task_type=r.task_type,
            language=r.language,
            error=r.error,
            created_at=r.created_at,
        )
        for r in result.scalars().all()
    ]

    return UsageDashboard(summary=summary, by_model=by_model, recent=recent)
