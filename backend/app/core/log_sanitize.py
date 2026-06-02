"""로그용 사용자 콘텐츠 마스킹 (Track B-2 / C8).

손글씨 인식 결과·채팅 본문 등 사용자 입력은 PII를 포함할 수 있으므로 로그에는
길이만 남기거나 짧게 클립한다.
"""
from __future__ import annotations


def loglen(text: str | None) -> str:
    """본문 대신 길이만 노출."""
    if not text:
        return "<empty>"
    return f"<{len(text)}chars>"


def clip(text: str | None, n: int = 30) -> str:
    """앞 n자만 노출하고 나머지는 길이로 마스킹."""
    if not text:
        return "<empty>"
    if len(text) <= n:
        return f"{text!r}"
    return f"{text[:n]!r}…(+{len(text) - n})"
