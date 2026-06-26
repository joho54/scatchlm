"""textbook_sources.deleted_at — 서재 soft delete

Revision ID: f3a4b5c6d7e8
Revises: e7f8a9b0c1d2
Create Date: 2026-06-26 12:00:00.000000

서재 목록에서 교재를 숨기되 노트 연결·가이드/챕터/OCR 캐시·PDF 파일은 보존(복구 가능).
deleted_at IS NULL을 거르는 건 목록(list_textbooks)과 서재 제안(discover) 집계뿐 —
id 직접 접근(파일/챕터/가이드/피드백 컨텍스트/ensure)은 삭제돼도 허용한다.
기존 행은 모두 NULL(미삭제)로 들어간다.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "f3a4b5c6d7e8"
down_revision: Union[str, Sequence[str], None] = "e7f8a9b0c1d2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "textbook_sources",
        sa.Column("deleted_at", sa.DateTime(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("textbook_sources", "deleted_at")
