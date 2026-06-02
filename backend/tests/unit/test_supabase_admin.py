"""set_app_metadata 회귀 — read-modify-write merge가 기존 키(role)를 보존해야 한다.

§7 Risk: "set_app_metadata가 role 등 기존 키 clobber → 높음". GoTrue가 app_metadata를
replace하더라도 GET→merge→PUT로 role이 유지되는지 단위 검증(네트워크는 모킹).
"""
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.core.config import settings
from app.services import supabase_admin


def _mock_client(get_json: dict, put_json: dict | None = None, put_status: int = 200):
    """httpx.AsyncClient async-context-manager 대역. get/put 호출을 기록한다."""
    client = MagicMock()
    get_resp = MagicMock(status_code=200)
    get_resp.json.return_value = get_json
    put_resp = MagicMock(status_code=put_status)
    put_resp.json.return_value = put_json if put_json is not None else get_json
    client.get = AsyncMock(return_value=get_resp)
    client.put = AsyncMock(return_value=put_resp)

    cm = MagicMock()
    cm.__aenter__ = AsyncMock(return_value=client)
    cm.__aexit__ = AsyncMock(return_value=False)
    return cm, client


@pytest.fixture(autouse=True)
def _configure(monkeypatch):
    monkeypatch.setattr(settings, "SUPABASE_URL", "https://test.supabase.co")
    monkeypatch.setattr(settings, "SUPABASE_SECRET_KEY", "svc-key")


@pytest.mark.asyncio
async def test_merge_preserves_existing_role():
    cm, client = _mock_client(get_json={"app_metadata": {"role": "admin", "tier": "normal"}})
    with patch.object(supabase_admin.httpx, "AsyncClient", return_value=cm):
        result = await supabase_admin.set_app_metadata("u-1", {"tier": "pro"})

    # PUT 본문은 기존 role + 갱신된 tier를 모두 포함해야 한다.
    sent = client.put.call_args.kwargs["json"]["app_metadata"]
    assert sent == {"role": "admin", "tier": "pro"}
    assert result["role"] == "admin"


@pytest.mark.asyncio
async def test_merge_with_empty_existing_metadata():
    cm, client = _mock_client(get_json={"app_metadata": None})
    with patch.object(supabase_admin.httpx, "AsyncClient", return_value=cm):
        await supabase_admin.set_app_metadata("u-1", {"tier": "pro"})
    sent = client.put.call_args.kwargs["json"]["app_metadata"]
    assert sent == {"tier": "pro"}


@pytest.mark.asyncio
async def test_put_failure_raises():
    cm, _ = _mock_client(get_json={"app_metadata": {}}, put_status=500)
    with patch.object(supabase_admin.httpx, "AsyncClient", return_value=cm):
        with pytest.raises(supabase_admin.SupabaseAdminError):
            await supabase_admin.set_app_metadata("u-1", {"tier": "pro"})
