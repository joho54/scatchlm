"""llm_usage.billable — 일일 비용 quota 차감 대상 플래그

Revision ID: c5d6e7f8a9b0
Revises: b4c5d6e7f8a9
Create Date: 2026-06-23 12:00:00.000000

모든 LLM 호출을 llm_usage에 기록하되, 일일 비용 quota(quota.py)엔 정책상 일부만 차감한다.
billable=False면 기록은 하되 한도 합산에서 제외 — chapter_detect(업로드 자동), recognition·
query_rewrite(피드백 하위 단계), ocr(자체 월 파일수 + 일일 백스톱 트랙)이 면제 대상.
기존 행은 모두 차감 대상이던 feedback/chat/ocr이라 True로 백필(server_default="true").
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "c5d6e7f8a9b0"
down_revision: Union[str, Sequence[str], None] = "b4c5d6e7f8a9"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "llm_usage",
        sa.Column(
            "billable",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("true"),
        ),
    )


def downgrade() -> None:
    op.drop_column("llm_usage", "billable")
