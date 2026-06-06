"""folders table + notes.folder_id — 노트 폴더 정리 (note-folders-spec)

Revision ID: c9d0e1f2a3b4
Revises: b8c9d0e1f2a3
Create Date: 2026-06-06 14:00:00.000000

플랫(단일 레벨) 폴더로 노트를 정리한다. 기존 sync 인프라 재사용 — folders는
notes/note_pages/…와 동일한 (user_id, updated_at) 인덱스·soft delete 패턴.
note.folder_id는 폴더를 가리키는 단순 컬럼(FK 강제 안 함, NULL=미분류).
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "c9d0e1f2a3b4"
down_revision: Union[str, Sequence[str], None] = "b8c9d0e1f2a3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "folders",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("name", sa.String(), nullable=False, server_default=""),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index("ix_folders_user_updated", "folders", ["user_id", "updated_at"])
    op.add_column("notes", sa.Column("folder_id", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("notes", "folder_id")
    op.drop_index("ix_folders_user_updated", table_name="folders")
    op.drop_table("folders")
