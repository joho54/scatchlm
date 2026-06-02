"""피드백 프롬프트 회귀 테스트 — JSON 지시 재유입 방지 + 분야 범용화."""

from app.services.feedback_service import _build_system_prompt


def test_system_prompt_no_json_instruction():
    """시스템 프롬프트에 JSON 포맷 지시가 없어야 한다."""
    prompt = _build_system_prompt("Japanese", "Korean", has_textbook=False)
    assert "JSON" not in prompt
    assert "json" not in prompt


def test_system_prompt_with_textbook_no_json():
    """교재 컨텍스트가 있어도 JSON 지시가 없어야 한다."""
    prompt = _build_system_prompt("Japanese", "Korean", has_textbook=True)
    assert "JSON" not in prompt
    assert "json" not in prompt
    assert "교재 외 참고" in prompt


def test_system_prompt_contains_response_language():
    """응답 언어가 시스템 프롬프트에 포함되어야 한다."""
    prompt = _build_system_prompt("Japanese", "Japanese")
    assert "Japanese" in prompt


def test_system_prompt_citation_rules_only_with_textbook():
    """출처 인용 규칙은 교재가 있을 때만 포함."""
    without = _build_system_prompt("Japanese", "Korean", has_textbook=False)
    with_tb = _build_system_prompt("Japanese", "Korean", has_textbook=True)
    assert "SOURCE CITATION" not in without
    assert "SOURCE CITATION" in with_tb


def test_system_prompt_is_subject_agnostic():
    """분야가 프롬프트에 주입되고, 언어학습 전용 문구로 고정되지 않아야 한다."""
    physics = _build_system_prompt("물리학", "Korean")
    assert "물리학" in physics
    # 더 이상 "foreign language learning assistant"로 하드코딩되지 않음
    assert "foreign language learning assistant" not in physics
    # 비언어 분야도 다룰 수 있다는 적응형 지시가 있어야 함
    assert "non-language subjects" in physics


def test_system_prompt_no_student_label():
    """사용자를 'a student'로 지칭하지 않고 직접 대화체로 지칭해야 한다."""
    prompt = _build_system_prompt("물리학", "Korean")
    assert "a student" not in prompt
    assert "helping the user" in prompt
    # 2인칭 직접 지칭 + '학생' 라벨 금지 지시가 명시되어야 함
    assert "ADDRESS THE USER DIRECTLY" in prompt
