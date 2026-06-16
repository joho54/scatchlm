"""피드백 응답 output 상한 회귀 테스트.

1536은 교재 컨텍스트 + 정정 많은 손글씨 같은 긴 케이스에서 응답을 문장 중간에
잘라 저장했다(prod에서 output_tokens=1536 절단 2건 확인). 다시 그 수준으로
내려가면 침묵 절단이 재발하므로 하한을 가드한다.
"""

from app.services.feedback_service import FEEDBACK_MAX_TOKENS


def test_feedback_max_tokens_above_truncation_threshold():
    """절단을 유발했던 1536보다 충분히 커야 한다."""
    assert FEEDBACK_MAX_TOKENS >= 4096


def test_feedback_max_tokens_within_model_limit():
    """sonnet-4-6 단일 응답 한도(64K)를 넘지 않아야 한다."""
    assert FEEDBACK_MAX_TOKENS <= 64000
