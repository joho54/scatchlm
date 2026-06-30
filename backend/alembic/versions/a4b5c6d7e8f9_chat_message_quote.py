"""chat_messages.quote — 라이브 '선택 질문' 인용 구절 영속화/동기화

Revision ID: a4b5c6d7e8f9
Revises: f3a4b5c6d7e8
Create Date: 2026-06-30 12:00:00.000000

iOS 라이브(읽기) 모드에서 본문을 드래그 선택해 보낸 '선택 질문'의 인용 구절은
기존엔 클라이언트 @State 세션 한정이라 시트 재진입·재로그인 시 사라졌다.
feedback_chats(iOS)/chat_messages(서버) 양쪽에 quote 컬럼을 두고 sync로 round-trip.
표시용이며 user 메시지에만 존재. 기존 행은 모두 NULL.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "a4b5c6d7e8f9"
down_revision: Union[str, Sequence[str], None] = "f3a4b5c6d7e8"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "chat_messages",
        sa.Column("quote", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("chat_messages", "quote")
