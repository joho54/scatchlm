"""요청 로깅 미들웨어 + 전역 예외 핸들러 (Track C-4).

- request_id 생성/echo + contextvar 전파 → 모든 로그에 동봉(§3.2-e)
- 응답 헤더 `X-Request-Id`
- method/path/status/latency access 로그
- 처리되지 않은 예외를 잡아 500 + request_id 반환(O5)
"""
from __future__ import annotations

import logging
import time
import uuid

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.core.request_context import set_request_id

log = logging.getLogger("access")


class RequestLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # 요청에 X-Request-Id가 오면 echo, 없으면 서버 생성.
        request_id = request.headers.get("X-Request-Id") or uuid.uuid4().hex
        set_request_id(request_id)
        request.state.request_id = request_id

        start = time.monotonic()
        try:
            response = await call_next(request)
        except Exception:
            latency_ms = int((time.monotonic() - start) * 1000)
            log.exception(
                "unhandled exception: %s %s latency=%dms",
                request.method, request.url.path, latency_ms,
            )
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
