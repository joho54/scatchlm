"""ocr_page_text table and textbook scan/ocr status columns

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-06-05 00:00:00.000000

스캔본(이미지) PDF OCR 지원 (docs/scanned-pdf-ocr-spec.md §4.1-c).
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e5f6a7b8c9d0'
down_revision: Union[str, Sequence[str], None] = 'd4e5f6a7b8c9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        'ocr_page_text',
        sa.Column('id', sa.String(), nullable=False),
        sa.Column('textbook_id', sa.String(), nullable=False),
        sa.Column('page', sa.Integer(), nullable=False),
        sa.Column('content', sa.Text(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['textbook_id'], ['textbook_sources.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('textbook_id', 'page', name='uq_ocr_page_text_textbook_page'),
    )
    op.create_index(op.f('ix_ocr_page_text_textbook_id'), 'ocr_page_text', ['textbook_id'], unique=False)

    op.add_column('textbook_sources', sa.Column('is_scanned', sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column('textbook_sources', sa.Column('ocr_status', sa.String(), nullable=True))
    op.add_column('textbook_sources', sa.Column('ocr_pages_done', sa.Integer(), nullable=False, server_default='0'))
    op.add_column('textbook_sources', sa.Column('ocr_cap', sa.Integer(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column('textbook_sources', 'ocr_cap')
    op.drop_column('textbook_sources', 'ocr_pages_done')
    op.drop_column('textbook_sources', 'ocr_status')
    op.drop_column('textbook_sources', 'is_scanned')
    op.drop_index(op.f('ix_ocr_page_text_textbook_id'), table_name='ocr_page_text')
    op.drop_table('ocr_page_text')
