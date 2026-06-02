"""page_guides: add response_language to cache key (Track H)

기존 행은 출시 전이라 폐기 가능(§6.x-8) → 마이그레이션에서 page_guides를 비우고
response_language(NOT NULL) 컬럼 추가, uq_page_guide를 (textbook_id, page, response_language)로 변경.

Revision ID: c3d4e5f6a7b8
Revises: b2c3d4e5f6a7
Create Date: 2026-06-02
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "c3d4e5f6a7b8"
down_revision: Union[str, Sequence[str], None] = "b2c3d4e5f6a7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 기존 가이드 캐시 폐기 (언어 차원 누락분 — 출시 전이라 백필 불필요)
    op.execute("DELETE FROM page_guides")

    # 기존 유니크 제약 제거 후 컬럼 추가
    op.drop_constraint("uq_page_guide", "page_guides", type_="unique")
    op.add_column(
        "page_guides",
        sa.Column("response_language", sa.String(), nullable=False, server_default="Korean"),
    )
    op.create_unique_constraint(
        "uq_page_guide", "page_guides", ["textbook_id", "page", "response_language"]
    )
    # server_default는 마이그레이션 편의용 — 이후 애플리케이션이 항상 값을 지정.
    op.alter_column("page_guides", "response_language", server_default=None)


def downgrade() -> None:
    op.drop_constraint("uq_page_guide", "page_guides", type_="unique")
    op.drop_column("page_guides", "response_language")
    op.create_unique_constraint("uq_page_guide", "page_guides", ["textbook_id", "page"])
