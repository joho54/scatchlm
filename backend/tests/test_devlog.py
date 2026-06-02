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
