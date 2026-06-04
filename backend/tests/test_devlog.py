"""FE 로그 수집(/api/dev/log/batch) + 422 검증 핸들러 회귀 테스트.

배경: 운영에서 /api/dev/log/batch가 끊임없이 422로 거부됐는데, 서버 로그엔
status만 남고 body·사유가 기록되지 않아 추적 불가였다. 두 가지를 고정한다.
  1) 정상 payload는 인증 없이도(익명) 200으로 수집된다 — iOS의 미인증 전송 보류
     가드 제거가 안전하다는 서버 측 전제(엔드포인트가 인증을 요구하지 않음).
  2) 검증 실패 시 RequestValidationError 핸들러가 errors() detail을 응답으로
     돌려준다(어느 필드가 거부됐는지 가시화).
"""
import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio


def _entry(**over):
    e = {"level": "error", "tag": "auth", "message": "apple sign-in failed",
         "data": {"error": "x"}, "ts": "2026-06-02T12:00:00Z"}
    e.update(over)
    return e


async def test_log_batch_anonymous_accepted(client: AsyncClient):
    """미인증(Authorization 헤더 없음)이어도 정상 payload는 200으로 수집된다."""
    res = await client.post("/api/dev/log/batch",
                            json={"logs": [_entry()], "context": {"user_id": ""}})
    assert res.status_code == 200
    assert res.json() == {"received": 1}


async def test_log_batch_empty_logs_ok(client: AsyncClient):
    res = await client.post("/api/dev/log/batch", json={"logs": []})
    assert res.status_code == 200
    assert res.json() == {"received": 0}


async def test_log_batch_missing_message_is_422_with_detail(client: AsyncClient):
    """엔트리에 message 누락 → 422. 핸들러가 errors() detail을 돌려줘야 한다."""
    bad = _entry()
    del bad["message"]
    res = await client.post("/api/dev/log/batch", json={"logs": [bad]})
    assert res.status_code == 422
    detail = res.json()["detail"]
    assert any(err["loc"][-1] == "message" and err["type"] == "missing"
               for err in detail)


async def test_log_batch_missing_logs_wrapper_is_422(client: AsyncClient):
    """logs 래퍼 없이 단건 형태 전송 → 422."""
    res = await client.post("/api/dev/log/batch", json=_entry())
    assert res.status_code == 422
    detail = res.json()["detail"]
    assert any(err["loc"][-1] == "logs" and err["type"] == "missing"
               for err in detail)


# --- 로그 포맷 회귀 (spec §3.2-a): prefix 12자리화 + provider 토큰 ---

_FULL_UID = "66d2d3d1d71d4c8e9f0a1b2c3d4e5f60"   # 32 hex
_FULL_SID = "4E8D80F4ABCD1234EF56"               # 20 hex


async def test_emit_truncates_prefixes_to_12(client: AsyncClient, caplog):
    """user_id·session_id는 12자리로 절단되어 로그에 찍힌다(8자리 아님)."""
    with caplog.at_level("INFO", logger="fe"):
        res = await client.post("/api/dev/log/batch", json={
            "logs": [_entry(level="info")],
            "context": {"user_id": _FULL_UID, "session_id": _FULL_SID},
        })
    assert res.status_code == 200
    line = "\n".join(r.message for r in caplog.records)
    assert f"[u:{_FULL_UID[:12]}]" in line
    assert f"[sess:{_FULL_SID[:12]}]" in line
    # 전체 UUID는 절단되어 그대로 노출되지 않는다.
    assert f"[u:{_FULL_UID}]" not in line


async def test_emit_includes_provider_token_when_present(client: AsyncClient, caplog):
    with caplog.at_level("INFO", logger="fe"):
        res = await client.post("/api/dev/log/batch", json={
            "logs": [_entry(level="info")],
            "context": {"user_id": _FULL_UID, "provider": "email"},
        })
    assert res.status_code == 200
    line = "\n".join(r.message for r in caplog.records)
    # [prov:]는 [u:] 뒤에 온다.
    assert f"[u:{_FULL_UID[:12]}] [prov:email]" in line


async def test_emit_omits_provider_token_when_absent(client: AsyncClient, caplog):
    """provider 없으면 [prov:] 토큰을 생략한다(하위호환)."""
    with caplog.at_level("INFO", logger="fe"):
        res = await client.post("/api/dev/log/batch", json={
            "logs": [_entry(level="info")],
            "context": {"user_id": _FULL_UID},
        })
    assert res.status_code == 200
    line = "\n".join(r.message for r in caplog.records)
    assert "[prov:" not in line
