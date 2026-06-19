# 채팅 "튕김" 디버깅 포스트모템 (2026-06-19)

iPhone 컴패니언 앱의 채팅이 "튕긴다"(앱 정지/강제종료)는 제보로 시작. 비결정적이고
"한 번 시작하면 어디서든" 발생. 종일 추적한 결과 **별개의 두 문제**가 얽혀 있었고,
진범은 **SwiftUI 자동 키보드 회피가 무거운 채팅 리스트를 재레이아웃**하던 것이었다.

---

## TL;DR

| | 증상 | 진짜 원인 | 수정 |
|---|---|---|---|
| 문제 1 | 메모리/렌더 | 버블마다 WKWebView 1개 누적(동시 15+) + MarkdownUI 중첩 ForEach 리스트 재빌드 | KaTeX를 공유 webview 1개로 **이미지로 굽기(bake)** + `EquatableChatBubble`(데이터 동일 시 재평가 스킵) |
| **문제 2 (진범)** | **키보드 올리고/내릴 때 정지** | **SwiftUI 자동 키보드 회피가 ScrollView/LazyVStack 전체를 재레이아웃** → 메인 스레드 2초+ 점유 → App Hang/워치독(`0x8badf00d`) | **입력바를 `VStack`이 아니라 `.safeAreaInset(edge:.bottom)`으로** → 키보드가 작은 inset만 밀고 리스트 프레임은 안 줄어 재레이아웃 없음 |

최종적으로 세 채팅(피드백·페이지 가이드·챕터 가이드)을 **단일 `ChatThreadView`로 통일**.

---

## 진단 여정 (틀린 가설 포함)

1. **WKWebView 누적 가설.** census 계측(`WebViewCensus`) 결과 채팅+리더에서 `live`가 1→16으로
   직선 상승, `destroy` 0건. iPhone SE에서 WebContent 프로세스 고갈 → jetsam으로 의심.
2. **bake 시도.** 버블마다 webview를 만드는 대신 KaTeX를 **공유 오프스크린 webview 1개**로
   렌더해 비트맵으로 굽고 캐시(`KaTeXSnapshotRenderer`). 여러 번 깨짐:
   - 오프스크린(숨은 윈도우) 스냅샷이 빈 이미지 → 키 윈도우 뒤로 호스팅해 해결.
   - SwiftUI 폭 측정 GeometryReader/preference **피드백 루프**로 너비 붕괴(692→24).
   - 1px 프레임에서 페인트 → 빈 스냅샷. 큰 프레임으로 페인트 후 캡처.
   - `documentElement.scrollHeight`가 20000px 프레임 높이를 흘려 **거대 이미지 → 메모리 폭발**.
3. **디바이스 `.ips`가 방향을 틀었다.** App Store 빌드(2.2.0)의 크래시는 메모리 jetsam이 아니라
   **워치독 행(`0x8badf00d`) — 메인 스레드가 SwiftUI `LazyVStack` 레이아웃에서 멈춤**.
   즉 메모리가 아니라 **레이아웃 행**이 주범이었다.
4. **MarkdownUI 제거.** 채팅 리스트의 MarkdownUI(중첩 ForEach)를 bake 이미지로 → 그 행 한 종류는
   사라짐(Sentry 재발 0). 하지만 행은 계속됨.
5. **Sentry App Hang으로 못 박음.** dev 빌드는 직접 프로파일링이 어려워 Sentry(`enableAppHangTracking`)를
   켜고 스택을 받음. 모든 행의 culprit = **`UITextSelectionInteraction._handleMultiTapGesture`**,
   breadcrumb = `UIKeyboardDidShow/Hide`, 스택 = `_UIHostingView.layoutSubviews` →
   `ViewLayoutEngine`/`ForEachList.applyNodes`/`AG::Subgraph::update`(대량 할당).
   → **키보드 전환이 채팅 뷰그래프 전체를 재평가/재레이아웃**하는 것.
6. **헛다리들(기록용):** 공유 `WKProcessPool`(효과 없음 — 현대 WebKit은 프로세스 안 합침),
   가시성 게이팅(피크 여전히 16), 동시 webview 상한(슬롯 기아로 빈 말풍선),
   per-bubble 폭 측정 제거(행 그대로), `@FocusState` 자식 격리(행 그대로).
   → 사용자가 일찍 "키보드 dismiss가 문제"라고 지목했는데 내 가설을 계속 쫓다 시간 소모.
7. **리서치 → 진범 확정.** 표준 SwiftUI 채팅 패턴 조사 결과: **SwiftUI 자동 키보드 회피가
   ScrollView+LazyVStack을 키보드 전환마다 재레이아웃하는 알려진 성능 문제**. 표준 해법은
   입력바를 `.safeAreaInset(edge:.bottom)`으로 두어 리스트 프레임이 안 줄게 하는 것.
   적용 → **해결**.

---

## 진짜 원인 (문제 2)

```
VStack { ScrollView(메시지 리스트) ; 입력바 }   // ❌ 옛 구조
```
키보드가 뜨면 SwiftUI 키보드 회피가 **VStack 전체를 위로 밀고 ScrollView를 줄인다** →
LazyVStack이 새 높이로 **전 항목 재레이아웃**. 항목이 무거우면(이미지 버블 多) 메인 스레드
2초+ → App Hang, 5초+면 워치독이 강제종료. `_handleMultiTapGesture`(입력창 더블탭/포커스)가
키보드 전환을 트리거.

```
ScrollView(메시지 리스트)                        // ✅ 표준 iMessage 패턴
  .safeAreaInset(edge: .bottom) { 입력바 }
```
키보드는 **작은 입력바(inset)만** 밀어 올리고 ScrollView **프레임은 안 줄어** 리스트 재레이아웃이
없다. 키보드 dismiss(스크롤/바깥 탭/`@FocusState`)는 **무고**했다 — 트리거였을 뿐 비용은 회피 레이아웃.

---

## 적용한 수정 (코드)

- `Views/KaTeXSnapshotRenderer.swift` — KaTeX→이미지 공유 렌더러(앱 전역 webview 1개, 직렬, 캐시).
- `Views/BakedMarkdownView.swift` — bake 이미지 표시(`@Environment(\.bakeWidth)`로 폭 1회 주입,
  per-bubble GeometryReader 제거). UIKit 카드(`BakedMarkdownUIView`)는 라이브 webview 유지
  (고정 프레임+내부 스크롤이라 전체 굽기는 50MB 이미지 → 메모리 낭비).
- `Views/ChatBubbleView.swift` — `ChatBubbleView`(통일 말풍선) + `EquatableChatBubble`
  (role/content/serverId/rating 동일 시 재평가 스킵).
- `Views/ChatThreadView.swift` — **통일 채팅 컨테이너**: 리스트 + `.safeAreaInset` 입력바 +
  키보드 처리. 헤더는 `@ViewBuilder`로 주입, 전송/평가/스크랩은 콜백. `ChatTurn` 표시 모델.
- `Views/FeedbackChatSheet.swift`, `Views/PdfViewerView.swift` — 세 채팅을 `ChatThreadView`로 이관.
  PdfViewerView의 중복 `chatBubble`/`chatInputBar` 제거.

---

## 교훈

- **SwiftUI 키보드 회피 + ScrollView/LazyVStack은 무거운 콘텐츠에서 행을 낸다.** 채팅류는 입력바를
  `.safeAreaInset(edge:.bottom)`으로. 리스트는 키보드로 재레이아웃되면 안 됨.
- **휘발성 상태(@FocusState 등)·뷰 비용은 invalidation scope를 좁혀라.** 무거운 리스트 행은
  `Equatable`로 재평가를 스킵.
- **클라이언트 perf는 Sentry App Hang(`enableAppHangTracking`)이 결정적 로그.** dev 빌드는 직접
  프로파일링이 어려우니 일찍 켤 것. App Hang 스택의 culprit/breadcrumb가 트리거를 짚어준다.
- **사용자가 원인을 지목하면 그걸 먼저 문제로 정의해 검증할 것.** (이번엔 "키보드 dismiss"를
  일찍 지목받고도 bake/레이아웃 가설을 쫓다 시간 태움.)
- **메모리 vs 행 구분:** `.ips`의 `EXC_RESOURCE/jetsam`(메모리) vs `0x8badf00d` watchdog/App Hang
  (메인 스레드 행)은 완전히 다른 수정. `JetsamEvent-*.ips` 유무로도 갈린다.

---

## 마무리 정리 TODO (디버깅 잔재)

- [ ] **임시 Sentry DSN 제거** — `Utilities/Config.swift`의 하드코드 DSN(커밋 금지 마커) → `""` 복원.
- [ ] `katex` 단계 진단 로그(`render start`/`ready`/`snapshot`) `appLogDebug` 강등 또는 제거.
- [ ] `boot` 빌드 마커를 정상값으로(현재 `unified-chat-1`).
- [ ] `PdfViewerView`의 실험용 `.ignoresSafeArea(.keyboard)` 필요 여부 재검토.
- [ ] (백엔드) Sentry 활성화 — 아래 "부록" 참고. 현재 `.env.prod`에서 `SENTRY_DSN` 뺀 상태.

---

## 부록: 백엔드 Sentry 활성화 시 startup 크래시 (2026-06-19)

iOS Sentry를 켠 김에 백엔드도 켜려고 VM `/opt/scatchlm/.env.prod`에 `SENTRY_DSN`을 넣고
app 컨테이너를 재생성하자 **부팅에서 크래시 → `/docs` 502**가 됐다.

**원인 — `sentry-sdk[fastapi]` ↔ `starlette` 버전 비호환 (코드 버그 아님):**

1. `SENTRY_DSN`이 채워지면 `app/core/sentry.py`의 `init_sentry()`가 `sentry_sdk.init()` 호출
   → FastAPI/Starlette 통합이 **자동 활성화**.
2. 통합 `setup_once` → **`sentry_sdk/integrations/starlette.py`의 `patch_templates`**
   (Starlette `Jinja2Templates`를 몽키패치)에서 예외 발생 — 설치된 `sentry-sdk==2.42.1`이
   현재 Starlette의 템플릿 API와 안 맞음.
3. `init_sentry()`는 `app/main.py`에서 **`app = FastAPI()` 생성 전**에 호출되므로(ASGI 통합
   결선 순서상 필수), 이 예외가 **모듈 임포트 시점에 그대로 터져 uvicorn 워커가 부팅 실패**
   → 컨테이너 unhealthy → 502.

**복구:** `.env.prod`에서 `SENTRY_DSN` 제거(빈 DSN이면 `init_sentry()`가 `sentry_sdk.init`을
아예 호출 안 하고 no-op) 후 `up -d app` → 정상 부팅. (`.env.prod`는 백업 후 수정.)

**다시 켜려면 (택1):**
- `sentry-sdk`를 Starlette와 호환되는 버전으로 올리기/맞추기(`requirements.txt`).
- `init`에서 통합을 명시해 템플릿 패치를 끄기 —
  `sentry_sdk.init(..., auto_enabling_integrations=False, integrations=[StarletteIntegration(), FastApiIntegration()])`
  또는 문제 통합만 제외.
- 켠 뒤 반드시 prod `/docs`·`/privacy`·`/terms` 헬스 확인(부팅 지연 있으니 재시도).

> 교훈: `init_sentry()`가 app 생성 전 import-time에 돌아 **SDK init 예외가 곧 부팅 실패**가 된다.
> DSN 토글로 prod에 켤 땐 startup 크래시 가능성을 염두에 두고 헬스체크/롤백을 준비할 것.
