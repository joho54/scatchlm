"""Supabase JWT 인증 검증 테스트."""
import io

import pytest
from httpx import AsyncClient

from tests.conftest import make_test_token


@pytest.mark.asyncio
async def test_no_token_returns_401(client: AsyncClient):
    """토큰 없이 보호된 엔드포인트 접근 시 401."""
    res = await client.post(
        "/api/feedback",
        files={"image": ("test.png", io.BytesIO(b"\x89PNG"), "image/png")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_invalid_token_returns_401(client: AsyncClient):
    """잘못된 토큰으로 접근 시 401."""
    res = await client.post(
        "/api/feedback",
        headers={"Authorization": "Bearer invalid.token.here"},
        files={"image": ("test.png", io.BytesIO(b"\x89PNG"), "image/png")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_expired_token_returns_401(client: AsyncClient):
    """만료된 토큰으로 접근 시 401."""
    expired_token = make_test_token(expired=True)
    res = await client.post(
        "/api/feedback",
        headers={"Authorization": f"Bearer {expired_token}"},
        files={"image": ("test.png", io.BytesIO(b"\x89PNG"), "image/png")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_valid_token_passes_auth(client: AsyncClient, auth_header: dict):
    """유효한 Supabase JWT로 접근 시 인증 통과 (400 = 인증은 통과, 빈 이미지 에러)."""
    res = await client.post(
        "/api/feedback",
        headers=auth_header,
        files={"image": ("test.png", io.BytesIO(b""), "image/png")},
        data={"note_id": "note-1"},
    )
    # 401이 아님 = 인증 통과. 빈 이미지이므로 400 반환.
    assert res.status_code == 400
    assert "Empty image" in res.json()["detail"]


@pytest.mark.asyncio
async def test_token_without_sub_returns_401(client: AsyncClient):
    """sub 클레임이 없는 토큰은 401."""
    import time
    import jwt as pyjwt
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization

    # sub 없는 토큰 생성 (별도 키로는 검증 실패하므로 conftest 키 재사용)
    from tests.conftest import _private_key, TEST_KID

    now = int(time.time())
    token = pyjwt.encode(
        {"iat": now, "exp": now + 3600},  # sub 없음
        _private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ),
        algorithm="ES256",
        headers={"kid": TEST_KID},
    )
    res = await client.post(
        "/api/feedback",
        headers={"Authorization": f"Bearer {token}"},
        files={"image": ("test.png", io.BytesIO(b"\x89PNG"), "image/png")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 401
    assert "no sub" in res.json()["detail"]
