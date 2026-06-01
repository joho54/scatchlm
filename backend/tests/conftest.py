import time

import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization
import jwt as pyjwt
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker
from unittest.mock import patch, MagicMock

from app.core.database import get_db
from app.models.user import Base, User
from app.main import app

import os
TEST_DB_URL = os.getenv(
    "TEST_DATABASE_URL",
    "postgresql+asyncpg://postgres:postgres@localhost:5432/scatchlm_test",
)

# 테스트용 ES256 키 쌍 생성
_private_key = ec.generate_private_key(ec.SECP256R1())
_public_key = _private_key.public_key()

TEST_USER_ID = "test-user-00000000-0000-0000-0000-000000000001"
TEST_KID = "test-key-id"


def _make_test_jwk() -> dict:
    """테스트용 공개키를 JWK 형식으로 반환."""
    numbers = _public_key.public_numbers()
    import base64

    def _b64url(n: int, length: int) -> str:
        return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()

    return {
        "keys": [
            {
                "kty": "EC",
                "crv": "P-256",
                "x": _b64url(numbers.x, 32),
                "y": _b64url(numbers.y, 32),
                "kid": TEST_KID,
                "alg": "ES256",
                "use": "sig",
            }
        ]
    }


def make_test_token(user_id: str = TEST_USER_ID, expired: bool = False) -> str:
    """테스트용 ES256 JWT를 생성한다."""
    now = int(time.time())
    payload = {
        "sub": user_id,
        "iat": now,
        "exp": now - 10 if expired else now + 3600,
        "iss": "https://test.supabase.co/auth/v1",
    }
    private_pem = _private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return pyjwt.encode(payload, private_pem, algorithm="ES256", headers={"kid": TEST_KID})


@pytest.fixture(scope="session")
async def engine():
    eng = create_async_engine(TEST_DB_URL)
    async with eng.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    yield eng
    async with eng.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await eng.dispose()


@pytest.fixture(autouse=True)
async def clean_tables(engine):
    yield
    async with engine.begin() as conn:
        for table in reversed(Base.metadata.sorted_tables):
            await conn.execute(text(f"TRUNCATE {table.name} CASCADE"))


def _mock_jwks_client():
    """PyJWKClient를 모킹하여 테스트용 공개키를 반환."""
    import jwt as pyjwt

    jwk_data = _make_test_jwk()["keys"][0]
    signing_key = MagicMock()
    signing_key.key = _public_key

    mock_client = MagicMock()
    mock_client.get_signing_key_from_jwt.return_value = signing_key
    return mock_client


@pytest.fixture
async def client(engine):
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async def override_get_db():
        async with session_factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db

    # 테스트 유저를 DB에 삽입 (FK 제약 충족)
    async with session_factory() as session:
        session.add(User(id=TEST_USER_ID, email="test@scatchlm.com"))
        await session.commit()

    with patch("app.core.auth._get_jwks_client", return_value=_mock_jwks_client()):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            yield c

    app.dependency_overrides.clear()


@pytest.fixture
async def db_session(engine):
    """테스트에서 직접 DB에 행을 삽입할 때 사용하는 세션."""
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with session_factory() as session:
        yield session


@pytest.fixture
def auth_token() -> str:
    return make_test_token()


@pytest.fixture
def auth_header(auth_token: str) -> dict:
    return {"Authorization": f"Bearer {auth_token}"}
