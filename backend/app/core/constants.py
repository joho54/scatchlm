"""도메인 공용 상수 — 레이어별로 흩어지면 안 되는 단일 출처(SSOT)."""

# 노트의 주제(과목) 기본값. 빈 문자열 = 분야 중립 튜터(feedback_service._build_system_prompt 참조).
# 과거 "en"이 라우터·서비스·DB 모델 6곳에 따로 박혀 있어, 주제 누락 시 프롬프트가 literally
# "learn en"이 되거나 OCR에 "Subject: en."이 주입되던 버그가 있었다. 반드시 이 상수만 쓸 것.
DEFAULT_SUBJECT = ""
