"""notes.template — 캔버스 배경 템플릿 (canvas-template)

Revision ID: d0e1f2a3b4c5
Revises: c9d0e1f2a3b4
Create Date: 2026-06-06 16:00:00.000000

노트 단위 캔버스 배경 템플릿(NoteTemplate.rawValue: blank/lined/grid/staff).
기존 노트는 server_default="blank"로 자연 호환. sync는 folder_id 패턴과 동일하게
ENTITY_FIELDS["notes"]에 컬럼만 추가하면 push/pull 자동 처리된다.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "d0e1f2a3b4c5"
down_revision: Union[str, Sequence[str], None] = "c9d0e1f2a3b4"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "notes",
        sa.Column("template", sa.String(), nullable=False, server_default="blank"),
    )


def downgrade() -> None:
    op.drop_column("notes", "template")
