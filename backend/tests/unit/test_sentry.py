"""Sentry PII 스크럽 + trace_id 파싱 regression (spec §3.3·§4.3 / Track A-2·A-4).

DB 불필요. before_send가 손글씨·채팅·이메일·토큰을 새지 않는지, 미들웨어가
incoming sentry-trace를 올바르게 파싱(없으면 자체 생성)하는지를 동결.
"""
from app.core.sentry import _before_send, _scrub
from app.middleware.request_log import _parse_trace_id


def test_scrub_masks_sensitive_keys_recursively():
    event = {
        "request": {
            "headers": {"Authorization": "Bearer secret", "X-Request-Id": "abc"},
            "data": {"image": "base64blob", "message": "사용자 채팅 본문"},
        },
        "extra": {
            "nested": {"email": "user@example.com", "prompt_context_snippet": "교재 텍스트"},
            "safe": "keep-me",
        },
    }
    out = _before_send(event, {})

    # request body는 통째로 제거.
    assert "data" not in out["request"]
    # 민감 헤더 마스킹, 일반 헤더 보존.
    assert out["request"]["headers"]["Authorization"] == "[scrubbed]"
    assert out["request"]["headers"]["X-Request-Id"] == "abc"
    # 중첩 PII 키 마스킹.
    assert out["extra"]["nested"]["email"] == "[scrubbed]"
    assert out["extra"]["nested"]["prompt_context_snippet"] == "[scrubbed]"
    # 비민감 값은 보존.
    assert out["extra"]["safe"] == "keep-me"


def test_scrub_is_case_insensitive_and_handles_lists():
    event = {"items": [{"Content": "x"}, {"ok": "y"}]}
    out = _scrub(event)
    assert out["items"][0]["Content"] == "[scrubbed]"
    assert out["items"][1]["ok"] == "y"


def test_parse_trace_id_extracts_32hex_head():
    tid = "d4cd1f9b2a3e4c5d6e7f8a9b0c1d2e3f"
    assert _parse_trace_id(f"{tid}-7c2a1b3c4d5e6f70-1") == tid


def test_parse_trace_id_rejects_malformed():
    assert _parse_trace_id(None) is None
    assert _parse_trace_id("") is None
    assert _parse_trace_id("not-a-trace") is None
    assert _parse_trace_id("zzzz1f9b2a3e4c5d6e7f8a9b0c1d2e3f-span-1") is None  # 비-hex
    assert _parse_trace_id("d4cd-span-1") is None                              # 길이 부족
