# 아이폰 컴패니언 앱: iPad 전용 → Universal (iPhone 읽기 전용 뷰어)

> **Status:** Draft
> **Date:** 2026-06-06
> **Author:** (auto-generated)

---

## 1. Background

### 1.1 현재 상태

ScatchLM은 **iPad 전용** 앱이다. PencilKit으로 손글씨를 받고, 캔버스에 피드백 카드를 박고, 교재 PDF를 분할 뷰로 띄운다.

- 타겟 디바이스: `TARGETED_DEVICE_FAMILY: "2"` (iPad only) — `project.yml:64`.
- 방향: `AppDelegate.supportedInterfaceOrientationsFor`가 전역 `.portrait` 반환 (`ScatchLMApp.swift:4-8`). INFOPLIST `UISupportedInterfaceOrientations_iPad`는 4방향 모두 허용 (`project.yml:63`). NoteView는 `isLandscape` 분기로 PDF/캔버스 분할 (`NoteView.swift:75-98`) — 즉 가로 분할은 뷰 레벨에서만 쓰이고 전역 락과 공존(§6.x-1).
- 루트: `HomeView` `NavigationStack(path:)` → 노트 그리드(`LazyVGrid`, 240px 카드) → `NoteView(noteId)` (`HomeView.swift:25-34, 53`).
- 데이터는 GRDB 로컬 + sync 4테이블(notes/note_pages/feedbacks/feedback_chats)로 멀티디바이스 보존 (`SyncService.swift:292-297`). 유저별 격리는 `currentUserId` 스코프 (`DatabaseService.swift:15-17`).

### 1.2 목표

같은 코드베이스·계정·백엔드로 **iPhone에서 읽기 전용 컴패니언**을 제공한다. iPhone 사용자는:

1. **챗 서랍 열람 + 대화 이어가기** — `chapter-chat-drawer-spec.md`에서 도입하는 `chat_session` 기반 드로어(챕터별 세션 리스트, 세션 열어 대화). iPhone에서 이게 핵심 가치.
2. **노트/필기 읽기 전용 열람** — NotePage의 PKDrawing blob을 렌더만(편집·필기 불가). 피드백 카드도 함께 노출(읽기).
3. **교재 PDF 읽기 전용 열람** — 연결 교재 PDF를 페이지 단위로 보기 + 페이지/챕터 가이드 채팅.

신규 피드백 생성(손글씨 인식 `/api/feedback`)·드로잉 편집은 iPhone에서 **차단**한다.

### 1.3 설계 결정 (사용자 확정)

| # | 결정 | 비고 |
|---|---|---|
| 1 | **Universal 단일 타겟.** 기존 `ScatchLM` 타겟의 `TARGETED_DEVICE_FAMILY`를 `"1,2"`로 확장. 같은 App Store 리스팅·번들·코드. | 유지보수 최소. 별도 타겟/앱 아님 |
| 2 | **iPhone = 읽기 전용.** PencilKit 캔버스 `isUserInteractionEnabled=false`. 신규 피드백·필기 편집 진입점 숨김. | §4.3 |
| 3 | **분기 = idiom 우선.** `UIDevice.current.userInterfaceIdiom == .phone`로 iPhone 전용 UI 노출. 보조로 `horizontalSizeClass`. | §4.1 |
| 4 | **백엔드 무변경.** sync/엔드포인트는 그대로. `chat_session` sync는 `chapter-chat-drawer-spec.md` Track E/F 소관. | §3 |

### 1.4 Out of Scope

| 항목 | 이유 |
|---|---|
| 신규 피드백 생성(`/api/feedback` 손글씨 인식) | iPhone은 읽기 전용. 캔버스 입력 차단 |
| 드로잉 편집·필기·페이지 추가/삭제·순서변경 | 동일 |
| 드로어→캔버스 재스크랩/점프(placement 신규 생성) | 캔버스 편집의 일종 — iPad 전용. iPhone은 "열람+대화"만 (`chapter-chat-drawer-spec.md` Track D는 iPad) |
| 백엔드 API·sync 스키마 변경 | 본 작업은 클라이언트 UI 적응 한정. 데이터 계약은 기존+chat-drawer-spec 재사용 |
| iPhone 가로/분할 레이아웃 | iPhone은 세로 단일 컬럼. compact width 단순화(§6.x-1) |
| 교재 PDF 업로드 | iPad 전용 흐름 유지 |

### 1.5 chapter-chat-drawer-spec.md 의존

본 스펙은 그 스펙의 **`chat_session` 데이터 모델·드로어 뷰(`ChapterDrawerView`)·세션 채팅 일반화(`FeedbackChatSheet`→sessionId)** 가 iPad에서 먼저 구현됨을 전제한다. iPhone은 그 산출물을 compact 레이아웃으로 재사용한다. 따라서 **본 스펙 Track C(드로어 적응)는 chapter-chat-drawer-spec Track A/B/D 완료가 블로커**다 (§5 의존성).

조사 결과 현재 `ChatSessionRecord` 모델 정의는 iOS 코드에 일부 존재하나 v8 마이그레이션·`SyncSessionDTO`·드로어 뷰는 미구현(§6.2). 즉 챗 서랍 자체가 아직 없으므로 그 스펙이 선행돼야 한다.

### 1.6 개정 (2026-06-06): 교재 = 노트 종속, 전역 교재 탭 제거

초안의 §4.2는 iPhone 홈을 **노트/교재 2탭**으로 두고 교재 탭이 `GET /pdf/textbooks` 전역 목록을 띄웠다(`PhoneTextbooksTab`). 그러나 **교재 PDF 필기는 `pdfAnnotation(noteId, page)` 키로 노트에 영속**된다(`PdfViewerView.swift:1085`). 전역 교재 탭은 `noteId`를 못 넘겨 필기 레이어를 띄울 수 없는 모순이 있었고, iPad(`NoteView`)는 이미 교재를 **노트 내부**에서 연다(`NoteView.swift:489`).

→ **교재 탭을 제거하고 교재 진입을 노트 내부로 일원화한다.** `PhoneHomeView`는 단일 노트 리스트(`PhoneNotesTab`)만 둔다. `PhoneNoteReaderView`는 `note.textbookId != nil`일 때 툴바 "교재" 버튼을 노출 → 읽기 전용 `PdfViewerView`를 full-screen push(`noteId` 전달로 노트별 필기 렌더, `inkMode=false`로 입력 차단, `initialPage=note.lastPage`). 교재가 어떤 노트에도 연결 안 됐으면 iPhone에서 비노출(읽기 전용이라 연결 생성 불가 → 노트 종속 모델과 일관). 본 개정으로 §4.2의 교재 탭·§4.4의 진입 경로 서술은 대체된다. 구현 완료.

---

## 2. 현재 vs TOBE 구조

### 2.1 현재 (iPad only)

```
ScatchLMApp ─ auth 분기 ─ HomeView(NavigationStack)
                              ├ 노트 그리드 → NoteView(편집: PencilKit + 카드 + 분할 PDF)
                              └ (PDF는 NoteView 내 isLandscape 분할)
   device family = "2" (iPad)
```

### 2.2 TOBE (Universal)

```
ScatchLMApp ─ auth 분기 ─ RootView
                              ├ idiom == .pad  → HomeView (기존 그대로, 편집 가능)
                              └ idiom == .phone → PhoneHomeView (읽기 전용)
                                     ├ 노트 리스트 → PhoneNoteReaderView
                                     │     (PKDrawing 렌더 + 카드 읽기, 캔버스 입력 OFF)
                                     ├ 교재 리스트 → PdfViewerView (읽기 전용 + 가이드 채팅)
                                     └ 챗 서랍 → ChapterDrawerView (열람 + 세션 대화)
   device family = "1,2" (iPhone + iPad)
   sync: pull로 노트/페이지/카드/세션 수신, push는 채팅 메시지·세션만
```

**핵심:** 데이터 레이어(GRDB·sync·auth·APIClient)는 100% 재사용. iPhone은 **렌더링·네비게이션 레이어만 분기**한다.

---

## 3. Backend API Inventory & Contracts

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| POST | `/sync/push`, `/sync/pull` | 로컬-퍼스트 sync | **변경없음** (chat-drawer-spec가 sessions 추가하나 본 스펙 무관) | 기존 + chat-drawer §3.2-a |
| GET | `/api/pdf/{id}/file` | 교재 PDF 서빙 | **변경없음** | — |
| GET | `/api/pdf/{id}/chapters` | 챕터 목록 (드로어 챕터 그룹핑) | **변경없음** | — |
| GET | `/api/pdf/{id}/guide`, `/chapter-guide` | 페이지/챕터 가이드 | **변경없음** | — |
| POST | `/api/feedback/chat` | 채팅 turn (stateless) | **변경없음** | — |
| POST | `/api/dev/log/batch` | 클라이언트 로그 | **변경없음** | — |

### 3.2 신규/변경 엔드포인트 계약

**없음.** 본 작업은 순수 클라이언트(iOS) UI 적응이다. 신규 데이터 흐름이 없어 동결할 계약이 없다. 따라서 BE track 부재 → 모든 트랙은 iOS 단일 repo 내 파일 분리로 병렬화한다.

> 단, iPhone은 신규 피드백을 만들지 않으므로 `/api/feedback`(손글씨 인식)을 **호출하지 않는다**. 채팅(`/feedback/chat`)·가이드·PDF·sync만 호출. 인증·토큰·Config는 기존 그대로(`Config.apiBaseURL`, `APIClient` Bearer 헤더 `APIClient.swift:55-56`).

---

## 4. 구현 설계

### 4.1 Idiom 분기 인프라 (Track B)

iPhone 전용 UI를 노출하는 단일 진입 분기를 둔다.

- **신규 `RootView.swift`** (또는 `ScatchLMApp.body`에 분기): `auth.isAuthenticated` 후
  ```swift
  if UIDevice.current.userInterfaceIdiom == .phone {
      PhoneHomeView()
  } else {
      HomeView()   // 기존 iPad 경로 무변경
  }
  ```
- 분기 헬퍼: `Config` 또는 신규 `Platform.swift`에 `static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }`. 뷰 내부 세부 분기는 `@Environment(\.horizontalSizeClass)` 보조 사용(이미 `NoteView.swift:72`가 보유).
- **방향 (결정됨):** iPhone은 **portrait 전용**(가로 미허용). 이러면 §6.x-1의 "전역 portrait 락 vs iPad 가로 분할" 모순이 자연 해소된다 — iPhone은 어차피 portrait만 쓰므로 가로 분할 레이아웃을 고려할 필요가 없다.
  - INFOPLIST에 `UISupportedInterfaceOrientations_iPhone: "UIInterfaceOrientationPortrait"`만 선언(`UIInterfaceOrientationPortraitUpsideDown` 제외 권장).
  - `AppDelegate.supportedInterfaceOrientationsFor`(`ScatchLMApp.swift:4-8`)는 idiom 분기로 명시화: iPhone → `.portrait`, iPad → 기존 동작 유지(가로 분할 영향 없음). 현재 전역 `.portrait` 반환이 iPad 가로 분할과 어떻게 공존하는지는 §6.x-1로 별도 검증하되, **iPhone 동작은 이 분기로 확정**된다.

### 4.2 iPhone 홈 (Track B)

**신규 `Views/PhoneHomeView.swift`**:
- `NavigationStack` + `TabView` 또는 상단 세그먼트로 3개 섹션: **노트 / 교재 / 챗 서랍**.
- **노트 탭:** 단일 컬럼 리스트(`List` 또는 1열 `LazyVStack`). 카드 = 제목 + 언어 배지 + 첫 페이지 썸네일. 썸네일 렌더는 기존 `PKDrawing(data:).image(from:scale:)` 재사용(`HomeView.swift:237-254`). 탭 → `PhoneNoteReaderView(noteId)`.
- **교재 탭:** `GET /api/pdf/textbooks` 목록 → 탭 시 `PdfViewerView`(읽기 전용, §4.4).
- **챗 서랍 탭:** `ChapterDrawerView`(chapter-chat-drawer-spec Track B 산출물)를 full-screen으로(드로어가 아닌 탭/푸시). §4.3.
- 편집·추가(노트 생성 FAB, 업로드 등) 진입점은 iPhone에서 **숨김**.

### 4.3 챗 서랍 적응 (Track C) — chapter-chat-drawer-spec 의존

`ChapterDrawerView`(iPad에서 슬라이드 오버/시트로 구현됨)를 iPhone에서 **탭의 루트 화면**으로 재사용:
- 입력: 사용자의 전체 교재 목록(노트 종속 아님). 교재→챕터 섹션→세션 행.
- 세션 행 액션 중 iPhone 허용: **열기**(세션 채팅 — `FeedbackChatSheet`의 sessionId 일반화 버전, chapter-chat-drawer Track D-1)만. **점프/스크랩은 비노출**(캔버스 편집, Out of Scope §1.4).
- 세션 채팅에서 메시지 전송 → `POST /feedback/chat` + 로컬 영속 + sync push(`chat_message`/`chat_session` dirty). 읽기 전용 앱이지만 채팅 메시지·세션 생성은 허용(편집이 아닌 학습 행위).
- 진입점/배지/placement 아이콘은 chapter-chat-drawer §4.3 그대로. iPhone은 액션 메뉴에서 점프·스크랩 항목만 `Platform.isPhone` 가드로 제거.

### 4.4 PDF 뷰어 적응 (Track D)

`PdfViewerView.swift`는 이미 읽기 전용(`PDFView` 기본 비편집, `PdfViewerView.swift:796-923`). compact width 적응만:
- iPhone에서 단일 컬럼 전체 화면. 상단바·하단 가이드/TOC 버튼 레이아웃을 compact에 맞게(버튼 축소/오버플로 메뉴).
- 가이드 채팅(`guideChatMessages`/`chapterChatMessages` `@State`, `PdfViewerView.swift:209`)은 시트로 그대로. chapter-chat-drawer Track C가 이를 세션 영속화하면 iPhone도 자동 수혜.
- 교재 PDF 다운로드/캐시는 기존 `APIClient.getData("/pdf/{id}/file")` 경로 재사용(유효 PDF 검증 후 로컬 캐시).

### 4.5 노트 읽기 전용 뷰어 (Track E)

**신규 `Views/PhoneNoteReaderView.swift`** — `NoteView`를 통째로 재사용하지 않고 읽기 전용 경량 뷰를 신설(NoteView는 편집·좌표·frozen 로직이 무거워 compact 회귀 위험 큼, §7 R3):

- **페이지 네비:** 세로 스와이프 또는 `TabView(.page)`로 NotePage 순회. 페이지별 배경(흰/검) + 드로잉 + 카드 오버레이.
- **드로잉 렌더 (결정됨 — 카드 좌표 정합 최우선):** **읽기 전용 PKCanvasView 채택.** `PencilKitCanvasView`(`NoteView.swift:1120-1174`)를 재사용하되 `isUserInteractionEnabled=false` + `drawingPolicy=.pencilOnly` 고정으로 입력만 차단한다. 카드 좌표가 캔버스 콘텐츠 좌표계(`fb.positionY`, `NoteView.swift:1618`)에 묶여 있어, 같은 캔버스/스케일 로직을 그대로 쓰는 이 방식이 **카드 위치 정합을 보장**한다. (이미지 렌더 방식은 가볍지만 `fb.positionY` 스케일 매핑을 새로 맞춰야 해 정합 리스크 — 기각.)
  - 캔버스 스크롤/줌은 기존처럼 호스트 `UIScrollView`가 담당(`isScrollEnabled=false`, `NoteView.swift:1128`). iPhone에서도 동일 호스팅으로 좌표계 유지.
- **피드백 카드:** `renderCard()`(`NoteView.swift:1484-1625`)의 읽기 부분 재사용. iPhone에서 버튼바는 **대화(chat)만** 노출, 👍/👎·자세히·복사는 유지 가능, **되돌리기·스크랩은 숨김**(편집). 카드 "대화" → 세션 채팅(§4.3).
- **frozen 오버레이 제거:** 필기 금지 회색 바(`NoteView.swift:1430-1454`)는 입력이 없으므로 불필요 — 렌더 안 함.
- **편집 진입점 전무:** 툴바(펜/지우개/페이지관리/슬라이드오버 편집)는 비노출.

### 4.6 빌드 설정 (Track A)

`project.yml`:
- `TARGETED_DEVICE_FAMILY: "2"` → `"1,2"` (`project.yml:64`).
- `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: "UIInterfaceOrientationPortrait"` 추가.
- `xcodegen generate` 재생성 후 iPhone 시뮬레이터 destination으로 컴파일 검증.
- App Store: Universal이므로 별도 리스팅 불필요. 스크린샷에 iPhone 추가 필요(출시 체크리스트, 본 스펙 범위 외).

---

## 5. 구현 단계 (Tracks)

```
        ┌─ (선행) chapter-chat-drawer-spec.md: chat_session 모델 + ChapterDrawerView + 세션 채팅
        │        (Track A/B/D) ── 본 스펙 Track C의 블로커
        │
시작 ───┼─ Track A: 빌드 설정(project.yml device family/orientation)  [블로커 약함, 독립]
        │
        ├─ Track B: idiom 분기 + PhoneHomeView (RootView, 탭 셸)
        │
        ├─ Track D: PdfViewerView compact 적응 (읽기 전용 + 가이드)
        │
        ├─ Track E: PhoneNoteReaderView (드로잉 읽기 렌더 + 카드 읽기)
        │
        └─ Track C: 챗 서랍 iPhone 적응  ── chapter-chat-drawer 산출물 의존
```

**트랙 간 의존성:**
- **Track A**는 독립(빌드 설정). 먼저 끝내면 나머지 트랙이 iPhone 시뮬레이터에서 컴파일/실행 검증 가능 → 사실상 선행 권장.
- **Track B**는 셸(루트 분기 + 탭). C/D/E의 진입점이므로 B의 인터페이스(탭 구성, 네비 push 시그니처)만 합의되면 C/D/E와 병렬. B가 stub 화면을 먼저 깔면 C/D/E는 각 뷰만 채움.
- **Track C**는 `chapter-chat-drawer-spec` Track A(모델)/B(드로어)/D(세션채팅) 완료가 블로커. 그 전엔 C 시작 불가 → C를 마지막에.
- **Track D, E**는 서로 다른 파일(`PdfViewerView.swift` / `PhoneNoteReaderView.swift` 신규)·B와 다른 파일 → 병렬.
- 파일 충돌 주의: `ScatchLMApp.swift`(루트 분기)는 Track B 단독 소유. `project.yml`은 Track A 단독.

**인원별 배분:**
| 인원 | 추천 |
|---|---|
| 1명 | A → B → D → E → (drawer 완료 후) C |
| 2명 | P1: A→B→C / P2: D→E (B 셸 합의 후 병렬) |
| 3명 | P1: A→B / P2: D / P3: E → 이후 누구든 C(drawer 완료 후) |

### Track A: 빌드 설정
**의존:** 없음 (선행 권장)
**작업량:** 작음.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `ios-app/project.yml` | `TARGETED_DEVICE_FAMILY "2"→"1,2"`; `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` 추가 |
| A-2 | (빌드) | `xcodegen generate` → iPhone 시뮬레이터 destination 컴파일 검증 |

### Track B: idiom 분기 + iPhone 홈 셸
**의존:** 없음 (A 후 실행 검증 용이)
**내부 순서:** B-1 → B-2 → B-3
**작업량:** 중간. 가장 복잡: 탭 셸 네비게이션 + 편집 진입점 가드.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `Utilities/Platform.swift` (신규) 또는 `Config.swift` | `isPhone` 헬퍼 |
| B-2 | `App/ScatchLMApp.swift` 또는 `Views/RootView.swift`(신규) | auth 후 idiom 분기 (`PhoneHomeView` vs `HomeView`) |
| B-3 | `Views/PhoneHomeView.swift`(신규) | 노트/교재/챗서랍 탭 셸, 노트 리스트(썸네일 재사용), 편집 진입점 숨김 |

### Track C: 챗 서랍 iPhone 적응
**의존:** **chapter-chat-drawer-spec Track A/B/D 완료** + 본 스펙 B-3
**작업량:** 작음(재사용). 가장 복잡: 점프/스크랩 액션 `isPhone` 가드.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `Views/ChapterDrawerView.swift` (drawer-spec 산출물) | iPhone에서 탭 루트로 표시; 세션 행 액션을 "열기"만 노출(점프/스크랩 `Platform.isPhone` 가드) |
| C-2 | `Views/FeedbackChatSheet.swift` (drawer-spec 일반화본) | compact width 레이아웃 점검(이미 sessionId 기반이면 무변경에 가까움) |

### Track D: PDF 뷰어 compact 적응
**의존:** B 셸 인터페이스 합의 후 (병렬)
**작업량:** 중간.

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `Views/PdfViewerView.swift` | compact width 레이아웃(상단바·가이드/TOC 버튼 오버플로); iPhone 진입 경로 |
| D-2 | `Views/PdfViewerView.swift` | 가이드/챕터 채팅 시트 compact 점검(기존 @State 그대로) |

### Track E: 노트 읽기 전용 뷰어
**의존:** B 셸 인터페이스 합의 후 (병렬)
**작업량:** 중간~큼. 가장 복잡: 드로잉 렌더 정합(§6.x-2 결정) + 카드 좌표 매핑.

| ID | 파일 | 내용 |
|---|---|---|
| E-1 | `Views/PhoneNoteReaderView.swift`(신규) | 페이지 순회(TabView page) + 드로잉 렌더(§4.5 A/B) + 배경 |
| E-2 | `Views/PhoneNoteReaderView.swift` | 피드백 카드 읽기 렌더(`renderCard` 재사용, 버튼바 축소), frozen 제거 |
| E-3 | `Views/PhoneNoteReaderView.swift` | 카드 "대화" → 세션 채팅 진입(C 의존 — 없으면 비활성 stub) |

---

## 6. 확인 완료 사항 (코드 검증)

### 6.1 빌드/타겟
- iPad 전용 확정 — `TARGETED_DEVICE_FAMILY: "2"` (`project.yml:64`), `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: false` (`project.yml:65`).
- 방향 전역 락 — `AppDelegate.supportedInterfaceOrientationsFor` → `.portrait` (`ScatchLMApp.swift:5-6`). iPad INFOPLIST는 4방향(`project.yml:63`)이나 AppDelegate가 상위 제어. iPhone 키 미존재.
- deploymentTarget iOS 17.0 (`project.yml:4-5`) — iPhone도 동일 최소 버전.

### 6.2 데이터/sync (재사용 가능 확인)
- sync 4테이블 제네릭 dirty-flag 루프 — notes/note_pages/feedbacks/feedback_chats (`SyncService.swift:292-297`). 앱 시작/foreground에서 `requestSync()` (`ScatchLMApp.swift:50`). iPhone은 pull로 전량 수신, push는 채팅만.
- 유저 격리 — 모든 R/W가 `currentUserId` 스코프, 미로그인 시 빈 결과/throw (`DatabaseService.swift:15-17, 43-47`). GRDB 최신 v7 (`DatabaseService.swift:176`). iPhone 추가 마이그레이션 불필요(읽기 전용).
- 인증·API — Supabase 세션 Keychain, `Authorization: Bearer` (`APIClient.swift:55-56`), `Config.apiBaseURL` 분기. iPhone 동일 흐름.
- 교재 PDF 캐시 — `APIClient.getData("/pdf/{id}/file")` 후 유효 PDF 검증 캐시 (`PdfViewerView.swift` ~280). 재사용.

### 6.3 렌더 재사용
- 드로잉 이미지 렌더 패턴 존재 — `PKDrawing(data:).image(from:scale:)` 썸네일 (`HomeView.swift:237-254`). 풀사이즈 읽기에 확장 가능.
- 캔버스 읽기 전용화 지점 — `PencilKitCanvasView.makeUIView` (`NoteView.swift:1120-1174`); `isUserInteractionEnabled=false` + `drawingPolicy` 고정으로 입력 차단.
- NotePage blob — `drawingData: Data?` 페이지별 PKDrawing 직렬화 (`Note.swift:271-332`).
- 카드 렌더 — `renderCard()` (`NoteView.swift:1484-1625`), 카드 위치 `fb.positionY` 캔버스 콘텐츠 좌표 (`NoteView.swift:1618`). 좌표계 정합이 읽기 뷰 설계의 관건.
- PDF 읽기 전용 — `NativePdfView` 기본 비편집 (`PdfViewerView.swift:796-923`).

### 6.4 챗 서랍 선행 상태
- `chat_session`/`ChapterDrawerView`/세션 채팅 — **미구현**. `ChatSessionRecord` 모델 일부만 존재, v8 마이그레이션·`SyncSessionDTO`·드로어 뷰 없음. → `chapter-chat-drawer-spec.md`가 선행돼야 Track C 가능.

### 6.x 미확인 항목
| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | ~~iPhone 추가 시 가로 분할 모순~~ → **결정: iPhone portrait 전용**(§4.1). iPhone은 가로 미허용으로 모순 회피. 단 iPad 가로 분할이 전역 `.portrait` 락과 현재 어떻게 공존하는지(iPad 측 동작)는 A-1 후 회귀 확인 | iPad 가로 동작 회귀 테스트(iPhone과 무관, iPad 기존 동작 보존 확인용) |
| 2 | ~~드로잉 렌더 방식~~ → **결정: 읽기전용 PKCanvasView**(§4.5, 카드 좌표 정합 최우선). 미확인 해소 | — |
| 3 | 챗 서랍 진입 위치 — iPhone 탭 vs 노트/PDF 내부 버튼. chapter-chat-drawer §6.x-1(진입점 미확정)과 연동 | 두 스펙 UX 합의 |
| 4 | iPhone에서 카드 버튼바 노출 범위 — 대화만 vs 평가/복사 포함. 읽기 전용 정의의 경계 | 사용자 UX 결정 |
| 5 | 노트 리스트 정렬/필터(교재별 등) iPhone에서 필요 여부 | 사용자 UX 결정 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| **R1. 챗 서랍 미선행** — Track C가 chapter-chat-drawer 산출물에 묶임. 그 스펙 지연 시 iPhone 핵심 가치(챗) 공백 | 높음 | A/B/D/E를 먼저 완성해 iPhone "노트·PDF 열람" MVP 선출시. C는 drawer 완료 후 후속 릴리스 |
| **R2. 카드 좌표 정합 깨짐** — 읽기 뷰의 드로잉/카드 좌표계가 iPad 캔버스와 달라 카드가 엉뚱한 위치 | 중간 | §4.5 결정대로 읽기전용 PKCanvasView로 캔버스/스케일 로직 동일 재사용 → 정합 보장. compact width에서 호스트 ScrollView contentSize가 iPad와 동일 단위인지만 확인 |
| **R3. NoteView 재사용 회귀** — 편집용 NoteView를 iPhone에 직접 끼우면 frozen/좌표/툴바 로직이 compact에서 깨짐 | 높음 | NoteView 직접 재사용 금지. `PhoneNoteReaderView` 신설로 격리(§4.5). 기존 iPad 경로 무변경 |
| **R4. 읽기 전용 누수** — 어딘가 편집 진입점(제스처/툴바/FAB)이 iPhone에 노출되어 빈 캔버스 생성·sync 오염 | 중간 | `isUserInteractionEnabled=false` + 편집 뷰 자체를 iPhone에 미탑재. push는 채팅/세션 dirty만 발생함을 sync 로그로 검증 |
| **R5. iPad 가로 회귀** — iPhone portrait 강제를 위해 `AppDelegate`를 idiom 분기하다 iPad 가로 분할이 깨짐 | 중간 | iPhone→`.portrait`, iPad→기존 반환 유지(분기로 격리). A-1 후 iPad 가로 동작 회귀 테스트 |
| **R6. App Store Universal 리젝** — iPhone 빌드인데 핵심 기능 빈약/플레이스홀더면 심사 반려 | 중간 | iPhone은 "동기화된 노트·교재 열람 + AI 챗"으로 명확한 독립 가치 제시. 빈 화면/“iPad에서 쓰세요” 류 금지 |

---

## 8. 권장 진행 순서

1. **Track A** 먼저 — `TARGETED_DEVICE_FAMILY "1,2"` + iPhone `UISupportedInterfaceOrientations_iPhone: Portrait` + `AppDelegate` idiom 분기. iPhone 시뮬레이터 빌드/실행 가능하게(검증 기반 마련).
2. A-1 후 iPad 가로 분할 회귀 테스트(iPhone portrait 강제가 iPad에 번지지 않는지).
3. **Track B** 셸 합의 → C/D/E 병렬 해금. B는 stub 탭 먼저.
4. **Track E**(노트 읽기) — 읽기전용 PKCanvasView로 착수(렌더 방식 확정됨).
5. **Track D**(PDF) 병렬.
6. `chapter-chat-drawer-spec` 완료 확인 후 **Track C**(챗 서랍) — iPhone 핵심 가치 완성.
7. iPhone 빌드는 시뮬레이터 destination으로 컴파일 검증(CLAUDE.md 빌드 정책).
