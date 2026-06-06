"""pdf_annotations table — PDF 페이지 필기 오버레이 (필기 전용)

Revision ID: b8c9d0e1f2a3
Revises: a7b8c9d0e1f2
Create Date: 2026-06-06 13:00:00.000000

PDF 뷰어 필기 기능(pdf-annotation). 노트 종속(note_id) + PDF 페이지 번호(pdf_page) 키.
note_pages와 동일한 sync 모델이되 페이지 키가 PDF 페이지 번호(1-based)다.
drawing 본문은 기존 content-addressed blob 채널(drawing_hash)로 동기화한다.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "b8c9d0e1f2a3"
down_revision: Union[str, Sequence[str], None] = "a7b8c9d0e1f2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "pdf_annotations",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("note_id", sa.String(), nullable=False),
        sa.Column("pdf_page", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("drawing_hash", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index(
        "ix_pdf_annotations_user_updated", "pdf_annotations", ["user_id", "updated_at"]
    )


def downgrade() -> None:
    op.drop_index("ix_pdf_annotations_user_updated", table_name="pdf_annotations")
    op.drop_table("pdf_annotations")
