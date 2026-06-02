"""Apple JWS 검증·디코드 (Track A-2).

StoreKit 2 서명 트랜잭션(`Transaction.jwsRepresentation`)과 ASSN v2 웹훅(`signedPayload`)을
**Apple root PKI 체인으로 서명 검증**한 뒤 디코드한다. 검증 없는 본문은 절대 신뢰 금지(§3.2-b).

검증 라이브러리 결정(§6.x-1): Apple 공식 `app-store-server-library`(SignedDataVerifier).
수동 x5c 체인 검증 대비 root cert 갱신·체인 검증을 라이브러리가 책임진다.

환경 분기(§3.2-b "환경"): 한 엔드포인트가 Sandbox/Production payload를 모두 받는다. 서명은
동일 root(Apple Root CA - G3)로 검증되지만 라이브러리는 생성 시 지정한 environment와 payload의
environment 불일치를 INVALID_ENVIRONMENT로 거부한다. → 두 verifier(Prod/Sandbox)를 만들고
순차 시도한다(서명 실패는 둘 다 동일하게 거부 → 위조 통과 없음).
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.JWSTransactionDecodedPayload import (
    JWSTransactionDecodedPayload,
)
from appstoreserverlibrary.models.ResponseBodyV2DecodedPayload import (
    ResponseBodyV2DecodedPayload,
)
from appstoreserverlibrary.signed_data_verifier import (
    SignedDataVerifier,
    VerificationException,
)

from app.core.config import settings

log = logging.getLogger(__name__)

_CERT_DIR = Path(__file__).parent / "apple_certs"


class AppleVerificationError(ValueError):
    """JWS 서명/체인/환경 검증 실패. 라우터에서 400으로 매핑."""


@dataclass(frozen=True)
class VerifiedTransaction:
    """검증된 트랜잭션에서 추출한 도메인 값."""

    original_transaction_id: str
    transaction_id: str
    product_id: str
    bundle_id: str
    app_account_token: str | None
    environment: str  # "Production" | "Sandbox"
    expires_at: datetime | None  # naive UTC (DB 저장 규약과 일치)
    revocation_date: datetime | None  # 환불/취소 시점
    is_revoked: bool


def _load_root_certs() -> list[bytes]:
    certs = [p.read_bytes() for p in sorted(_CERT_DIR.glob("*.cer"))]
    if not certs:
        raise AppleVerificationError("no Apple root certificates bundled")
    return certs


@lru_cache(maxsize=1)
def _verifiers() -> list[SignedDataVerifier]:
    """Production·Sandbox verifier를 순서대로 반환(순차 시도용).

    online check는 끔(§6.x-2 MVP): OCSP 네트워크 의존 없이 서명+체인만 검증. 정기 reconcile은
    fast-follow. app_apple_id 미설정 시 Production notification 검증은 라이브러리가 거부한다(Sandbox 우선).
    """
    roots = _load_root_certs()
    bundle_id = settings.APPLE_BUNDLE_ID
    app_apple_id = settings.APPLE_APP_APPLE_ID
    out: list[SignedDataVerifier] = []
    # Production은 app_apple_id 필수(라이브러리 제약). 미설정이면 Sandbox만.
    if app_apple_id:
        out.append(
            SignedDataVerifier(roots, False, Environment.PRODUCTION, bundle_id, app_apple_id)
        )
    out.append(SignedDataVerifier(roots, False, Environment.SANDBOX, bundle_id, app_apple_id))
    return out


def _ms_to_naive_utc(ms: int | None) -> datetime | None:
    if ms is None:
        return None
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).replace(tzinfo=None)


def _try_each(fn) -> object:
    """Prod→Sandbox verifier 순차 시도. 마지막 예외를 AppleVerificationError로 변환."""
    last_exc: Exception | None = None
    for verifier in _verifiers():
        try:
            return fn(verifier)
        except VerificationException as e:
            last_exc = e
            continue
    log.warning("Apple JWS verification failed across all verifiers: %s", last_exc)
    raise AppleVerificationError(f"signature verification failed: {last_exc}")


def _to_verified(tx: JWSTransactionDecodedPayload) -> VerifiedTransaction:
    env = tx.environment.value if tx.environment is not None else "Production"
    return VerifiedTransaction(
        original_transaction_id=tx.originalTransactionId or tx.transactionId or "",
        transaction_id=tx.transactionId or "",
        product_id=tx.productId or "",
        bundle_id=tx.bundleId or "",
        app_account_token=str(tx.appAccountToken) if tx.appAccountToken else None,
        environment=env,
        expires_at=_ms_to_naive_utc(tx.expiresDate),
        revocation_date=_ms_to_naive_utc(tx.revocationDate),
        is_revoked=tx.revocationDate is not None,
    )


def verify_transaction(signed_transaction: str) -> VerifiedTransaction:
    """StoreKit2 `Transaction.jwsRepresentation`을 서명 검증·디코드한다.

    실패(서명/체인/환경/bundleId 불일치) 시 AppleVerificationError.
    """
    tx: JWSTransactionDecodedPayload = _try_each(
        lambda v: v.verify_and_decode_signed_transaction(signed_transaction)
    )
    verified = _to_verified(tx)
    if verified.bundle_id != settings.APPLE_BUNDLE_ID:
        raise AppleVerificationError(
            f"bundleId mismatch: {verified.bundle_id} != {settings.APPLE_BUNDLE_ID}"
        )
    return verified


def verify_notification(signed_payload: str) -> tuple[ResponseBodyV2DecodedPayload, VerifiedTransaction | None]:
    """ASSN v2 `signedPayload`를 서명 검증·디코드한다.

    반환: (디코드된 알림, 알림에 동봉된 트랜잭션의 검증값|None).
    `data.signedTransactionInfo`도 같은 root로 재검증한다.
    """
    notification: ResponseBodyV2DecodedPayload = _try_each(
        lambda v: v.verify_and_decode_notification(signed_payload)
    )

    tx_verified: VerifiedTransaction | None = None
    data = notification.data
    if data is not None and data.signedTransactionInfo:
        tx: JWSTransactionDecodedPayload = _try_each(
            lambda v: v.verify_and_decode_signed_transaction(data.signedTransactionInfo)
        )
        tx_verified = _to_verified(tx)

    return notification, tx_verified
