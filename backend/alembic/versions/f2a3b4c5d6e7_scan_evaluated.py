"""textbook_sources.scan_evaluated — is_scanned 평가 완료 마커

Revision ID: f2a3b4c5d6e7
Revises: e1f2a3b4c5d6
Create Date: 2026-06-06 15:30:00.000000

"현재 규칙으로 is_scanned를 평가했나" 마커. upload는 무조건 평가하므로 true로 저장,
재사용/노트 생성(intake)은 false면 1회 재평가 후 set → 파일 재오픈을 textbook당 평생 1회로 바운드.

기존 행: is_scanned=true(이미 스캔본으로 옳게 평가됨)는 scan_evaluated=true로 둔다(재평가 불필요).
is_scanned=false(게이팅 시절 stale 가능)만 false로 남겨 다음 intake에서 1회 재평가되게 한다.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "f2a3b4c5d6e7"
down_revision: Union[str, Sequence[str], None] = "e1f2a3b4c5d6"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "textbook_sources",
        sa.Column("scan_evaluated", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    # is_scanned=true는 이미 올바르게 평가됨 → 재평가 면제. is_scanned=false만 false로 남김.
    op.execute("UPDATE textbook_sources SET scan_evaluated = true WHERE is_scanned = true")


def downgrade() -> None:
    op.drop_column("textbook_sources", "scan_evaluated")
