"""가이드 프롬프트 회귀 테스트 — 분야 범용화 + 챕터 JSON 키명 보존."""

from app.services.guide_service import _page_guide_prompt, _chapter_guide_prompt


def test_page_guide_is_subject_agnostic():
    """페이지 가이드가 English/외국어 학습 전용으로 고정되지 않아야 한다."""
    prompt = _page_guide_prompt("Korean")
    assert "Korean" in prompt
    assert "English textbook" not in prompt
    assert "non-English speaker" not in prompt


def test_page_guide_contains_response_language():
    prompt = _page_guide_prompt("Japanese")
    assert "Japanese" in prompt


def test_chapter_guide_preserves_json_keys():
    """챕터 가이드 JSON 키명은 iOS/DB 파싱과 직결 — 절대 변경 금지."""
    prompt = _chapter_guide_prompt("Korean")
    for key in ("topic", "key_concepts", "study_order", "common_mistakes", "summary"):
        assert f'"{key}"' in prompt


def test_chapter_guide_is_subject_agnostic():
    """챕터 가이드가 grammar/vocab 등 언어학습 전용 표현으로 고정되지 않아야 한다."""
    prompt = _chapter_guide_prompt("Korean")
    assert "Korean" in prompt
    assert "language learning tutor" not in prompt
    assert "grammar/vocab" not in prompt
