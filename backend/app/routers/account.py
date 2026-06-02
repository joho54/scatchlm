"""계정 삭제 엔드포인트 (L1 / Track A-1).

계약: docs/launch-readiness-implementation-spec.md §3.2-a.
"""
import logging

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.services import account_deletion
from app.services.supabase_admin import delete_auth_user

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["account"])


@router.delete("/account")
async def delete_account(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """현재 유저의 전 데이터·blob·Supabase auth 유저를 삭제한다."""
    log.warning("Account deletion requested: user=%s", user_id)

    # 1. blob 키 수집 (행 삭제 전)
    blob_keys = await account_deletion.collect_blob_keys(user_id, db)

    # 2. 단일 트랜잭션으로 DB 행 삭제 → 커밋. 실패 시 롤백(아무것도 삭제 안 됨).
    try:
        counts = await account_deletion.delete_db_rows(user_id, db)
        await db.commit()
    except Exception:
        await db.rollback()
        log.exception("Account deletion DB stage failed: user=%s", user_id)
        raise HTTPException(
            status_code=500,
            detail={"detail": "account deletion failed", "stage": "db"},
        )

    # 3. 커밋 후 blob 삭제
    blob_count = account_deletion.delete_blobs(user_id, blob_keys)
    counts["blobs"] = blob_count

    # 4. 마지막에 Supabase auth 유저 삭제(재시도 가능하게 맨 끝)
    try:
        await delete_auth_user(user_id)
        supabase_auth_deleted = True
    except Exception:
        log.exception("Account deletion auth stage failed (data already deleted): user=%s", user_id)
        # DB·blob는 이미 삭제됨 → 502. iOS는 이 경우에도 로컬 purge + 로그아웃 진행.
        return JSONResponse(
            status_code=502,
            content={
                "detail": "data deleted but auth removal failed",
                "supabase_auth_deleted": False,
                "user_id": user_id,
                "counts": counts,
            },
        )

    log.warning("Account deletion done: user=%s counts=%s", user_id, counts)
    return {
        "deleted": True,
        "user_id": user_id,
        "counts": counts,
        "supabase_auth_deleted": supabase_auth_deleted,
    }
