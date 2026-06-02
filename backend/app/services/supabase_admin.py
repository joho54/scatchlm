"""Supabase service-role 클라이언트.

JWT 검증만 하는 `core/auth.py`와 달리, 이 모듈은 **Supabase secret 키**(신형, 옛
service_role)로 Admin REST를 호출한다(현재는 auth 유저 삭제 전용). 이 키는 RLS를
우회하는 강력한 비밀이므로 절대 응답·로그·클라이언트에 노출하지 않는다.

`SUPABASE_SECRET_KEY` env 필요. 미설정이면 `delete_auth_user`는 RuntimeError.
"""
from __future__ import annotations

import logging

import httpx

from app.core.config import settings

log = logging.getLogger(__name__)


class SupabaseAdminError(RuntimeError):
    """Supabase Admin REST 호출 실패."""


def _require_config() -> tuple[str, str]:
    if not settings.SUPABASE_URL:
        raise SupabaseAdminError("SUPABASE_URL not configured")
    if not settings.SUPABASE_SECRET_KEY:
        raise SupabaseAdminError("SUPABASE_SECRET_KEY not configured")
    return settings.SUPABASE_URL.rstrip("/"), settings.SUPABASE_SECRET_KEY


async def set_app_metadata(user_id: str, patch: dict) -> dict:
    """`app_metadata`에 patch를 병합 반영한다 (Admin REST `PUT /auth/v1/admin/users/{id}`).

    **read-modify-write merge**(§6.x-3): 먼저 현재 유저를 GET해 기존 `app_metadata`를 읽고,
    patch를 얕게 병합한 전체 dict를 PUT한다. GoTrue가 app_metadata를 replace해도 `role` 등
    기존 키가 보존되도록 하기 위함(merge 동작 불확실성에 대한 방어).

    Returns 병합 후 app_metadata. 실패 시 SupabaseAdminError.
    """
    base_url, service_key = _require_config()
    url = f"{base_url}/auth/v1/admin/users/{user_id}"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }
    async with httpx.AsyncClient(timeout=15.0) as client:
        get_resp = await client.get(url, headers=headers)
        if get_resp.status_code != 200:
            log.error("Supabase get user failed: user=%s status=%d", user_id, get_resp.status_code)
            raise SupabaseAdminError(f"get user failed: status={get_resp.status_code}")
        current = get_resp.json().get("app_metadata") or {}
        merged = {**current, **patch}
        put_resp = await client.put(url, headers=headers, json={"app_metadata": merged})

    if put_resp.status_code == 200:
        log.info("Supabase app_metadata updated: user=%s keys=%s", user_id, list(patch.keys()))
        return put_resp.json().get("app_metadata") or merged
    log.error("Supabase app_metadata update failed: user=%s status=%d", user_id, put_resp.status_code)
    raise SupabaseAdminError(f"app_metadata update failed: status={put_resp.status_code}")


async def delete_auth_user(user_id: str) -> bool:
    """Supabase auth 유저를 삭제한다 (Admin REST `DELETE /auth/v1/admin/users/{id}`).

    Returns True on success(또는 이미 없음=404→멱등 성공). 실패 시 SupabaseAdminError.
    """
    base_url, service_key = _require_config()
    url = f"{base_url}/auth/v1/admin/users/{user_id}"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
    }
    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.delete(url, headers=headers)

    if resp.status_code in (200, 204):
        log.info("Supabase auth user deleted: %s", user_id)
        return True
    if resp.status_code == 404:
        # 이미 없음 — 멱등적으로 성공 취급.
        log.info("Supabase auth user already absent: %s", user_id)
        return True
    log.error("Supabase auth user delete failed: user=%s status=%d", user_id, resp.status_code)
    raise SupabaseAdminError(f"auth delete failed: status={resp.status_code}")
