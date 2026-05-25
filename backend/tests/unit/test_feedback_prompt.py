"""피드백 프롬프트 회귀 테스트 — JSON 지시 재유입 방지."""

from app.services.feedback_service import _build_system_prompt


def test_system_prompt_no_json_instruction():
    """시스템 프롬프트에 JSON 포맷 지시가 없어야 한다."""
    prompt = _build_system_prompt("Korean", has_textbook=False)
    assert "JSON" not in prompt
    assert "json" not in prompt


def test_system_prompt_with_textbook_no_json():
    """교재 컨텍스트가 있어도 JSON 지시가 없어야 한다."""
    prompt = _build_system_prompt("Korean", has_textbook=True)
    assert "JSON" not in prompt
    assert "json" not in prompt
    assert "교재 외 참고" in prompt


def test_system_prompt_contains_response_language():
    """응답 언어가 시스템 프롬프트에 포함되어야 한다."""
    prompt = _build_system_prompt("Japanese")
    assert "Japanese" in prompt


def test_system_prompt_citation_rules_only_with_textbook():
    """출처 인용 규칙은 교재가 있을 때만 포함."""
    without = _build_system_prompt("Korean", has_textbook=False)
    with_tb = _build_system_prompt("Korean", has_textbook=True)
    assert "SOURCE CITATION" not in without
    assert "SOURCE CITATION" in with_tb
