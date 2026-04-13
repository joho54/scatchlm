import pytest
from httpx import AsyncClient


@pytest.mark.asyncio
async def test_signup(client: AsyncClient):
    res = await client.post(
        "/api/auth/signup",
        json={"email": "new@test.com", "password": "pass1234"},
    )
    assert res.status_code == 200
    data = res.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"


@pytest.mark.asyncio
async def test_signup_duplicate_email(client: AsyncClient):
    payload = {"email": "dup@test.com", "password": "pass1234"}
    await client.post("/api/auth/signup", json=payload)
    res = await client.post("/api/auth/signup", json=payload)
    assert res.status_code == 400
    assert "already registered" in res.json()["detail"]


@pytest.mark.asyncio
async def test_login_success(client: AsyncClient):
    payload = {"email": "login@test.com", "password": "pass1234"}
    await client.post("/api/auth/signup", json=payload)
    res = await client.post("/api/auth/login", json=payload)
    assert res.status_code == 200
    assert "access_token" in res.json()


@pytest.mark.asyncio
async def test_login_wrong_password(client: AsyncClient):
    await client.post(
        "/api/auth/signup",
        json={"email": "wrong@test.com", "password": "pass1234"},
    )
    res = await client.post(
        "/api/auth/login",
        json={"email": "wrong@test.com", "password": "wrongpass"},
    )
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_login_nonexistent_user(client: AsyncClient):
    res = await client.post(
        "/api/auth/login",
        json={"email": "nobody@test.com", "password": "pass1234"},
    )
    assert res.status_code == 401
