"""요청 로깅 미들웨어 + 전역 예외 핸들러 (Track C-4 / Sentry A-3·A-4).

- request_id 생성/echo + contextvar 전파 → 모든 로그에 동봉(§3.2-e)
- trace_id: incoming `sentry-trace` 헤더 파싱(없으면 uuid4 자체 생성) → 모든 로그에
  `[trace:…]` 동봉 + Sentry 스코프 태그. Sentry DSN이 비어 있어도 trace_id는 항상 존재(spec §4.3).
- 응답 헤더 `X-Request-Id`
- method/path/status/latency access 로그
- 처리되지 않은 예외를 잡아 500 + request_id 반환(O5) + `sentry_sdk.capture_exception()`
  (미들웨어가 예외를 swallow하므로 Sentry 자동 통합만으로는 누락 — spec §6-1·A-3)
"""
from __future__ import annotations

import logging
import time
import uuid

import sentry_sdk
from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.core.request_context import set_request_id, set_trace_id

log = logging.getLogger("access")

_HEX = frozenset("0123456789abcdef")


def _parse_trace_id(header: str | None) -> str | None:
    """`sentry-trace` 헤더(`{trace_id}-{span_id}-{sampled}`)의 32-hex trace_id를 추출."""
    if not header:
        return None
    head = header.split("-", 1)[0].strip().lower()
    if len(head) == 32 and all(c in _HEX for c in head):
        return head
    return None


class RequestLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # 요청에 X-Request-Id가 오면 echo, 없으면 서버 생성.
        request_id = request.headers.get("X-Request-Id") or uuid.uuid4().hex
        set_request_id(request_id)
        request.state.request_id = request_id

        # trace_id: iOS가 보낸 sentry-trace를 그대로 사용(같은 trace로 상관) → 없으면 자체 생성.
        # Sentry가 켜져 있으면 FastAPI 통합도 동일 헤더를 읽어 같은 trace_id로 continue한다.
        trace_id = _parse_trace_id(request.headers.get("sentry-trace")) or uuid.uuid4().hex
        set_trace_id(trace_id)
        request.state.trace_id = trace_id

        # Sentry 스코프 태그 — DSN 빈 값이면 no-op. trace_id 태그는 우리 로그↔이벤트 보조 상관 키.
        sentry_sdk.set_tag("request_id", request_id)
        sentry_sdk.set_tag("trace_id", trace_id)

        start = time.monotonic()
        try:
            response = await call_next(request)
        except Exception:
            latency_ms = int((time.monotonic() - start) * 1000)
            log.exception(
                "unhandled exception: %s %s latency=%dms",
                request.method, request.url.path, latency_ms,
            )
            # 미들웨어가 예외를 swallow하므로 명시적으로 캡처(5xx/미처리만, 4xx는 도달 안 함).
            sentry_sdk.capture_exception()
            resp = JSONResponse(
                status_code=500,
                content={"detail": "internal server error", "request_id": request_id},
            )
            resp.headers["X-Request-Id"] = request_id
            return resp

        latency_ms = int((time.monotonic() - start) * 1000)
        response.headers["X-Request-Id"] = request_id
        log.info(
            "%s %s -> %d latency=%dms",
            request.method, request.url.path, response.status_code, latency_ms,
        )
        return response
