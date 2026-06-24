"""_clean_keywords 회귀 — feedback/chat structured output의 DMN 인출 단서 정규화.

LLM이 돌려준 keywords를 그대로 신뢰하지 않고: 문자열만 남기고, 공백 정리·중복 제거,
상한을 적용한다. 길이 컷은 두지 않는다(표시=클라이언트 책임). 비-list/비-str은 조용히 버린다.
"""
import pytest

from app.services.feedback_service import _clean_keywords


def test_basic_strip_and_keep_order():
    assert _clean_keywords(["  역전파 ", "베이즈 정리"]) == ["역전파", "베이즈 정리"]


def test_dedupe_preserves_first_occurrence():
    assert _clean_keywords(["역전파", "역전파", "체인룰"]) == ["역전파", "체인룰"]


def test_drops_empty_and_whitespace_only():
    assert _clean_keywords(["", "   ", "경사하강"]) == ["경사하강"]


def test_drops_non_string_items():
    assert _clean_keywords(["개념", 3, None, {"x": 1}, "정리"]) == ["개념", "정리"]


def test_non_list_returns_empty():
    assert _clean_keywords(None) == []
    assert _clean_keywords("역전파") == []
    assert _clean_keywords({"keywords": ["x"]}) == []


def test_respects_limit():
    kws = [f"개념{i}" for i in range(20)]
    assert _clean_keywords(kws, limit=5) == kws[:5]


def test_no_length_cap():
    # 길이 컷은 표시 단 책임 — 긴 개념어도 그대로 보존한다.
    long_kw = "객체지향프로그래밍의캡슐화원칙"
    assert _clean_keywords([long_kw]) == [long_kw]
