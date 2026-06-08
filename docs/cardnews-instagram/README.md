# 인스타/스레드 카드뉴스 (HTML 기반)

ScatchLM 홍보용 **카드뉴스 7장**을 HTML/CSS로 짜고 Playwright로 **1080×1350(@2x)** PNG로 렌더한다.
기존 앱스토어 스크린샷(`../appstore-screenshots*`)과 같은 방식 — Figma 없이 코드로 관리.

## 왜 이 구성인가 (앱스토어 광고 X)

기존 홍보물이 "기능 나열형 앱스토어 광고"라 0→1 구간에서 약하다는 판단. 초안은 1인칭 개발자 서사 10장이었으나,
**피드에서 서사 빌드업(특히 '헬라어' 같은 니치 훅)은 스크롤로 걸러진다**고 보고 서사 3장을 걷어내 **7장**으로 압축.
첫 장에서 **가치를 직격**("손으로 쓰면 AI가 바로 첨삭")하고, 차별점인 **닫힌 학습 루프(묻고 → 손으로 연습 → 다시 피드백)**
한 가지에 집중(카드 2~5). `../marketing-plan-v1.md §1.3`의 차별점 정의와 일치.

## 카드 구성 (`cardnews.html`)

| # | 역할 | 핵심 |
|---|---|---|
| 01 | 훅(가치 직격) | "손으로 쓰면 AI가 바로 첨삭한다" (브랜드 노출) |
| 02 | 루프 ① | 묻고 — 손글씨째 질문 (스크린샷) |
| 03 | 루프 ② | 연습하고 — 그 위에서 손으로 다시 (스크린샷) |
| 04 | 루프 ③ | 다시 피드백 — 한 캔버스에서 닫힘 (스크린샷) |
| 05 | 차별점 | 비교표(ChatGPT/필기앱/ScatchLM) |
| 06 | grounding | 내 교재 PDF 기준·페이지 인용 (스크린샷) |
| 07 | CTA | 앱스토어 'ScatchLM' 검색 · 무료 |

## 쓰는 순서

```bash
npm install                 # playwright (최초 1회)
npx playwright install chromium
node render.mjs             # → out/card-1.png … card-10.png
```

미리보기: `cardnews.html`을 브라우저로 열면 10장이 세로로 쌓여 보인다.

## 디자인 바꾸기

- 색·여백·강조색(`--accent` 펜 노랑): `style.css` 최상단 `:root`만 수정.
- 문구: `cardnews.html` 의 텍스트만 교체.
- 스크린샷: `assets/loop-1~3.png`, `assets/textbook.png` 교체(현재 `../appstore-screenshots/shots/`에서 복사).

## 캡션(본문)

업로드 시 함께 붙일 캡션은 `caption.md` 참조.

## 주의

- `out/`, `node_modules/` 는 산출물/대용량 → 커밋 제외(`.gitignore`).
- `assets/`는 커밋 — 스크린샷·아이콘 원본.
