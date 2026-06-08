# App Store 스크린샷 — iPhone 컴패니언 (HTML 기반)

2.0.0에서 추가된 **iPhone 컴패니언**(`iphone-companion-app-spec.md`) 홍보용 스크린샷.
iPad판(`../appstore-screenshots`)과 같은 방식·테마(HTML/CSS → Playwright PNG 렌더)이며,
규격만 **iPhone 6.7" 세로 = 1284×2778**로 바꾼 자매 폴더다.
(App Store Connect iPhone 슬롯이 받는 사이즈: **6.5"=1242×2688** 또는 **6.7"=1284×2778**.
원본 사진 크기와 무관 — 템플릿이 캡처를 고정 프레임에 합성하므로 산출 PNG는 항상 1284×2778.)

## iPhone 컴패니언이 파는 가치 (캡션 근거)

iPhone은 **읽기 전용 열람 + 챕터 대화(채팅)** 다 — 신규 필기/편집은 iPad 전용(`spec §1.2/§1.4`).
그래서 캡션은 "새로 쓰는 도구"가 아니라 **"iPad에서 쓴 것을 iPhone에서 이어 보고 AI와 대화"**로 잡는다.

| 컷 | 파일 | 메시지 | 캡처할 화면 |
|---|---|---|---|
| #1 | `1-sync-notes.png`   | iPad 노트가 iPhone에 동기화 | iPhone 노트 탭 리스트 |
| #2 | `2-note-read.png`    | 필기+AI 피드백 열람          | 노트 열람(페이지 스와이프, 피드백 카드) |
| #3 | `3-textbook.png`     | 교재 PDF 휴대                | 교재 PDF 뷰어(페이지/가이드) |
| #4 | `4-chapter-chat.png` | 챕터 대화 = 핵심 가치        | 챕터별 세션 리스트(챕터 대화) |
| #5 | `5-chat.png`         | 이동 중 AI 대화             | 세션 채팅 화면 |

> ⚠️ 캡션이 "iPhone에서 필기"를 암시하지 않도록 유지할 것 — App Store 심사에서 기능과
> 스크린샷이 불일치하면 리젝 사유다. iPhone은 "열람 + 대화"가 정직한 약속.

## 쓰는 순서

1. **iPhone 실기기에서 화면 캡처(세로)** → `shots/` 에 위 파일명대로 저장
   - 빈 화면 금지 — iPad에서 dogfooding으로 채운 실제 노트/대화가 동기화된 상태로 캡처.
   - 캡처 원본 사진의 크기·기기는 무관하다(시뮬레이터든 실기기든). 템플릿이 사진을 고정
     프레임에 합성하므로 **산출 PNG는 항상 1284×2778**로 나와 App Store 규격을 만족한다.
2. **미리보기**: `screenshots.html` 을 브라우저로 열어 레이아웃 확인 (이미지 없으면 회색 라벨 박스).
3. **렌더**: `node render.mjs` → `out/shot-1.png … shot-5.png` (App Store 업로드용 1284×2778).

## 디자인 바꾸기
- 색·폰트·여백: `style.css` 최상단 `:root` 변수만 수정. iPad판과 색은 통일돼 있다.
- 캡션 문구: `screenshots.html` 의 `<h2>` / `.sub` / `.eyebrow`.

## 셋업 (최초 1회)
```bash
npm install            # playwright
npx playwright install chromium
```

## 주의
- `out/`, `shots/`, `node_modules/` 는 빌드 산출물/대용량 → 커밋 제외(.gitignore 참고).
- App Store Connect: iPhone은 같은 앱 리스팅의 **iPhone 디스플레이 슬롯**에 업로드(별도 앱 아님, Universal).
