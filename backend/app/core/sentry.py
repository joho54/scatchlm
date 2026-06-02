"""Sentry 초기화 + PII 스크럽 (Track A-2).

- `init_sentry()`는 `app = FastAPI(...)` 생성 **전**에 호출해야 한다(main.py).
- `SENTRY_DSN`이 빈 값이면 `sentry_sdk.init`을 호출하지 않아 SDK는 완전 no-op(dev 안전).
- FastAPI/Starlette/asyncio 통합은 `sentry-sdk[fastapi]`로 자동 활성화되며,
  incoming `sentry-trace`/`baggage`를 파싱해 iOS가 시작한 트레이스를 이어받는다(spec §3.1).
- 이 앱은 손글씨 이미지·교재 텍스트·채팅 본문·이메일을 다루므로(spec §3.3·§7),
  `before_send`에서 민감 헤더/본문/필드를 제거한다.
"""
from __future__ import annotations

import logging

import sentry_sdk

from app.core.config import settings

log = logging.getLogger(__name__)

# 이벤트 어디에 들어 있든 키 이름이 일치하면 마스킹(대소문자 무시). spec §3.3.
_SENSITIVE_KEYS = frozenset({
    "authorization",
    "cookie",
    "set-cookie",
    "image",
    "content",
    "message",
    "email",
    "previous_context",
    "prompt_context_snippet",
})

_SCRUBBED = "[scrubbed]"


def _scrub(obj):
    """이벤트 트리를 재귀 순회하며 민감 키 값을 마스킹한다."""
    if isinstance(obj, dict):
        return {
            k: (_SCRUBBED if isinstance(k, str) and k.lower() in _SENSITIVE_KEYS else _scrub(v))
            for k, v in obj.items()
        }
    if isinstance(obj, (list, tuple)):
        return [_scrub(v) for v in obj]
    return obj


def _before_send(event, hint):
    """전송 직전 PII 스크럽. request body는 통째로 제거(이미지·채팅 본문 누출 방지)."""
    request = event.get("request")
    if isinstance(request, dict):
        request.pop("data", None)      # body — 명시적으로 미첨부(spec §3.3)
        request.pop("cookies", None)
    return _scrub(event)


def init_sentry() -> None:
    dsn = settings.SENTRY_DSN
    if not dsn:
        log.info("Sentry disabled (SENTRY_DSN empty) — SDK no-op")
        return

    sentry_sdk.init(
        dsn=dsn,
        environment=settings.ENVIRONMENT,
        release=f"scatchlm-backend@{settings.GIT_SHA}",
        traces_sample_rate=settings.SENTRY_TRACES_SAMPLE_RATE,
        send_default_pii=False,
        before_send=_before_send,
    )
    log.info(
        "Sentry initialized: env=%s release=scatchlm-backend@%s traces_sample_rate=%s",
        settings.ENVIRONMENT, settings.GIT_SHA, settings.SENTRY_TRACES_SAMPLE_RATE,
    )
