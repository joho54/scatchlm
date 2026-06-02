"""estimate_cost_from_usage 회귀 — prompt caching(§11 L2) 단가 반영.

cache_read = 0.1×, cache_creation = 1.25×, 일반 input = 1×, output = 정가.
캐시 미사용(필드 0/없음)이면 estimate_cost와 동일해야 한다.
"""
from types import SimpleNamespace

from app.services.feedback_service import estimate_cost, estimate_cost_from_usage

SONNET = "claude-sonnet-4-6"  # input $3/1M, output $15/1M


def test_no_cache_matches_plain_estimate():
    usage = SimpleNamespace(input_tokens=2500, output_tokens=600,
                            cache_read_input_tokens=0, cache_creation_input_tokens=0)
    assert estimate_cost_from_usage(SONNET, usage) == estimate_cost(SONNET, 2500, 600)


def test_missing_cache_fields_default_to_zero():
    # 캐시 필드가 아예 없는 usage(캐싱 미적용 응답)도 안전하게 동작.
    usage = SimpleNamespace(input_tokens=1000, output_tokens=100)
    assert estimate_cost_from_usage(SONNET, usage) == estimate_cost(SONNET, 1000, 100)


def test_cache_read_billed_at_one_tenth():
    # 1,000,000 cache_read 토큰 = $3 × 0.1 = $0.30
    usage = SimpleNamespace(input_tokens=0, output_tokens=0,
                            cache_read_input_tokens=1_000_000, cache_creation_input_tokens=0)
    assert abs(estimate_cost_from_usage(SONNET, usage) - 0.30) < 1e-9


def test_cache_write_billed_at_1_25x():
    # 1,000,000 cache_creation 토큰 = $3 × 1.25 = $3.75
    usage = SimpleNamespace(input_tokens=0, output_tokens=0,
                            cache_read_input_tokens=0, cache_creation_input_tokens=1_000_000)
    assert abs(estimate_cost_from_usage(SONNET, usage) - 3.75) < 1e-9


def test_combined():
    # input 1M($3) + read 1M($0.3) + write 1M($3.75) + output 1M($15) = $22.05
    usage = SimpleNamespace(input_tokens=1_000_000, output_tokens=1_000_000,
                            cache_read_input_tokens=1_000_000, cache_creation_input_tokens=1_000_000)
    assert abs(estimate_cost_from_usage(SONNET, usage) - 22.05) < 1e-9
