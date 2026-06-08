"""textbook_sources.ocr_started_at — 월 OCR 건수 쿼터 기준 시각

Revision ID: a3b4c5d6e7f8
Revises: f2a3b4c5d6e7
Create Date: 2026-06-08 12:00:00.000000

OCR을 *처음* 시작한 시각(최초 1회만 set). 월 건수 쿼터(check_ocr_monthly_quota)가 이번 KST
달력 월에 시작된 스캔본 수를 셀 때의 기준. 재개/재시도는 이 값을 갱신하지 않아 한 파일은
평생 1건만 차지한다(중복 카운트 방지).

기존 행 백필: 이미 시작된(ocr_status가 available/null이 아닌) 스캔본은 그 슬롯을 이미 쓴 것이므로
ocr_updated_at(없으면 created_at)으로 채워, 향후 재개 시 새 슬롯을 소비하거나 재게이트되지 않게 한다.
'available'(미시작)·null은 그대로 둔다 — 다음 명시적 시작에서 쿼터 검사를 받는다.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "a3b4c5d6e7f8"
down_revision: Union[str, Sequence[str], None] = "f2a3b4c5d6e7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "textbook_sources",
        sa.Column("ocr_started_at", sa.DateTime(), nullable=True),
    )
    op.execute(
        "UPDATE textbook_sources "
        "SET ocr_started_at = COALESCE(ocr_updated_at, created_at) "
        "WHERE ocr_status IS NOT NULL AND ocr_status <> 'available'"
    )


def downgrade() -> None:
    op.drop_column("textbook_sources", "ocr_started_at")
