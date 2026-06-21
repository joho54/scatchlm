"""ai_response.handwriting_transcription — 손글씨 원문(one-pass structured output)

Revision ID: b4c5d6e7f8a9
Revises: a3b4c5d6e7f8
Create Date: 2026-06-21 12:00:00.000000

손글씨 피드백 Vision 호출이 structured output으로 함께 뱉는 사용자 필기 원문(transcription).
후속 채팅이 노트 원문을 컨텍스트로 주입하는 데 쓴다(채팅 시점엔 이미지가 없어 "피드백 요청한
문장"의 실체가 프롬프트에 없던 틈을 메움). 기존 행은 NULL(백필 불가 — 원본 이미지가 없음).
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "b4c5d6e7f8a9"
down_revision: Union[str, Sequence[str], None] = "a3b4c5d6e7f8"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "ai_response",
        sa.Column("handwriting_transcription", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("ai_response", "handwriting_transcription")
