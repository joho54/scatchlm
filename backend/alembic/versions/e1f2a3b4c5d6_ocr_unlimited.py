"""textbook_sources.ocr_unlimited — admin OCR 무제한 플래그

Revision ID: e1f2a3b4c5d6
Revises: d0e1f2a3b4c5
Create Date: 2026-06-06 14:30:00.000000

admin(JWT role=admin) 업로드 스캔본은 페이지 캡·OCR 예산을 무제한으로 처리한다.
role은 DB에 없어 업로드 시점에 이 플래그로 영속화 → 백그라운드 OCR 잡/스위퍼가
JWT 없이도 admin 무제한을 판별한다. 기존 행은 server_default=false로 자연 호환.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "e1f2a3b4c5d6"
down_revision: Union[str, Sequence[str], None] = "d0e1f2a3b4c5"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "textbook_sources",
        sa.Column("ocr_unlimited", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    op.drop_column("textbook_sources", "ocr_unlimited")
