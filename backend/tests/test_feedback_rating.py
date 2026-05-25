import io
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient

from app.services.feedback_service import FeedbackResult
from tests.conftest import TEST_USER_ID, make_test_token

MOCK_RESULT = FeedbackResult(
    data={"type": "feedback", "content": "テスト피드백 본문입니다."},
    model="claude-sonnet-4-6",
    input_tokens=100,
    output_tokens=20,
    total_tokens=120,
    cost_usd=0.001,
    latency_ms=500,
)


async def _create_feedback(client: AsyncClient, auth_header: dict) -> str:
    with patch(
        "app.routers.feedback.get_feedback",
        new_callable=AsyncMock,
        return_value=MOCK_RESULT,
    ):
        res = await client.post(
            "/api/feedback",
            headers=auth_header,
            files={"image": ("c.png", io.BytesIO(b"\x89PNG"), "image/png")},
            data={"note_id": "note-1", "language": "ja"},
        )
    assert res.status_code == 200
    fid = res.json().get("feedback_id")
    assert fid
    return fid


@pytest.mark.asyncio
async def test_feedback_response_includes_id(client: AsyncClient, auth_header: dict):
    fid = await _create_feedback(client, auth_header)
    assert isinstance(fid, str) and len(fid) > 0


@pytest.mark.asyncio
async def test_rate_feedback_creates_rating(client: AsyncClient, auth_header: dict):
    fid = await _create_feedback(client, auth_header)
    res = await client.post(
        f"/api/feedback/{fid}/rate",
        headers=auth_header,
        json={"rating": 1, "reason_tags": ["unhelpful"], "comment": "nice"},
    )
    assert res.status_code == 204


@pytest.mark.asyncio
async def test_rate_feedback_upsert(client: AsyncClient, auth_header: dict):
    fid = await _create_feedback(client, auth_header)
    r1 = await client.post(
        f"/api/feedback/{fid}/rate",
        headers=auth_header,
        json={"rating": -1, "reason_tags": ["tone_off"]},
    )
    r2 = await client.post(
        f"/api/feedback/{fid}/rate",
        headers=auth_header,
        json={"rating": 1, "reason_tags": []},
    )
    assert r1.status_code == 204 and r2.status_code == 204


@pytest.mark.asyncio
async def test_rate_feedback_invalid_rating(client: AsyncClient, auth_header: dict):
    fid = await _create_feedback(client, auth_header)
    res = await client.post(
        f"/api/feedback/{fid}/rate",
        headers=auth_header,
        json={"rating": 0},
    )
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_rate_feedback_not_found(client: AsyncClient, auth_header: dict):
    res = await client.post(
        "/api/feedback/does-not-exist/rate",
        headers=auth_header,
        json={"rating": 1},
    )
    assert res.status_code == 404


@pytest.mark.asyncio
async def test_rate_feedback_forbidden_other_user(client: AsyncClient, auth_header: dict):
    fid = await _create_feedback(client, auth_header)
    other_token = make_test_token(user_id="other-user-00000000-0000-0000-0000-000000000099")
    res = await client.post(
        f"/api/feedback/{fid}/rate",
        headers={"Authorization": f"Bearer {other_token}"},
        json={"rating": 1},
    )
    assert res.status_code == 403


@pytest.mark.asyncio
async def test_rate_feedback_requires_auth(client: AsyncClient, auth_header: dict):
    fid = await _create_feedback(client, auth_header)
    res = await client.post(f"/api/feedback/{fid}/rate", json={"rating": 1})
    assert res.status_code == 401
