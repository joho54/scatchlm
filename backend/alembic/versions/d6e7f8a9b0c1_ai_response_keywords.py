"""ai_response.keywords — DMN 휴식 타이머 인출 단서

Revision ID: d6e7f8a9b0c1
Revises: c5d6e7f8a9b0
Create Date: 2026-06-24 12:00:00.000000

feedback/chat 응답의 structured output이 함께 뱉는 핵심 개념어(인출 단서). DMN 휴식 타이머가
노트 scope로 최근 응답에서 모아 표시한다. 볼드 휴리스틱(WordExtractor) 대체 — 단서 추출을
LLM 포맷팅(볼드)에서 디커플링한다. 기존 행은 빈 배열(백필 불가 — 원본 컨텍스트 없음).
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import ARRAY


revision: str = "d6e7f8a9b0c1"
down_revision: Union[str, Sequence[str], None] = "c5d6e7f8a9b0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "ai_response",
        sa.Column(
            "keywords",
            ARRAY(sa.String()),
            nullable=False,
            server_default="{}",
        ),
    )


def downgrade() -> None:
    op.drop_column("ai_response", "keywords")
