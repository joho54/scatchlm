"""피드백 프롬프트 회귀 테스트 — JSON 지시 재유입 방지 + 분야 범용화."""

from app.core.constants import DEFAULT_SUBJECT
from app.services.feedback_service import (
    _build_system_prompt,
    _normalize_intent,
    source_citation_rules,
    _INTENT_USER_INSTRUCTION,
    DEFAULT_INTENT,
    VALID_INTENTS,
)


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


def test_system_prompt_empty_subject_is_neutral():
    """주제가 비면(즉시 생성 노트 등) 분야 중립 튜터로 동작해야 한다."""
    for empty in ("", "   "):
        prompt = _build_system_prompt(empty, "Korean")
        # 빈 subject가 프롬프트에 그대로 박혀 'learn .' 같은 비문이 되면 안 됨
        assert "learn their study material" in prompt
        assert "helping the user learn ." not in prompt


def test_system_prompt_nonempty_subject_unchanged():
    """주제가 있으면 그대로 주입되고 중립 문구는 쓰이지 않아야 한다."""
    prompt = _build_system_prompt("Japanese", "Korean")
    assert "learn Japanese" in prompt
    assert "their study material" not in prompt


def test_default_subject_is_field_neutral():
    """주제 기본값(SSOT)은 분야 중립이어야 한다 — 과거 "en"으로 회귀 방지.

    DEFAULT_SUBJECT가 "en" 등 구체 값으로 돌아가면 주제 누락 요청이 'learn en'으로
    오염되고 OCR에 'Subject: en.'이 주입되던 버그가 재발한다.
    """
    assert DEFAULT_SUBJECT.strip() == ""
    prompt = _build_system_prompt(DEFAULT_SUBJECT, "Korean")
    assert "learn their study material" in prompt
    assert "learn en" not in prompt


# --- 의도 분기 (grade/ask/hint) ---

def test_default_intent_is_grade():
    """intent 미지정 = 채점(grade). 구버전 클라이언트 동작 유지(BC)."""
    assert DEFAULT_INTENT == "grade"
    default = _build_system_prompt("물리학", "Korean")
    grade = _build_system_prompt("물리학", "Korean", intent="grade")
    assert default == grade


def test_grade_intent_frames_as_evaluation():
    """채점 의도: 필기를 답안으로 보고 평가하는 지시가 있어야 한다."""
    prompt = _build_system_prompt("Latin", "Korean", intent="grade")
    assert "GRADE it" in prompt
    assert "what is correct and what needs fixing" in prompt


def test_ask_intent_does_not_grade():
    """질문 의도: 채점하지 말고 답하라는 지시. '미완성 답안으로 채점' 버그의 회귀 가드."""
    prompt = _build_system_prompt("Latin", "Korean", intent="ask")
    assert "NOT an answer to be graded" in prompt
    assert "Do NOT score it" in prompt
    # 채점 전용 문구가 새지 않아야 함
    assert "GRADE it" not in prompt


def test_hint_intent_withholds_answer():
    """힌트 의도: 정답을 공개하지 말고 한 걸음만 밀어주라는 지시."""
    prompt = _build_system_prompt("Latin", "Korean", intent="hint")
    assert "Do NOT reveal the final answer" in prompt
    assert "GRADE it" not in prompt


def test_invalid_intent_falls_back_to_grade():
    """알 수 없는 intent는 채점으로 정규화 — 깨진/구버전 값에도 안전."""
    assert _normalize_intent("bogus") == "grade"
    assert _normalize_intent(None) == "grade"
    assert _normalize_intent("ask") == "ask"
    bogus = _build_system_prompt("Latin", "Korean", intent="bogus")
    grade = _build_system_prompt("Latin", "Korean", intent="grade")
    assert bogus == grade


def test_all_intents_have_user_instruction():
    """모든 유효 의도가 user 턴 마지막 지시 문구를 가져야 한다(KeyError 방지)."""
    for intent in VALID_INTENTS:
        assert intent in _INTENT_USER_INSTRUCTION
        assert _INTENT_USER_INSTRUCTION[intent].strip()
    # 의도별로 실제 다른 지시여야 함 — 분기가 무의미해지지 않게.
    assert len({_INTENT_USER_INSTRUCTION[i] for i in VALID_INTENTS}) == len(VALID_INTENTS)


def test_intent_branches_are_subject_agnostic():
    """모든 의도 분기에서 주제가 주입되고 JSON 지시가 없어야 한다(공통 불변식)."""
    for intent in VALID_INTENTS:
        prompt = _build_system_prompt("Japanese", "Korean", intent=intent)
        assert "Japanese" in prompt
        assert "JSON" not in prompt and "json" not in prompt


# --- 출처/인용 커널 (피드백·채팅 공유) + 교재외 badge 제거 회귀 가드 ---

def test_citation_kernel_positive_claim_groundable():
    """공유 인용 커널: 본문에 있는 것 → [p.X] 인용. 양의 주장만 groundable이라 유지."""
    rules = source_citation_rules()
    assert len(rules) == 2
    assert "[p.33]" in rules[0]


def test_citation_kernel_forbids_external_badge_emission():
    """커널은 '교재 외' 음의 주장을 금지만 하고 발화 지시는 없어야 한다.

    챕터만 주입된 상태에선 '다른 챕터 교재 내용'과 '교재 밖 일반지식'을 구분할 수 없어
    교재 외 단정은 부당하다. 과거의 'mark it as: 📖 교재 외 참고' 발화 지시 회귀를 막는다.
    """
    joined = " ".join(source_citation_rules())
    assert "do NOT assert its provenance" in joined  # 금지 지시 존재
    assert "교재 외 참고" in joined                    # 라벨 금지 언급
    assert "mark it as" not in joined                  # 발화 지시 부재


def test_feedback_prompt_uses_shared_citation_kernel():
    """피드백 프롬프트가 공유 커널 절을 그대로 포함해야 한다(두 프롬프트 drift 가드)."""
    prompt = _build_system_prompt("Latin", "Korean", has_textbook=True)
    for clause in source_citation_rules():
        assert clause in prompt


def test_feedback_prompt_no_external_badge_emission():
    """피드백 프롬프트가 교재 외 badge를 붙이라고 지시하지 않아야 한다(회귀 가드)."""
    prompt = _build_system_prompt("Latin", "Korean", has_textbook=True)
    assert "[p.33]" in prompt           # 양의 주장 유지
    assert "mark it as" not in prompt   # 발화 지시 제거됨
