"""add app_logs table

Revision ID: d4e5f6a7b8c9
Revises: 588f1d04cd22
Create Date: 2026-06-04 00:00:00.000000

FE 텔레메트리 영속 적재 (data-durability-spec §B.3).
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


# revision identifiers, used by Alembic.
revision: str = 'd4e5f6a7b8c9'
down_revision: Union[str, Sequence[str], None] = '588f1d04cd22'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        'app_logs',
        sa.Column('id', sa.String(), nullable=False),
        sa.Column('ts', sa.DateTime(), nullable=False),
        sa.Column('received_at', sa.DateTime(), nullable=False),
        sa.Column('level', sa.String(), nullable=False),
        sa.Column('tag', sa.String(), nullable=False),
        sa.Column('message', sa.Text(), nullable=False),
        sa.Column('data', postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column('user_id', sa.String(), nullable=True),
        sa.Column('session_id', sa.String(), nullable=True),
        sa.Column('trace_id', sa.String(), nullable=True),
        sa.Column('request_id', sa.String(), nullable=True),
        sa.Column('app_version', sa.String(), nullable=True),
        sa.Column('build', sa.String(), nullable=True),
        sa.Column('os_version', sa.String(), nullable=True),
        sa.Column('device_model', sa.String(), nullable=True),
        sa.Column('locale', sa.String(), nullable=True),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_app_logs_ts'), 'app_logs', ['ts'], unique=False)
    op.create_index(op.f('ix_app_logs_tag'), 'app_logs', ['tag'], unique=False)
    op.create_index(op.f('ix_app_logs_user_id'), 'app_logs', ['user_id'], unique=False)
    op.create_index(op.f('ix_app_logs_session_id'), 'app_logs', ['session_id'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f('ix_app_logs_session_id'), table_name='app_logs')
    op.drop_index(op.f('ix_app_logs_user_id'), table_name='app_logs')
    op.drop_index(op.f('ix_app_logs_tag'), table_name='app_logs')
    op.drop_index(op.f('ix_app_logs_ts'), table_name='app_logs')
    op.drop_table('app_logs')
