# 온보딩 데모 교재 에셋

`demo-template.pdf` — 온보딩(가이드된 첫 성공)에서 쓰는 데모 교재.

> ⚠️ 현재 파일은 **플레이스홀더**(`scripts/gen_demo_textbook.py` 생성)다. 앱의 첫인상이므로
> 디자인된 정식 PDF로 교체할 것.

## 교체 방법 (코드 변경 불필요)

1. 같은 파일명으로 두 곳을 덮어쓴다:
   - `backend/app/assets/demo-template.pdf` (백엔드 — 텍스트 추출용 복사 원본)
   - `ios-app/ScatchLM/Resources/demo-template.pdf` (iOS 번들 — 온보딩 표시용)
2. 배포(백엔드 재배포 + iOS 재빌드).

## 자동 반영 동작

- 백엔드 `ensure_demo_textbook`은 **콘텐츠 인지**다. 템플릿 해시가 바뀌면 각 유저의 기존
  사본(`demo-{user_id}`)을 다음 요청 때 **자동 갱신**(파일 재복사 + total_pages·챕터 재생성).
- 페이지 수는 PDF에서 **자동 추출**되므로 몇 쪽이든 OK.
- 단, iOS `OnboardingView.demoTextbookPages`는 페이지 인디케이터용 상수라 **페이지 수가 바뀌면
  이 값만 맞춰** 주면 된다(표시 정확도용 — PDF 자체는 PDFKit이 실제 쪽수대로 렌더).

## 요건

- **텍스트 레이어 PDF**(스캔 이미지 아님) — 백엔드가 페이지 텍스트를 LLM 컨텍스트로 추출.
- 저작권 안전(자작). 손글씨로 답하기 좋은 간단한 문제/빈칸 구성 권장(페이지↔프롬프트↔기대 피드백 한 세트).
