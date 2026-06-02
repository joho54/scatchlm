"""IAP 엔드포인트 테스트 (Track A-4).

Apple JWS 검증(apple_iap)과 Supabase Admin 호출은 네트워크/서명이 필요하므로 모킹한다.
엔드포인트 자체 로직(매핑·status 도출·entitlement upsert·tier 응답)을 검증한다.
"""
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy import select

from app.models.iap import IapEntitlement
from app.services.apple_iap import AppleVerificationError, VerifiedTransaction
from tests.conftest import TEST_USER_ID

PRODUCT = "com.joho54.scatchlm.pro.monthly"


def _naive_utc(offset_days: float) -> datetime:
    return (datetime.now(timezone.utc) + timedelta(days=offset_days)).replace(tzinfo=None)


def _tx(*, expires_days: float | None = 30.0, app_account_token: str | None = TEST_USER_ID,
        revoked: bool = False, otid: str = "otid-1") -> VerifiedTransaction:
    return VerifiedTransaction(
        original_transaction_id=otid,
        transaction_id="txid-1",
        product_id=PRODUCT,
        bundle_id="com.joho54.scatchlm",
        app_account_token=app_account_token,
        environment="Sandbox",
        expires_at=_naive_utc(expires_days) if expires_days is not None else None,
        revocation_date=_naive_utc(-1) if revoked else None,
        is_revoked=revoked,
    )


# tier 동기화(Supabase Admin REST)는 항상 모킹 — 네트워크 차단.
@pytest.fixture(autouse=True)
def _mock_set_metadata():
    with patch("app.services.iap_service.supabase_admin.set_app_metadata",
               new=AsyncMock(return_value={"tier": "pro"})):
        yield


@pytest.mark.asyncio
async def test_verify_active_returns_pro(client, auth_header, db_session):
    with patch("app.routers.iap.verify_transaction", return_value=_tx()):
        resp = await client.post("/api/iap/verify",
                                 json={"signed_transaction": "jws"}, headers=auth_header)
    assert resp.status_code == 200
    body = resp.json()
    assert body["tier"] == "pro"
    assert body["product_id"] == PRODUCT
    assert body["environment"] == "Sandbox"
    assert body["expires_at"] is not None

    ent = await db_session.scalar(select(IapEntitlement).where(IapEntitlement.user_id == TEST_USER_ID))
    assert ent is not None and ent.status == "active"


@pytest.mark.asyncio
async def test_verify_expired_returns_normal(client, auth_header):
    with patch("app.routers.iap.verify_transaction", return_value=_tx(expires_days=-5)):
        resp = await client.post("/api/iap/verify",
                                 json={"signed_transaction": "jws"}, headers=auth_header)
    assert resp.status_code == 200
    assert resp.json()["tier"] == "normal"


@pytest.mark.asyncio
async def test_verify_invalid_jws_400(client, auth_header):
    with patch("app.routers.iap.verify_transaction",
               side_effect=AppleVerificationError("bad sig")):
        resp = await client.post("/api/iap/verify",
                                 json={"signed_transaction": "jws"}, headers=auth_header)
    assert resp.status_code == 400
    assert resp.json()["detail"]["code"] == "iap_invalid"


@pytest.mark.asyncio
async def test_verify_account_mismatch_409(client, auth_header):
    with patch("app.routers.iap.verify_transaction",
               return_value=_tx(app_account_token="someone-else-uuid")):
        resp = await client.post("/api/iap/verify",
                                 json={"signed_transaction": "jws"}, headers=auth_header)
    assert resp.status_code == 409
    assert resp.json()["detail"]["code"] == "iap_account_mismatch"


@pytest.mark.asyncio
async def test_verify_requires_auth(client):
    resp = await client.post("/api/iap/verify", json={"signed_transaction": "jws"})
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_status_no_entitlement(client, auth_header):
    resp = await client.get("/api/iap/status", headers=auth_header)
    assert resp.status_code == 200
    body = resp.json()
    assert body == {"tier": "normal", "product_id": None, "expires_at": None, "active": False}


@pytest.mark.asyncio
async def test_status_active_entitlement(client, auth_header, db_session):
    db_session.add(IapEntitlement(
        original_transaction_id="otid-9", user_id=TEST_USER_ID, product_id=PRODUCT,
        status="active", expires_at=_naive_utc(30), environment="Sandbox",
    ))
    await db_session.commit()
    resp = await client.get("/api/iap/status", headers=auth_header)
    assert resp.status_code == 200
    body = resp.json()
    assert body["tier"] == "pro" and body["active"] is True
    assert body["product_id"] == PRODUCT


@pytest.mark.asyncio
async def test_notifications_invalid_signature_400(client):
    with patch("app.routers.iap.verify_notification",
               side_effect=AppleVerificationError("bad sig")):
        resp = await client.post("/api/iap/notifications", json={"signedPayload": "jws"})
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_notifications_missing_payload_400(client):
    resp = await client.post("/api/iap/notifications", json={})
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_notifications_expired_sets_normal(client, db_session):
    # 먼저 활성 entitlement 존재
    db_session.add(IapEntitlement(
        original_transaction_id="otid-1", user_id=TEST_USER_ID, product_id=PRODUCT,
        status="active", expires_at=_naive_utc(30), environment="Sandbox",
    ))
    await db_session.commit()

    notif = _FakeNotif("EXPIRED")
    with patch("app.routers.iap.verify_notification",
               return_value=(notif, _tx(expires_days=-2, app_account_token=None))):
        resp = await client.post("/api/iap/notifications", json={"signedPayload": "jws"})
    assert resp.status_code == 200
    assert resp.json() == {"received": True}

    db_session.expire_all()
    ent = await db_session.scalar(select(IapEntitlement).where(IapEntitlement.original_transaction_id == "otid-1"))
    assert ent.status == "expired"
    assert ent.last_notification_type == "EXPIRED"


@pytest.mark.asyncio
async def test_notifications_renew_creates_active(client, db_session):
    notif = _FakeNotif("DID_RENEW")
    with patch("app.routers.iap.verify_notification",
               return_value=(notif, _tx(otid="otid-renew"))):
        resp = await client.post("/api/iap/notifications", json={"signedPayload": "jws"})
    assert resp.status_code == 200
    ent = await db_session.scalar(select(IapEntitlement).where(IapEntitlement.original_transaction_id == "otid-renew"))
    assert ent is not None and ent.status == "active" and ent.user_id == TEST_USER_ID


class _FakeNotif:
    """ResponseBodyV2DecodedPayload 대역 — notificationType.value / notificationUUID만 사용."""
    def __init__(self, ntype: str):
        self.notificationType = _Enum(ntype)
        self.rawNotificationType = ntype
        self.notificationUUID = "uuid-" + ntype


class _Enum:
    def __init__(self, value: str):
        self.value = value
