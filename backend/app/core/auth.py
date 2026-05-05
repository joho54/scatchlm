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


def _verify_token(token: str) -> str:
    """JWT를 검증하고 user_id(sub)를 반환한다."""
    try:
        signing_key = _get_jwks_client().get_signing_key_from_jwt(token)
        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["ES256"],
            options={"verify_aud": False},
        )
        user_id: str = payload.get("sub")
        if user_id is None:
            log.warning("JWT missing sub claim")
            raise HTTPException(status_code=401, detail="Invalid token: no sub claim")
        return user_id
    except jwt.ExpiredSignatureError:
        log.info("JWT expired")
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError as e:
        log.warning("JWT invalid: %s", e)
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")


async def _ensure_user_exists(user_id: str, email: str | None, db: AsyncSession) -> None:
    """users 테이블에 해당 유저가 없으면 자동 생성."""
    result = await db.execute(select(User).where(User.id == user_id))
    if result.scalar_one_or_none() is None:
        user = User(id=user_id, email=email or f"{user_id}@unknown")
        db.add(user)
        await db.commit()
        log.info("Auto-created user: %s", user_id)


async def get_current_user_id(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security),
    token: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
) -> str:
    """Authorization 헤더 또는 ?token= 쿼리 파라미터에서 JWT를 검증한다."""
    if credentials and credentials.credentials:
        raw_token = credentials.credentials
    elif token:
        raw_token = token
    else:
        raise HTTPException(status_code=401, detail="Not authenticated")

    user_id = _verify_token(raw_token)

    # JWT에서 email 추출
    payload = jwt.decode(raw_token, options={"verify_signature": False})
    email = payload.get("email")

    await _ensure_user_exists(user_id, email, db)
    return user_id
