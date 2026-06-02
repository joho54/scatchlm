"""DB 불필요 순수 로직 테스트 — quota 경계 계산, tier/role 추출, 에러 분류 (Track B)."""
from datetime import datetime, timezone

import anthropic
import pytest

from app.core.auth import get_role, get_tier
from app.core.quota import KST, _kst_day_bounds, _limit_for_tier
from app.services.feedback_service import classify_anthropic_error


def test_kst_day_bounds_resets_at_kst_midnight():
    # 2026-06-02 15:30 UTC == 2026-06-03 00:30 KST → 오늘(KST) 자정은 06-03 00:00 KST
    now = datetime(2026, 6, 2, 15, 30, tzinfo=timezone.utc)
    since, next_midnight = _kst_day_bounds(now)
    # next midnight은 KST 06-04 00:00
    assert next_midnight.tzinfo == KST
    assert (next_midnight.year, next_midnight.month, next_midnight.day) == (2026, 6, 4)
    assert next_midnight.hour == 0
    # since(UTC naive)는 06-02 15:00 UTC (= 06-03 00:00 KST)
    assert since.tzinfo is None
    assert (since.month, since.day, since.hour) == (6, 2, 15)


def test_limit_for_tier(monkeypatch):
    from app.core import quota
    monkeypatch.setattr(quota.settings, "DAILY_COST_LIMIT_NORMAL_USD", 1.0)
    monkeypatch.setattr(quota.settings, "DAILY_COST_LIMIT_PRO_USD", 5.0)
    assert _limit_for_tier("normal") == 1.0
    assert _limit_for_tier("pro") == 5.0
    assert _limit_for_tier("unknown") == 1.0  # fallback to normal


def test_get_tier_and_role():
    assert get_tier({"app_metadata": {"tier": "pro"}}) == "pro"
    assert get_tier({"app_metadata": {"tier": "weird"}}) == "normal"
    assert get_tier({}) == "normal"
    assert get_role({"app_metadata": {"role": "admin"}}) == "admin"
    assert get_role({"app_metadata": {}}) is None
    assert get_role({}) is None


def test_classify_anthropic_error():
    rate = anthropic.RateLimitError.__new__(anthropic.RateLimitError)
    assert classify_anthropic_error(rate) == "rate_limit_429"
    assert classify_anthropic_error(ValueError("x")) == "unknown"
