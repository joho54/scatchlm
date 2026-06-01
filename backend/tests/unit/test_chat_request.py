"""ChatRequest 스키마 회귀 — subject 분야 필드는 optional(하위호환)이어야 한다."""

from app.routers.feedback import ChatRequest


def test_subject_defaults_to_none():
    """기존 클라이언트(subject 미전송)와 하위호환 유지."""
    req = ChatRequest(message="hi")
    assert req.subject is None


def test_subject_accepts_arbitrary_domain():
    req = ChatRequest(message="설명해줘", subject="물리학")
    assert req.subject == "물리학"
