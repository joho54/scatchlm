# App Store 스크린샷 (HTML 기반)

`marketing-plan-v1.md` §2.3의 7장 계획을 HTML/CSS로 프레이밍 → **2048×2732(iPad 12.9" 세로)** PNG로 렌더한다.
Figma 없이 코드로 관리하고, 영어판은 `screenshots.html` 텍스트만 교체하면 된다.
테마: 짙은 파랑 배경 + 흰 글자(앱 아이콘과 통일). 루프(#3~5)는 3장 분리 + 진행 트래커.

## 쓰는 순서

1. **실기기에서 화면 캡처(세로)** → `shots/` 에 아래 파일명대로 저장
   | 파일 | 내용 (캡처할 화면) |
   |---|---|
   | `1-feedback.png` | 손글씨 + AI 피드백 한 화면 |
   | `2-textbook.png` | 교재 PDF + 페이지 인용(`[p.33]`) 답변 |
   | `3a.png` | 루프 ① 질문 → AI 답변 |
   | `3b.png` | 루프 ② 스크랩 위에서 손으로 다시 연습 |
   | `3c.png` | 루프 ③ 스크랩 근거로 재피드백 |
   | `4-usage.png` | 실제 사용 장면(헬라어/수식 등) |
   | `5-chat.png` | 채팅 심화 |
   - 캡처 전 **콘텐츠를 실제 dogfooding 사례로 채울 것**(빈 캔버스·lorem 금지). 목업보다 진짜 손글씨가 설득력 높음(§2.3).
   - 13형 iPad(12.9"/M4) **세로**로 캡처. iPhone/시뮬레이터 비권장.

2. **미리보기**: `screenshots.html` 을 브라우저로 열어 레이아웃 확인 (이미지 없으면 회색 라벨 박스).

3. **렌더**: `node render.mjs` → `out/shot-1.png … shot-7.png` (App Store 업로드용).

## 디자인 바꾸기
- 색·폰트·여백: `style.css` 최상단 `:root` 변수만 수정. `--accent`는 앱 브랜드색으로 교체 권장.
- 캡션 문구: `screenshots.html` 의 `<h2>` / `.sub`.
- #3 루프 패널 구조: `screenshots.html` 의 `.loop` 블록.

## 셋업 (최초 1회)
```bash
npm install            # playwright
npx playwright install chromium
```

## 주의
- `out/`, `shots/`, `node_modules/` 는 빌드 산출물/대용량 → 커밋 제외 권장(.gitignore 참고).
