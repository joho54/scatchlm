"""DB 불필요 순수 로직 테스트 — quota 경계 계산, tier/role 추출, 에러 분류 (Track B)."""
from datetime import datetime, timezone
from unittest.mock import AsyncMock

import anthropic
import pytest

from app.core.auth import get_role, get_tier
from app.core.quota import KST, _kst_day_bounds, _limit_for_tier, check_daily_quota
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


async def test_quota_acquires_per_user_advisory_lock(monkeypatch):
    """동시 요청 race 방지용 per-user advisory lock이 발급되는지 (regression).

    이 lock이 제거되면 동시 요청이 stale 합계를 함께 읽고 한도를 우회한다.
    """
    from app.core import quota

    monkeypatch.setattr(quota.settings, "DAILY_COST_LIMIT_NORMAL_USD", 1.0)

    db = AsyncMock()
    db.execute = AsyncMock()
    db.scalar = AsyncMock(return_value=0.0)  # used=0 < limit → 통과

    await check_daily_quota("u1", "normal", db)

    db.execute.assert_awaited_once()
    sql = str(db.execute.await_args.args[0])
    assert "pg_advisory_xact_lock" in sql


async def test_quota_unlimited_tier_skips_lock(monkeypatch):
    """한도 0(무제한)이면 lock·집계 쿼리 모두 생략(오버헤드 회피)."""
    from app.core import quota

    monkeypatch.setattr(quota.settings, "DAILY_COST_LIMIT_NORMAL_USD", 0.0)

    db = AsyncMock()
    db.execute = AsyncMock()
    db.scalar = AsyncMock(return_value=0.0)

    await check_daily_quota("u1", "normal", db)

    db.execute.assert_not_awaited()
    db.scalar.assert_not_awaited()


async def test_quota_admin_unlimited(monkeypatch):
    """admin(is_admin=True)은 한도가 설정·초과돼 있어도 무제한 — lock·집계 생략, 429 없음."""
    from app.core import quota

    monkeypatch.setattr(quota.settings, "DAILY_COST_LIMIT_NORMAL_USD", 1.0)  # 한도 있음

    db = AsyncMock()
    db.execute = AsyncMock()
    db.scalar = AsyncMock(return_value=999.0)  # 한도 초과 상태여도

    await check_daily_quota("admin-user", "normal", db, is_admin=True)  # 예외 없이 통과

    db.execute.assert_not_awaited()
    db.scalar.assert_not_awaited()
