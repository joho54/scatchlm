"""chat_sessions table + session_id on feedbacks/chat_messages

Revision ID: a7b8c9d0e1f2
Revises: e5f6a7b8c9d0
Create Date: 2026-06-06 12:00:00.000000

chapter-chat-drawer-spec §3.2-a / Track F. 캔버스 비종속 chat_session 테이블 신설 +
feedbacks/chat_messages에 session_id 추가. 기존 chat_messages를 feedback_id로 그룹핑해
kind=feedback 세션으로 백필한다(세션 id = 'sess_'+feedback_id, 결정적 — 클라 백필과 머지, §7 R1).
chat_messages.feedback_id는 nullable로 완화(레거시 유지, R3).
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "a7b8c9d0e1f2"
down_revision: Union[str, Sequence[str], None] = "e5f6a7b8c9d0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "chat_sessions",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("kind", sa.String(), nullable=False, server_default="feedback"),
        sa.Column("title", sa.Text(), nullable=False, server_default=""),
        sa.Column("note_id", sa.String(), nullable=True),
        sa.Column("textbook_id", sa.String(), nullable=True),
        sa.Column("anchor_page", sa.Integer(), nullable=True),
        sa.Column("chapter_title", sa.String(), nullable=True),
        sa.Column("source_feedback_id", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index("ix_chat_sessions_user_updated", "chat_sessions", ["user_id", "updated_at"])

    # session_id 컬럼 추가
    op.add_column("feedbacks", sa.Column("session_id", sa.String(), nullable=True))
    op.add_column(
        "chat_messages",
        sa.Column("session_id", sa.String(), nullable=False, server_default=""),
    )
    # 레거시 FK 완화 (마이그레이션 후 null 가능)
    op.alter_column("chat_messages", "feedback_id", existing_type=sa.String(), nullable=True)

    # 백필: chat_messages를 feedback_id로 그룹핑 → kind=feedback 세션 1개씩.
    # 세션 id는 결정적('sess_'+feedback_id)이라 클라 백필과 충돌 없이 머지된다(R1).
    op.execute(
        """
        INSERT INTO chat_sessions
            (id, user_id, kind, title, note_id, textbook_id, anchor_page,
             chapter_title, source_feedback_id, created_at, updated_at, deleted)
        SELECT 'sess_' || f.id,
               f.user_id,
               'feedback',
               COALESCE(
                   (SELECT c2.content FROM chat_messages c2
                    WHERE c2.feedback_id = f.id AND c2.role = 'user'
                    ORDER BY c2.created_at ASC LIMIT 1),
                   '피드백 대화'),
               f.note_id, NULL, NULL, NULL, f.server_feedback_id,
               f.created_at, f.created_at, false
        FROM feedbacks f
        WHERE f.id IN (SELECT DISTINCT feedback_id FROM chat_messages WHERE feedback_id IS NOT NULL)
        ON CONFLICT (id) DO NOTHING
        """
    )
    op.execute(
        "UPDATE chat_messages SET session_id = 'sess_' || feedback_id "
        "WHERE feedback_id IS NOT NULL AND (session_id IS NULL OR session_id = '')"
    )
    op.execute(
        "UPDATE feedbacks SET session_id = 'sess_' || id "
        "WHERE id IN (SELECT DISTINCT feedback_id FROM chat_messages WHERE feedback_id IS NOT NULL)"
    )


def downgrade() -> None:
    op.alter_column("chat_messages", "feedback_id", existing_type=sa.String(), nullable=False)
    op.drop_column("chat_messages", "session_id")
    op.drop_column("feedbacks", "session_id")
    op.drop_index("ix_chat_sessions_user_updated", table_name="chat_sessions")
    op.drop_table("chat_sessions")
