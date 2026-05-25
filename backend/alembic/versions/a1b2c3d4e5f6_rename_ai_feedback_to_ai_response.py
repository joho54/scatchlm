"""rename ai_feedback_record/rating to ai_response, add page_guides.ai_response_id

Revision ID: a1b2c3d4e5f6
Revises: f4b4ab3c2bae
Create Date: 2026-05-25 14:30:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "a1b2c3d4e5f6"
down_revision: Union[str, Sequence[str], None] = "f4b4ab3c2bae"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1) ai_feedback_record → ai_response
    op.rename_table("ai_feedback_record", "ai_response")
    op.execute("ALTER INDEX ix_ai_feedback_record_user_id RENAME TO ix_ai_response_user_id")
    op.execute("ALTER INDEX ix_ai_feedback_record_note_id RENAME TO ix_ai_response_note_id")
    # note_id를 nullable로 (가이드 응답 등 note 없는 응답 허용)
    op.alter_column("ai_response", "note_id", existing_type=sa.String(), nullable=True)

    # 2) ai_feedback_rating → ai_response_rating, feedback_id → response_id
    op.rename_table("ai_feedback_rating", "ai_response_rating")
    op.alter_column("ai_response_rating", "feedback_id", new_column_name="response_id")
    op.execute("ALTER INDEX ix_ai_feedback_rating_user_id RENAME TO ix_ai_response_rating_user_id")
    op.execute("ALTER INDEX ix_ai_feedback_rating_feedback_id RENAME TO ix_ai_response_rating_response_id")
    # FK 재생성 (Postgres는 rename_table 시 FK 이름이 자동 갱신되지 않을 수 있음)
    op.execute("ALTER TABLE ai_response_rating DROP CONSTRAINT IF EXISTS ai_feedback_rating_feedback_id_fkey")
    op.create_foreign_key(
        "ai_response_rating_response_id_fkey",
        "ai_response_rating",
        "ai_response",
        ["response_id"],
        ["id"],
        ondelete="CASCADE",
    )

    # 3) page_guides.ai_response_id 추가
    op.add_column(
        "page_guides",
        sa.Column("ai_response_id", sa.String(), nullable=True),
    )
    op.create_foreign_key(
        "page_guides_ai_response_id_fkey",
        "page_guides",
        "ai_response",
        ["ai_response_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint("page_guides_ai_response_id_fkey", "page_guides", type_="foreignkey")
    op.drop_column("page_guides", "ai_response_id")

    op.drop_constraint("ai_response_rating_response_id_fkey", "ai_response_rating", type_="foreignkey")
    op.execute("ALTER INDEX ix_ai_response_rating_response_id RENAME TO ix_ai_feedback_rating_feedback_id")
    op.execute("ALTER INDEX ix_ai_response_rating_user_id RENAME TO ix_ai_feedback_rating_user_id")
    op.alter_column("ai_response_rating", "response_id", new_column_name="feedback_id")
    op.rename_table("ai_response_rating", "ai_feedback_rating")
    op.create_foreign_key(
        "ai_feedback_rating_feedback_id_fkey",
        "ai_feedback_rating",
        "ai_feedback_record",
        ["feedback_id"],
        ["id"],
        ondelete="CASCADE",
    )

    op.alter_column("ai_response", "note_id", existing_type=sa.String(), nullable=False)
    op.execute("ALTER INDEX ix_ai_response_note_id RENAME TO ix_ai_feedback_record_note_id")
    op.execute("ALTER INDEX ix_ai_response_user_id RENAME TO ix_ai_feedback_record_user_id")
    op.rename_table("ai_response", "ai_feedback_record")
