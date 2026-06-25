"""get_feedback 프롬프트 캐싱 배선 회귀 테스트.

교재 컨텍스트(챕터 전문)가 user 메시지가 아니라 cache_control:ephemeral가 걸린
system 블록으로 올라가는지, 교재 미연결이면 평문 system으로 떨어지는지 가드한다.
변동분(손글씨 이미지)이 캐시 경계 뒤에 남아야 같은 페이지 반복 채점에서 캐시가 산다.
"""
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest

from app.services.feedback_service import get_feedback


def _fake_response():
    return SimpleNamespace(
        usage=SimpleNamespace(input_tokens=10, output_tokens=5,
                              cache_read_input_tokens=0, cache_creation_input_tokens=0),
        content=[SimpleNamespace(text=json.dumps(
            {"transcription": "t", "feedback": "f", "keywords": []}))],
        stop_reason="end_turn",
    )


def _user_text(kwargs):
    blocks = kwargs["messages"][0]["content"]
    return " ".join(b["text"] for b in blocks if b.get("type") == "text")


@pytest.mark.asyncio
async def test_textbook_context_goes_to_cached_system_block():
    with patch("app.services.feedback_service.create_message_with_retry",
               new=AsyncMock(return_value=_fake_response())) as mock_call:
        await get_feedback(
            image_bytes=b"\xff\xd8fakejpeg",
            language="Latin",
            response_language="Korean",
            textbook_context="CHAPTER-ONLY-BODY-MARKER",
            intent="grade",
        )
    kwargs = mock_call.call_args.kwargs
    system = kwargs["system"]
    # system은 블록 배열, 마지막 블록 = 교재 텍스트 + cache_control(ephemeral)
    assert isinstance(system, list)
    tb_block = system[-1]
    assert tb_block["cache_control"] == {"type": "ephemeral"}
    assert "CHAPTER-ONLY-BODY-MARKER" in tb_block["text"]
    # 교재 텍스트는 user 메시지(캐시 경계 뒤)에 중복되면 안 됨
    assert "CHAPTER-ONLY-BODY-MARKER" not in _user_text(kwargs)


@pytest.mark.asyncio
async def test_no_textbook_uses_plain_string_system():
    with patch("app.services.feedback_service.create_message_with_retry",
               new=AsyncMock(return_value=_fake_response())) as mock_call:
        await get_feedback(
            image_bytes=b"\xff\xd8fakejpeg",
            language="Latin",
            response_language="Korean",
            textbook_context=None,
            intent="grade",
        )
    # 캐시할 큰 prefix가 없으면 평문 system(무캐시) — 블록 배열로 감싸지 않는다.
    assert isinstance(mock_call.call_args.kwargs["system"], str)
