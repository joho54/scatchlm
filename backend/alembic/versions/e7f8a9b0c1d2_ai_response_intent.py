"""ai_response.intent — 피드백 의도(grade/ask/hint)

Revision ID: e7f8a9b0c1d2
Revises: d6e7f8a9b0c1
Create Date: 2026-06-25 12:00:00.000000

손글씨 피드백의 인지 연산 의도. 같은 이미지라도 채점(grade)·질문(ask)·힌트(hint) 중
무엇을 시켰는지 기록한다. 손글씨 피드백에만 의미가 있어 nullable — chat/guide는 NULL.
기존 행은 NULL(백필 불가 — 의도 미기록). 어떤 의도가 실제로 쓰이는지 분석 backbone.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "e7f8a9b0c1d2"
down_revision: Union[str, Sequence[str], None] = "d6e7f8a9b0c1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("ai_response", sa.Column("intent", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("ai_response", "intent")
