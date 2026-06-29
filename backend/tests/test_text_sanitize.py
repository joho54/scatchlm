"""NUL(0x00) 제거 회귀 — Postgres UTF8 컬럼은 0x00을 거부해 INSERT가 500으로 깨진다.

운영 사고: PyMuPDF로 추출한 교재 텍스트가 prompt_context_snippet으로 적재되며
asyncpg.CharacterNotInRepertoireError("invalid byte sequence for encoding UTF8: 0x00")
로 POST /api/feedback/chat 이 전부 500을 냈다.
"""
from app.core.text_sanitize import pg_safe


def test_pg_safe_strips_nul():
    assert pg_safe("a\x00b\x00c") == "abc"


def test_pg_safe_preserves_normal_text():
    s = "연습문제 — BSC f=0.2\n$P(y=1\\mid x=1)$ 🙂"
    assert pg_safe(s) == s


def test_pg_safe_none_passthrough():
    assert pg_safe(None) is None


def test_pg_safe_empty():
    assert pg_safe("") == ""
