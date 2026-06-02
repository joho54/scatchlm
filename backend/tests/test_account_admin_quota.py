"""Track A(계정삭제·admin 가드) + B(quota 429) 통합 테스트."""
import io
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient

from app.models.usage import LLMUsage
from tests.conftest import TEST_USER_ID
from tests.test_feedback import MOCK_RESULT

pytestmark = pytest.mark.asyncio


# --- A-3: admin 가드 ---

async def test_admin_usage_forbidden_for_non_admin(client: AsyncClient, auth_header: dict):
    res = await client.get("/api/admin/usage", headers=auth_header)
    assert res.status_code == 403
    assert res.json()["detail"] == "admin access required"


async def test_admin_usage_ok_for_admin(client: AsyncClient, admin_header: dict):
    res = await client.get("/api/admin/usage", headers=admin_header)
    assert res.status_code == 200


# --- A-1: 계정 삭제 ---

async def test_delete_account_happy_path(client: AsyncClient, auth_header: dict, db_session):
    # 유저 데이터 적재(llm_usage 1건)
    db_session.add(LLMUsage(
        user_id=TEST_USER_ID, model="m", input_tokens=1, output_tokens=1,
        total_tokens=2, cost_usd=0.01, latency_ms=1, task_type="complex", language="en",
    ))
    await db_session.commit()

    with patch("app.routers.account.delete_auth_user", new_callable=AsyncMock, return_value=True) as m:
        res = await client.delete("/api/account", headers=auth_header)

    assert res.status_code == 200
    body = res.json()
    assert body["deleted"] is True
    assert body["supabase_auth_deleted"] is True
    assert body["counts"]["llm_usage"] >= 1
    assert body["counts"]["users"] == 1
    m.assert_awaited_once()


async def test_delete_account_partial_failure_returns_502(client: AsyncClient, auth_header: dict):
    # auth 삭제 실패 → DB·blob는 삭제됐으나 502.
    with patch("app.routers.account.delete_auth_user", new_callable=AsyncMock, side_effect=RuntimeError("boom")):
        res = await client.delete("/api/account", headers=auth_header)
    assert res.status_code == 502
    assert res.json()["supabase_auth_deleted"] is False


# --- B-1: quota 429 ---

async def test_quota_429_after_limit(client: AsyncClient, auth_header: dict, monkeypatch):
    # 한도를 MOCK_RESULT.cost_usd 미만으로 설정해 2번째 요청이 막히게 한다.
    from app.core import quota
    monkeypatch.setattr(quota.settings, "DAILY_COST_LIMIT_NORMAL_USD", 0.001)

    with patch("app.routers.feedback.get_feedback", new_callable=AsyncMock, return_value=MOCK_RESULT):
        first = await client.post(
            "/api/feedback", headers=auth_header,
            files={"image": ("c.png", io.BytesIO(b"\x89PNG x"), "image/png")},
            data={"note_id": "n1", "language": "ja"},
        )
        assert first.status_code == 200  # 첫 요청은 used=0 < limit 통과

        second = await client.post(
            "/api/feedback", headers=auth_header,
            files={"image": ("c.png", io.BytesIO(b"\x89PNG x"), "image/png")},
            data={"note_id": "n1", "language": "ja"},
        )

    assert second.status_code == 429
    assert "Retry-After" in second.headers
    detail = second.json()["detail"]
    assert detail["code"] == "quota_exceeded"
