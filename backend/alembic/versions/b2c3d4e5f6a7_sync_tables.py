"""create sync tables: notes, note_pages, feedbacks, chat_messages

Revision ID: b2c3d4e5f6a7
Revises: a1b2c3d4e5f6
Create Date: 2026-06-01 12:00:00.000000

cloud-data-sync-spec A-2. 델타 동기화 대상 4개 테이블 생성 + (user_id, updated_at) 인덱스.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "b2c3d4e5f6a7"
down_revision: Union[str, Sequence[str], None] = "a1b2c3d4e5f6"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "notes",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("title", sa.String(), nullable=False, server_default=""),
        sa.Column("language", sa.String(), nullable=False, server_default="en"),
        sa.Column("textbook_id", sa.String(), nullable=True),
        sa.Column("textbook_name", sa.String(), nullable=True),
        sa.Column("textbook_pages", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_page", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("pdf_open", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("current_page_index", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("drawing_hash", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index("ix_notes_user_updated", "notes", ["user_id", "updated_at"])

    op.create_table(
        "note_pages",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("note_id", sa.String(), nullable=False),
        sa.Column("page_index", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("drawing_hash", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index("ix_note_pages_user_updated", "note_pages", ["user_id", "updated_at"])

    op.create_table(
        "feedbacks",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("note_id", sa.String(), nullable=False),
        sa.Column("page_id", sa.String(), nullable=True),
        sa.Column("content", sa.Text(), nullable=False, server_default=""),
        sa.Column("position_x", sa.Double(), nullable=False, server_default="0"),
        sa.Column("position_y", sa.Double(), nullable=False, server_default="0"),
        sa.Column("bbox_x", sa.Double(), nullable=False, server_default="0"),
        sa.Column("bbox_y", sa.Double(), nullable=False, server_default="0"),
        sa.Column("bbox_width", sa.Double(), nullable=False, server_default="0"),
        sa.Column("bbox_height", sa.Double(), nullable=False, server_default="0"),
        sa.Column("stroke_range_start", sa.Integer(), nullable=True),
        sa.Column("stroke_range_end", sa.Integer(), nullable=True),
        sa.Column("server_feedback_id", sa.String(), nullable=True),
        sa.Column("user_rating", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index("ix_feedbacks_user_updated", "feedbacks", ["user_id", "updated_at"])

    op.create_table(
        "chat_messages",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("feedback_id", sa.String(), nullable=False),
        sa.Column("role", sa.String(), nullable=False, server_default="user"),
        sa.Column("content", sa.Text(), nullable=False, server_default=""),
        sa.Column("server_message_id", sa.String(), nullable=True),
        sa.Column("user_rating", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index("ix_chat_messages_user_updated", "chat_messages", ["user_id", "updated_at"])


def downgrade() -> None:
    op.drop_index("ix_chat_messages_user_updated", table_name="chat_messages")
    op.drop_table("chat_messages")
    op.drop_index("ix_feedbacks_user_updated", table_name="feedbacks")
    op.drop_table("feedbacks")
    op.drop_index("ix_note_pages_user_updated", table_name="note_pages")
    op.drop_table("note_pages")
    op.drop_index("ix_notes_user_updated", table_name="notes")
    op.drop_table("notes")
