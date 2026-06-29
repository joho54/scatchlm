"""PostgreSQL 텍스트 컬럼에 안전하지 않은 바이트 제거.

PostgreSQL의 text/varchar(UTF8)는 NUL 바이트(0x00)를 저장하지 못한다 —
INSERT 시 asyncpg.CharacterNotInRepertoireError로 트랜잭션이 통째로 깨진다.
PyMuPDF `get_text()`로 추출한 PDF 텍스트나, 그 텍스트를 컨텍스트로 받은 LLM이
그대로 echo한 응답 본문에 0x00이 섞여 들어올 수 있으므로, DB에 적재하기 직전의
모든 LLM/PDF 유래 문자열은 이 함수를 거친다.
"""
from __future__ import annotations


def pg_safe(text: str | None) -> str | None:
    """PostgreSQL이 거부하는 NUL 바이트(0x00)를 제거한다. None은 그대로 통과."""
    if text is None:
        return None
    return text.replace("\x00", "")
