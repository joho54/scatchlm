import logging
from typing import Optional

import jwt
from jwt import PyJWKClient
from fastapi import Depends, HTTPException, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_db
from app.models.user import User

log = logging.getLogger(__name__)
security = HTTPBearer(auto_error=False)

_jwks_client: PyJWKClient | None = None


def _get_jwks_client() -> PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        jwks_url = f"{settings.SUPABASE_URL}/auth/v1/.well-known/jwks.json"
        _jwks_client = PyJWKClient(jwks_url, cache_keys=True)
    return _jwks_client


def _verify_token_payload(token: str) -> dict:
    """JWT를 **서명 검증**하고 전체 payload를 반환한다.

    role/tier 등 보안 클레임은 반드시 이 검증된 payload에서만 읽어야 한다.
    `jwt.decode(..., options={"verify_signature": False})` 경로는 위조 가능하므로 금지.
    """
    try:
        signing_key = _get_jwks_client().get_signing_key_from_jwt(token)
        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["ES256"],
            options={"verify_aud": False},
        )
        if payload.get("sub") is None:
            log.warning("JWT missing sub claim")
            raise HTTPException(status_code=401, detail="Invalid token: no sub claim")
        return payload
    except jwt.ExpiredSignatureError:
        log.info("JWT expired")
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError as e:
        log.warning("JWT invalid: %s", e)
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")


def _verify_token(token: str) -> str:
    """JWT를 검증하고 user_id(sub)를 반환한다."""
    return _verify_token_payload(token)["sub"]


def _app_metadata(payload: dict) -> dict:
    md = payload.get("app_metadata")
    return md if isinstance(md, dict) else {}


def get_tier(payload: dict) -> str:
    """검증된 payload에서 tier를 읽는다. 미설정·미인식 → "normal"."""
    tier = _app_metadata(payload).get("tier")
    return tier if tier in ("normal", "pro") else "normal"


def get_role(payload: dict) -> str | None:
    """검증된 payload에서 role을 읽는다."""
    return _app_metadata(payload).get("role")


async def _ensure_user_exists(user_id: str, email: str | None, db: AsyncSession) -> None:
    """users 테이블에 해당 유저가 없으면 자동 생성. 데모 교재 딥카피도 best-effort 보장."""
    result = await db.execute(select(User).where(User.id == user_id))
    if result.scalar_one_or_none() is None:
        user = User(id=user_id, email=email or f"{user_id}@unknown")
        db.add(user)
        await db.commit()
        log.info("Auto-created user: %s", user_id)

    # 온보딩 데모 교재(유저별 딥카피)를 보장한다(가이드된 첫 성공 spec §4.3).
    # idempotent(있으면 no-op)라 매 요청 호출돼도 안전 — 동시에 프로비저닝 훅이자 온보딩 백스톱.
    # **best-effort**: 실패해도 인증·유저 생성은 절대 차단하지 않는다(try/except).
    try:
        from app.services.demo_textbook import ensure_demo_textbook
        await ensure_demo_textbook(user_id, db)
    except Exception:
        log.warning("ensure_demo_textbook failed (non-blocking) user=%s", user_id, exc_info=True)
        try:
            await db.rollback()  # 부분 변경 정리 — 후속 요청 처리에 영향 없게
        except Exception:
            pass


def _extract_raw_token(
    credentials: Optional[HTTPAuthorizationCredentials],
    token: Optional[str],
) -> str:
    if credentials and credentials.credentials:
        return credentials.credentials
    if token:
        return token
    raise HTTPException(status_code=401, detail="Not authenticated")


async def get_current_user_id(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security),
    token: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
) -> str:
    """Authorization 헤더 또는 ?token= 쿼리 파라미터에서 JWT를 검증한다."""
    raw_token = _extract_raw_token(credentials, token)
    payload = _verify_token_payload(raw_token)
    user_id = payload["sub"]
    await _ensure_user_exists(user_id, payload.get("email"), db)
    return user_id


async def get_verified_payload(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security),
    token: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """검증된 JWT payload 전체를 반환(role/tier 판정용). 유저 JIT 프로비저닝도 수행."""
    raw_token = _extract_raw_token(credentials, token)
    payload = _verify_token_payload(raw_token)
    await _ensure_user_exists(payload["sub"], payload.get("email"), db)
    return payload


async def require_admin(payload: dict = Depends(get_verified_payload)) -> str:
    """admin 전용 가드. 검증된 payload의 app_metadata.role == "admin"만 통과."""
    if get_role(payload) != "admin":
        log.warning("admin access denied: user=%s role=%s", payload.get("sub"), get_role(payload))
        raise HTTPException(status_code=403, detail="admin access required")
    log.info("admin access granted: user=%s", payload.get("sub"))
    return payload["sub"]
