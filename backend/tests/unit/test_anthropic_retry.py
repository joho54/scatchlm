"""create_message_with_retry 회귀 — 일시적 업스트림 장애(529/5xx/timeout)만 백오프 재시도.

529 Overloaded·5xx·timeout·connection은 지수 백오프로 재시도하고, 429(RateLimit)/4xx 등
비일시적 에러는 즉시 raise해 기존 except 핸들러(분류·502/Paywall)가 그대로 동작해야 한다.
2026-06-23 prod에서 채팅/가이드가 Anthropic 529·500을 그대로 유저에 노출한 사건의 가드.
"""
import anthropic
import pytest
from unittest.mock import AsyncMock

from app.services.feedback_service import _is_retryable, create_message_with_retry


def _status_err(code):
    e = anthropic.APIStatusError.__new__(anthropic.APIStatusError)
    e.status_code = code
    return e


@pytest.mark.parametrize("code,expected", [
    (529, True), (500, True), (502, True), (503, True), (504, True),
    (429, False), (400, False), (404, False),
])
def test_is_retryable_status(code, expected):
    assert _is_retryable(_status_err(code)) is expected


def test_is_retryable_timeout_and_connection():
    assert _is_retryable(anthropic.APITimeoutError.__new__(anthropic.APITimeoutError)) is True
    assert _is_retryable(ValueError()) is False


class _FakeClient:
    def __init__(self, side_effects):
        self.messages = type("M", (), {})()
        self.messages.create = AsyncMock(side_effect=side_effects)


async def test_retries_then_succeeds(monkeypatch):
    # asyncio.sleep을 no-op으로 패치해 테스트가 지연 없이 돈다.
    monkeypatch.setattr("app.services.feedback_service.asyncio.sleep", AsyncMock())
    client = _FakeClient([_status_err(529), _status_err(500), "ok"])
    result = await create_message_with_retry(client, base_delay=0)
    assert result == "ok"
    assert client.messages.create.await_count == 3


async def test_gives_up_after_max_attempts(monkeypatch):
    monkeypatch.setattr("app.services.feedback_service.asyncio.sleep", AsyncMock())
    client = _FakeClient([_status_err(529)] * 10)
    with pytest.raises(anthropic.APIStatusError):
        await create_message_with_retry(client, max_attempts=4, base_delay=0)
    assert client.messages.create.await_count == 4


async def test_non_retryable_raises_immediately(monkeypatch):
    monkeypatch.setattr("app.services.feedback_service.asyncio.sleep", AsyncMock())
    client = _FakeClient([_status_err(429), "should-not-reach"])
    with pytest.raises(anthropic.APIStatusError):
        await create_message_with_retry(client, base_delay=0)
    # 429는 재시도하지 않으므로 단 한 번만 호출돼야 한다.
    assert client.messages.create.await_count == 1
