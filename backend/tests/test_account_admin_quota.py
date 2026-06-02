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
    assert body["blobs_complete"] is True
    assert body["counts"]["llm_usage"] >= 1
    assert body["counts"]["users"] == 1
    m.assert_awaited_once()


async def test_delete_account_blobs_complete_false_on_prefix_failure(
    client: AsyncClient, auth_header: dict, monkeypatch
):
    # blob prefix 삭제가 실패하면(유저 드로잉 잔존) 삼키지 않고 blobs_complete=False로 보고.
    # DB는 삭제됐으므로 클라 플로우(200) 유지 — 삭제 자체를 막지 않는다.
    from app.services import account_deletion as ad

    def _boom(*_a):
        raise RuntimeError("storage down")

    monkeypatch.setattr(ad.storage, "delete_prefix", _boom)

    with patch("app.routers.account.delete_auth_user", new_callable=AsyncMock, return_value=True):
        res = await client.delete("/api/account", headers=auth_header)

    assert res.status_code == 200
    assert res.json()["blobs_complete"] is False


# --- A-1: delete_blobs 실패 surface (순수 로직 regression) ---

def test_delete_blobs_surfaces_prefix_failure(monkeypatch):
    from app.services import account_deletion as ad

    def _boom(*_a):
        raise RuntimeError("storage down")

    monkeypatch.setattr(ad.storage, "delete_prefix", _boom)
    monkeypatch.setattr(ad.storage, "delete", lambda _k: None)

    count, failures = ad.delete_blobs("u1", ["k1"])
    # prefix 실패가 삼켜지지 않고 보고돼야 한다(개인정보 삭제 완전성).
    assert any("sync/u1/" in f for f in failures)


def test_delete_blobs_missing_key_is_idempotent(monkeypatch):
    from app.services import account_deletion as ad

    monkeypatch.setattr(ad.storage, "delete_prefix", lambda _p: 0)

    def _missing(_k):
        raise FileNotFoundError(_k)

    monkeypatch.setattr(ad.storage, "delete", _missing)

    count, failures = ad.delete_blobs("u1", ["gone"])
    assert failures == []   # 이미 없는 키는 실패가 아니라 멱등 성공
    assert count == 1


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
