"""요청 단위 컨텍스트 — request_id를 contextvar로 전파해 로그에 자동 동봉한다."""
from __future__ import annotations

import contextvars
import logging

_request_id: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")
_user_id: contextvars.ContextVar[str] = contextvars.ContextVar("user_id", default="-")


def set_request_id(value: str) -> None:
    _request_id.set(value)


def get_request_id() -> str:
    return _request_id.get()


def set_user_id(value: str) -> None:
    _user_id.set(value)


def get_user_id() -> str:
    return _user_id.get()


class RequestContextFilter(logging.Filter):
    """로그 레코드에 request_id를 주입한다 (포맷에서 %(request_id)s 사용)."""

    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = _request_id.get()
        return True
