"""학습 자료 추천(Discover) 라우터 — docs/discover-feature-spec.md §3.2-a, A-1.

POST /api/discover — 자연어 질의 → 무료 공개 학습자료 추천.
auth는 get_verified_payload(tier/role 필요), 쿼터는 피드백/채팅과 동일한 일일 비용 한도 공유.
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_role, get_tier, get_verified_payload
from app.core.database import get_db
from app.core.quota import check_daily_quota
from app.services import discover_service

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["discover"])


class DiscoverRequest(BaseModel):
    query: str = Field(..., min_length=1, max_length=500)
    response_language: str = "Korean"


class DiscoverItem(BaseModel):
    title: str
    url: str
    format: str
    level: str
    why: str


class DiscoverResponse(BaseModel):
    recommendations: list[DiscoverItem] = []
    note: str = ""


class DiscoverSuggestion(BaseModel):
    topic: str
    bridge: str = ""


class DiscoverSuggestionsResponse(BaseModel):
    suggestions: list[DiscoverSuggestion] = []


@router.post("/discover", response_model=DiscoverResponse)
async def discover(
    body: DiscoverRequest,
    payload: dict = Depends(get_verified_payload),
    db: AsyncSession = Depends(get_db),
):
    user_id = payload["sub"]
    tier = get_tier(payload)
    is_admin = get_role(payload) == "admin"

    query = body.query.strip()
    if not query:
        # trim 후 비면 422 (§3.2-a). Pydantic min_length는 trim 전이라 여기서 한 번 더.
        raise HTTPException(status_code=422, detail="query is empty after trim")

    log.info("Discover [start]: user=%s tier=%s langlen=%d qlen=%d", user_id, tier, len(body.response_language), len(query))

    # 쿼터 게이트 — LLM 호출 없이 429 (§4.1-0). 피드백/채팅과 동일 일일 비용 한도 공유.
    await check_daily_quota(user_id, tier, db, is_admin=is_admin)

    try:
        result = await discover_service.run_discovery(
            db,
            user_id=user_id,
            query=query,
            response_language=body.response_language or "Korean",
            is_admin=is_admin,
        )
    except HTTPException:
        raise
    except Exception:
        log.exception("Discover: LLM/parse failure user=%s", user_id)
        raise HTTPException(status_code=502, detail="discover upstream failure")

    # 백엔드 독립 재검증 — 죽은/비PDF/리다이렉트실패 URL 제거(§4.1-4).
    verified = await discover_service.verify_urls(result["recommendations"])
    note = result["note"]
    if result["recommendations"] and not verified and not note:
        note = "추천 후보의 링크를 확인할 수 없었습니다. 주제를 더 구체적으로 입력해 보세요."

    # usage 적재 commit (run_discovery는 add만 했고 commit=False).
    await db.commit()

    log.info("Discover [done]: user=%s rec=%d verified=%d", user_id, len(result["recommendations"]), len(verified))
    return DiscoverResponse(
        recommendations=[DiscoverItem(**r) for r in verified],
        note=note,
    )


@router.get("/discover/suggestions", response_model=DiscoverSuggestionsResponse)
async def discover_suggestions(
    response_language: str = Query("Korean"),
    payload: dict = Depends(get_verified_payload),
    db: AsyncSession = Depends(get_db),
):
    """서재 기반 "새로 도전해볼 분야" 제안 프롬프트(Sonnet). 보조 UI라 쿼터 하드게이트는 두지 않는다
    (시트 열 때 자동 호출 → 429로 막으면 거슬림). usage는 billable로 적재해 예산엔 합산.
    실패는 빈 배열(서비스에서 흡수)."""
    user_id = payload["sub"]
    is_admin = get_role(payload) == "admin"
    suggestions = await discover_service.suggest_queries(
        db, user_id=user_id, response_language=response_language or "Korean", is_admin=is_admin
    )
    await db.commit()
    return DiscoverSuggestionsResponse(suggestions=suggestions)
