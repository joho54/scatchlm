# ScatchLM Android Port Spec: iOS(Swift/SwiftUI) → Android(Kotlin/Compose)

> **Status:** Draft
> **Date:** 2026-05-29
> **Author:** (auto-generated)
> **결정:** 네이티브 Kotlin/Jetpack Compose (사용자 확정). KMP/Flutter는 §1.2 Out of Scope 참조.

---

## 1. Background

### 1.1 현재 상태
- 현재 활성 클라이언트는 `ios-app/` (Swift/SwiftUI, iPad 전용, `TARGETED_DEVICE_FAMILY: "2"`).
- iOS 앱은 backend FastAPI(`backend/`)에 100% 의존하는 **씬(thin) 클라이언트 + 로컬 캐시 DB** 구조다. 모든 AI 로직은 서버에 있고, 클라이언트는 드로잉/PDF 뷰어/로컬 노트 저장/피드백 카드 오버레이만 담당.
- 인증은 Supabase Auth. 클라이언트가 Supabase에서 JWT를 받아 `Authorization: Bearer` 또는 `?token=` 으로 backend에 전달. backend는 JWKS(ES256)로 검증 (`backend/app/core/auth.py:29-49`).
- **Android는 0부터 신규 작성.** iOS 코드 재사용 없음(네이티브 선택). 단, **backend API와 Supabase 인증은 그대로 재사용** — 서버 변경은 원칙적으로 불필요(§3 참조).
- iOS 앱의 로컬 DB(GRDB)는 **순수 로컬 캐시**다. 노트/드로잉/피드백 데이터는 서버에 동기화되지 않는다 (`docs/notes-sync-todo.md`로 추적 중인 미구현 항목). 따라서 **Android와 iOS는 데이터를 공유하지 않으며**, 같은 계정으로 로그인해도 각 기기의 로컬 노트는 별개다. 이는 현재 iOS도 마찬가지인 기존 제약이다.

### 1.2 Out of Scope
| 항목 | 이유 |
|---|---|
| KMP(Kotlin Multiplatform) 공유 모듈 | 사용자가 네이티브 Android를 선택. 기존 Swift 앱 재작성 부담 회피. 향후 별도 phase에서 재검토 가능 |
| Flutter 단일 코드베이스 | 동일. PencilKit급 펜 드로잉을 Flutter에서 재현하는 리스크 회피 |
| 노트/드로잉 서버 동기화 | iOS에도 없는 기능. `docs/notes-sync-todo.md`로 별도 추적. Android도 로컬 캐시로 출발 |
| iOS ↔ Android 간 노트 공유 | 서버 동기화 미구현이 선행 조건. 위 항목에 종속 |
| Android 폰(소형 화면) 최적화 | iOS가 iPad 전용. 1차는 Android 태블릿 타겟. 폰 레이아웃은 후속 |
| 피드백 카드 "냉동(frozen) 영역" 1:1 픽셀 동등성 | iOS는 UIKit UIView 직접 렌더. Compose에서 동등 동작은 목표이나 픽셀 단위 일치는 비목표 |
| Admin 대시보드(`/api/admin/usage`) | 개발자용 웹, 클라이언트 무관 |

### 1.3 기존 코드 정리 대상
- 없음. Android는 신규 디렉토리(`android-app/`)에 작성하며 기존 코드를 건드리지 않는다.
- (참고) `mobile/` 은 레거시 RN. Android 작업과 무관, 손대지 않음.

---

## 2. 현재 시스템 도식 (클라이언트 관점)

```
┌─────────────────────────────────────────────┐
│  Client (iOS 현재 / Android 신규)             │
│                                               │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐  │
│  │ 드로잉    │   │ PDF 뷰어 │   │ 피드백   │  │
│  │ 캔버스    │   │          │   │ 카드     │  │
│  │(PencilKit)│   │(PDFKit)  │   │ 오버레이 │  │
│  └─────┬────┘   └────┬─────┘   └────┬─────┘  │
│        │             │              │        │
│  ┌─────┴─────────────┴──────────────┴─────┐  │
│  │ 로컬 DB (GRDB→Room): notes/pages/      │  │
│  │ feedbacks/chats/pdf_drawings           │  │
│  └────────────────────┬───────────────────┘  │
│                       │                       │
│  ┌──────────────┐  ┌──┴────────────┐         │
│  │ AuthService  │  │  APIClient    │         │
│  │ (supabase)   │  │  (URLSession→ │         │
│  └──────┬───────┘  │   OkHttp)     │         │
│         │          └──────┬────────┘         │
└─────────┼─────────────────┼──────────────────┘
          │ JWT              │ Bearer JWT / ?token=
          ▼                  ▼
   ┌─────────────┐    ┌──────────────────────────┐
   │ Supabase    │    │ FastAPI backend           │
   │ Auth        │    │ /api/feedback, /api/pdf,  │
   │ (JWKS ES256)│◄───│ /api/feedback/chat, ...   │
   └─────────────┘    └──────────────────────────┘
```

핵심 피드백 루프 (iOS `NoteView.requestFeedback`):
```
새 스트로크만 캡처 → 이미지 렌더(최대 2000px, JPEG 0.8)
  → POST /api/feedback (multipart: image + note_id + language
       + response_language + textbook_id? + current_page?)
  → AIResponse 수신 → 피드백 카드 DB 저장 + 캔버스에 오버레이
  → frozen 영역 갱신(피드백된 스트로크 아래로 새 입력 차단)
```

---

## 3. Backend API Inventory

**결론: 신규 backend 작업 0. 모든 엔드포인트가 플랫폼 독립적 HTTP 계약이며 Android가 그대로 호출 가능.** (검증: §6)

| Method | Path | 설명 | 상태 |
|---|---|---|---|
| POST | `/api/feedback` | multipart 이미지 → AI 피드백 | ✅ 재사용 |
| POST | `/api/feedback/{id}/rate` | 피드백 평가(👍/👎 + 태그 + 코멘트) | ✅ 재사용 |
| POST | `/api/feedback/chat` | 교재 컨텍스트 후속 채팅(RAG) | ✅ 재사용 |
| POST | `/api/pdf/upload` | 교재 PDF 업로드(≤50MB) | ✅ 재사용 |
| GET | `/api/pdf/textbooks` | 교재 목록 | ✅ 재사용 |
| GET | `/api/pdf/{id}/file?token=` | PDF 파일 서빙(다운로드/스트리밍) | ✅ 재사용 |
| GET | `/api/pdf/{id}/chapters` | 목차(TOC) | ✅ 재사용 |
| GET | `/api/pdf/extract` | 페이지 범위 텍스트 추출 | ✅ 재사용 |
| GET | `/api/pdf/{id}/guide?page=&response_language=` | 페이지 학습 가이드(캐싱) | ✅ 재사용 |
| GET | `/api/pdf/{id}/chapter-guide?chapter_id=` | 챕터 학습 가이드(캐싱) | ✅ 재사용 |
| POST | `/api/dev/log/batch` | 클라이언트 로그 배치 수신 | ✅ 재사용 |
| GET | `/health` | 헬스체크 | ✅ 재사용 |

**주의사항 (Android 클라이언트가 맞춰야 할 계약):**
- 인증: `Authorization: Bearer <jwt>` 헤더, **또는** PDF 파일 로드처럼 헤더를 못 싣는 경우 `?token=<jwt>` 쿼리 (`backend/app/core/auth.py:62-82`).
- 피드백 이미지: **base64 아님.** multipart 바이너리 파일 그대로. 서버가 MIME 자동 감지(JPEG `\xff\xd8`, PNG `\x89PNG`).
- 응답 JSON은 **snake_case** (`feedback_id`, `key_points`, `page_start` 등). Android는 kotlinx.serialization `@SerialName` 또는 Moshi `@Json`으로 매핑.
- 피드백 폼 필드명: `note_id`, `language`(인식 언어, 기본 "en"), `response_language`(응답 언어, 기본 "English"/iOS는 "Korean" 기본), `textbook_id`, `current_page`, `page_start`, `page_end`, `previous_context`, `request_id`.

---

## 4. 구현 설계 (Android)

### 4.0 프로젝트 골격
- 신규 디렉토리: `android-app/` (Gradle, Kotlin DSL).
- 최소 SDK: **API 26+ 권장** (검증 필요 — §6.x). PdfRenderer는 21+, Jetpack Ink는 더 높은 요구사항일 수 있음.
- 타겟: Android 태블릿 (landscape 우선, iOS와 동일 사용 시나리오).
- 패키지명: `com.joho54.scatchlm` (iOS bundleID와 동일 컨벤션, Supabase/redirect 설정 일관성).
- 아키텍처: MVVM + Repository. `ViewModel` + `StateFlow` + Compose. Hilt 또는 수동 DI(앱 규모상 수동도 가능).

### 4.1 기술 매핑 (iOS → Android)

| 영역 | iOS | Android | 비고 |
|---|---|---|---|
| UI | SwiftUI | Jetpack Compose | |
| 드로잉 | PencilKit (`PKCanvasView`) | **Jetpack Ink API** (`androidx.ink`) | 1순위. 대안: 직접 `Canvas`+`MotionEvent` 스타일러스 처리. §7 Risk |
| 드로잉 직렬화 | `PKDrawing.dataRepresentation()` (BLOB) | Ink `StrokeInputBatch`/serialization → BLOB | **포맷 비호환** — iOS BLOB과 교환 불가. 로컬 전용이라 무방 |
| PDF 뷰어 | PDFKit (`PDFView`) | **AndroidX Pdf (`androidx.pdf`)** 또는 Pdfium 래퍼 | 페이지 단위 렌더 + 캐싱 |
| PDF 캐시 | `~/Library/Caches/pdf_<id>.pdf` | `context.cacheDir/pdf_<id>.pdf` | 동일 패턴 |
| 로컬 DB | GRDB (SQLite) | **Room** (SQLite) | 스키마 §4.3 |
| 인증 | supabase-swift | **supabase-kt** (`io.github.jan-tennert.supabase`) | gotrue/auth 모듈 |
| HTTP | URLSession | **OkHttp + Retrofit** (또는 Ktor client) | multipart 지원 필수 |
| JSON | Codable | kotlinx.serialization 또는 Moshi | snake_case 매핑 |
| 마크다운 | MarkdownUI | **compose-markdown**(jeziellago) 또는 Markwon | 피드백/가이드 렌더 |
| 설정 | UserDefaults | DataStore (또는 SharedPreferences) | `responseLanguage`, `devApiHost` |
| 빌드 설정 | XcodeGen `Config.swift` `#if DEBUG` | `BuildConfig` (debug/release flavor) | API host 분기 |

### 4.2 화면(Compose) 설계 — iOS View 1:1 매핑

| Android Screen/Composable | iOS 원본 | 역할 |
|---|---|---|
| `LoginScreen` | LoginView | 이메일/비밀번호 sign in/up |
| `HomeScreen` + `NoteCard` | HomeView | 노트 목록 그리드, 썸네일, 검색/생성/수정/삭제 |
| `CreateNoteSheet` | CreateNoteSheet | 제목/언어 입력, 교재 선택/PDF 업로드 |
| `EditNoteSheet` | EditNoteSheet | 제목/언어 수정 |
| `NoteScreen` (**핵심**) | NoteView (1302줄) | Ink 캔버스 + PDF 패널 + 피드백 카드 오버레이 + 다중 페이지 + frozen 영역 |
| `PdfViewerScreen` | PdfViewerView (706줄) | PDF 렌더 + TOC + 페이지/챕터 가이드 + 가이드 채팅 + 박제 |
| `FeedbackChatSheet` | FeedbackChatSheet | 피드백 후속 채팅, 마크다운, 평가, 박제 |
| `FeedbackRatingSheet` | FeedbackRatingSheet | 좋음/아쉬움 + 태그 + 코멘트 폼 |
| `PageNavigator` | PageNavigatorView | 페이지 썸네일 사이드 패널 |
| `SettingsSheet` | SettingsSheet | 응답 언어 설정, 로그아웃 |

복잡도 순위: `NoteScreen` ≫ `PdfViewerScreen` > 나머지. `NoteScreen`이 전체 일정의 리스크 중심.

### 4.3 로컬 DB 스키마 (Room) — iOS GRDB 1:1

iOS 마이그레이션 v1~v6의 **최종 스키마**를 Room Entity로 한 번에 정의 (Android는 신규라 점진 마이그레이션 불필요).

```
notes(id PK, title, language, textbook_id?, textbook_name?, textbook_pages,
      drawing_data BLOB?, last_page, pdf_open, current_page_index,
      created_at, updated_at)
note_pages(id PK, note_id FK→notes CASCADE, page_index, drawing_data BLOB?,
      created_at, UNIQUE(note_id, page_index))
feedbacks(id PK, note_id FK→notes CASCADE, page_id?, content,
      position_x, position_y, bbox_x, bbox_y, bbox_width, bbox_height,
      stroke_range_start, stroke_range_end, created_at,
      server_feedback_id?, user_rating?, user_rating_synced_at?)
feedback_chats(id PK, feedback_id FK→feedbacks CASCADE, role, content,
      created_at, server_message_id?, user_rating?, user_rating_synced_at?)
pdf_drawings(id PK="{textbook_id}_{page}", textbook_id, page, drawing_data BLOB,
      updated_at, UNIQUE(textbook_id, page))
```
출처: `ios-app/.../DatabaseService.swift:29-130` (v1~v6). `drawing_data`는 Ink 직렬화 포맷(iOS와 비호환, 무방).

### 4.4 상태/데이터 흐름
- `AuthRepository`(supabase-kt) → JWT 보관, `accessToken` 노출. iOS `AuthService` 대응.
- `ApiClient`(Retrofit/OkHttp) → 모든 요청에 `Authorization` 인터셉터로 Bearer 자동 첨부 (iOS `APIClient.authHeaders`:20-26 대응). PDF 파일 URL은 `?token=` 쿼리.
- `NoteRepository` / `FeedbackRepository` / `PdfRepository` → Room DAO + ApiClient 조합.
- `LogService` → 메모리 큐 + 2초 주기 flush → `POST /api/dev/log/batch` (iOS LogService 1:1).

---

## 5. 구현 단계 (Tracks)

```
                    ┌─── Track A: 프로젝트 골격 + DI + BuildConfig
                    │      (블로커: 모든 트랙의 토대)
                    │
   A 완료 후 ───────┼─── Track B: 인증 (supabase-kt) + LoginScreen
                    │
                    ├─── Track C: 데이터 계층 (Room + ApiClient + LogService)
                    │
                    ├─── Track D: 드로잉 엔진 (Ink 캔버스 + 직렬화) ★최고 리스크
                    │
                    └─── Track E: PDF 엔진 (뷰어 + 캐시)

   C 완료 후 ───────┬─── Track F: HomeScreen + 노트 CRUD + Create/EditSheet
                    │
   C+D 완료 후 ─────┼─── Track G: NoteScreen (캔버스+피드백 카드+frozen+페이지) ★핵심
                    │
   C+E 완료 후 ─────┼─── Track H: PdfViewerScreen (TOC+가이드+채팅+박제)
                    │
   C 완료 후 ───────┴─── Track I: 피드백 평가 + 채팅 시트 + 설정
```

**트랙 간 의존성:**
- **Track A는 모든 것의 블로커.** 가장 먼저 단독 완료.
- Track B/C/D/E는 A 완료 후 **완전 병렬** (서로 다른 패키지/파일).
- Track G(NoteScreen)는 C(데이터)+D(드로잉) 둘 다 필요 — 통합 지점, 가장 늦게.
- Track H(PdfViewer)는 C+E 필요.
- Track F/I는 C만 있으면 시작 가능.
- backend는 변경 없음 → 통합 테스트 블로커 없음 (서버는 이미 동작).

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | A → C → D → G → E → H → B/F/I 순차 (드로잉·노트 화면이 핵심이므로 D/G 우선 검증) |
| 2명 | P1: A→C→D→G(핵심 라인). P2: B→E→H→I (P1의 A 완료 대기 후 B부터) |
| 3명 | P1: A→C→F. P2: D→G. P3: E→H→I, B는 여유 인원이 흡수 |
| 4명 | P1: A→C. P2: D→G. P3: E→H. P4: B→F→I |

---

### Track A: 프로젝트 골격 / DI / 빌드 설정
**의존:** 없음 (블로커)
**내부 순서:** A-1 → A-2 → A-3
**작업량:** 중간. 가장 복잡: Gradle 의존성 버전 정합 + supabase-kt/Ink/AndroidX Pdf 버전 호환 확인.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `android-app/` (신규) | Gradle 프로젝트 생성, Kotlin DSL, Compose BOM, minSdk/targetSdk 결정(§6.x), `com.joho54.scatchlm` |
| A-2 | `build.gradle.kts` | 의존성: compose, room, retrofit/okhttp, kotlinx-serialization, supabase-kt, androidx.ink, androidx.pdf, datastore, compose-markdown |
| A-3 | `Config.kt` / `BuildConfig` | `apiBaseURL`(debug `http://<devApiHost>:18000/api` / release `https://scatchlm.duckdns.org/api`), supabaseURL/anonKey, `responseLanguage` 기본값 (iOS `Config.swift:1-30` 대응) |

### Track B: 인증
**의존:** Track A
**내부 순서:** B-1 → B-2
**작업량:** 작음. supabase-kt 표준 사용.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `data/auth/AuthRepository.kt` | supabase-kt 클라이언트 초기화, signUp/signIn/signOut, session 복구, `accessToken`/`userId`/`isAuthenticated` 노출 (iOS `AuthService.swift` 대응) |
| B-2 | `ui/login/LoginScreen.kt` | 이메일/비밀번호 폼, 로딩/에러 처리 (LoginView 대응) |

### Track C: 데이터 계층 (DB + 네트워크 + 로그)
**의존:** Track A
**내부 순서:** C-1, C-2, C-3 병렬 가능 (서로 다른 파일)
**작업량:** 큼. 가장 복잡: ApiClient의 multipart(C-2) + DTO snake_case 매핑.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `data/db/*` (Entities, DAOs, AppDatabase) | Room 스키마 §4.3 전체. FK CASCADE, UNIQUE 제약 |
| C-2 | `data/api/ApiClient.kt` + `dto/*` | Retrofit/OkHttp, Bearer 인터셉터, multipart(`postMultipart`/`uploadFile` 대응), 전 엔드포인트(§3) + 응답 DTO. iOS `APIClient.swift` 대응 |
| C-3 | `data/log/LogService.kt` | 메모리 큐(≤50) + 2초 flush → `/api/dev/log/batch`. `appLog`/`appLogError` 헬퍼 (iOS LogService 대응) |
| C-4 | `data/repo/*` | NoteRepository/FeedbackRepository/PdfRepository (DAO+Api 조합) |

### Track D: 드로잉 엔진 ★최고 리스크
**의존:** Track A
**내부 순서:** D-1 → D-2 → D-3
**작업량:** 큼. 가장 복잡: PencilKit 동등 UX(스타일러스 전용 입력, undo/redo, 무한 세로 캔버스, drawing→이미지 렌더) 재현.

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `ui/draw/InkCanvas.kt` | Jetpack Ink 캔버스 Composable. 스타일러스 입력(`pencilOnly` 대응), 손가락 무시 토글, 무한 세로 스크롤/콘텐츠 확장 |
| D-2 | `ui/draw/InkSerialization.kt` | 드로잉 ↔ BLOB 직렬화/역직렬화(Room 저장), undo/redo, 스트로크 개수/범위 추적(frozen용) |
| D-3 | `ui/draw/InkRender.kt` | 드로잉(또는 스트로크 부분 범위) → Bitmap 렌더 → JPEG(최대 2000px, 0.8). 다크모드 반전. iOS `requestFeedback` 이미지 파이프라인 대응 |

### Track E: PDF 엔진
**의존:** Track A
**내부 순서:** E-1 → E-2
**작업량:** 중간. 가장 복잡: 페이지 단위 렌더 성능 + 다크모드 색반전.

| ID | 파일 | 내용 |
|---|---|---|
| E-1 | `ui/pdf/PdfRenderer.kt` | AndroidX Pdf/Pdfium 래퍼, `/api/pdf/{id}/file?token=`로 다운로드 → `cacheDir/pdf_<id>.pdf` 캐시 → 페이지 렌더 |
| E-2 | `ui/pdf/PdfView.kt` | 페이지 스크롤/이동, 페이지 변경 콜백, 다크모드 colorInvert 대응 |

### Track F: 홈 / 노트 CRUD
**의존:** Track C
**내부 순서:** F-1 → F-2
**작업량:** 중간.

| ID | 파일 | 내용 |
|---|---|---|
| F-1 | `ui/home/HomeScreen.kt` + `NoteCard.kt` | 노트 그리드, 썸네일(페이지 드로잉 미리보기), 검색, 삭제 (HomeView 대응) |
| F-2 | `ui/home/CreateNoteSheet.kt`, `EditNoteSheet.kt` | 노트 생성(제목/언어/교재 선택·업로드 `/api/pdf/upload`), 수정 |

### Track G: NoteScreen ★핵심 통합
**의존:** Track C + Track D (둘 다 완료 필요)
**내부 순서:** G-1 → G-2 → G-3 → G-4 (순차, 같은 화면 누적)
**작업량:** 큼(최대). 가장 복잡: 피드백 카드 위치 계산 + frozen 영역 + 자동 스크롤 + 다중 페이지 상태 동기화.

| ID | 파일 | 내용 |
|---|---|---|
| G-1 | `ui/note/NoteScreen.kt` | Ink 캔버스 + PDF 패널 split(가로/세로 40%) 레이아웃, 노트 로드/페이지 복구 |
| G-2 | `ui/note/FeedbackRequest.kt` | 새 스트로크만 캡처 → 이미지 렌더(D-3) → `POST /api/feedback` multipart → AIResponse 처리 |
| G-3 | `ui/note/FeedbackCardOverlay.kt` | 피드백 카드 오버레이(마크다운), 위치/bbox 계산, 자동 스크롤, DB 저장 |
| G-4 | `ui/note/FrozenRegion.kt` | frozen 영역(stroke_range) 추적 → 피드백된 영역 아래로 새 입력 차단, 다중 페이지(`PageNavigator`) 전환 시 상태 리셋 |

### Track H: PdfViewerScreen
**의존:** Track C + Track E
**내부 순서:** H-1 → H-2 → H-3
**작업량:** 큼.

| ID | 파일 | 내용 |
|---|---|---|
| H-1 | `ui/pdf/PdfViewerScreen.kt` | PDF 렌더(E) + TOC(`/chapters`) 사이드 |
| H-2 | `ui/pdf/GuidePanel.kt` | 페이지 가이드(`/guide`) + 챕터 가이드(`/chapter-guide`), 마크다운 렌더 |
| H-3 | `ui/pdf/GuideChat.kt` | 가이드 채팅(`/feedback/chat`), 박제(onPin → NoteScreen 캔버스 고정) |

### Track I: 평가 / 채팅 시트 / 설정
**의존:** Track C
**내부 순서:** I-1, I-2, I-3 병렬 가능
**작업량:** 중간.

| ID | 파일 | 내용 |
|---|---|---|
| I-1 | `ui/feedback/FeedbackChatSheet.kt` | 피드백 후속 채팅(`/feedback/chat`), 로컬 메시지 DB, 마크다운, 박제 |
| I-2 | `ui/feedback/RatingSheet.kt` | 좋음/아쉬움 + 태그 + 코멘트 → `POST /api/feedback/{id}/rate`, 로컬 rating 저장/동기화 |
| I-3 | `ui/settings/SettingsSheet.kt` | 응답 언어(DataStore), 로그아웃 (SettingsSheet 대응) |

---

## 6. 확인 완료 사항 (코드 검증)

- **인증은 헤더 + 쿼리 양쪽 지원**: `backend/app/core/auth.py:62-82` — `credentials`(HTTPBearer) 또는 `?token=` Query 중 하나로 JWT 수신. 검증은 ES256 JWKS (`auth.py:33-38`). Android가 PDF 파일 로드 시 `?token=` 사용 가능 확인.
- **피드백 이미지는 multipart 바이너리(base64 아님)**: iOS `APIClient.swift:110-116`가 파일 파트로 `fileData` 직접 append. backend는 `image.read()`로 바이트 수신(조사 보고). Android도 동일.
- **JWT는 Authorization 헤더에 `Bearer ` 프리픽스**: iOS `APIClient.swift:22-24, 96-98`. Android 인터셉터 동일 구현.
- **응답/요청 필드는 snake_case**: backend Pydantic(`feedback_id`, `key_points`, `page_start` 등) 확인(조사 보고). Android DTO는 `@SerialName` 매핑 필요.
- **API host 분기는 컴파일 타임**: iOS `Config.swift:10-16` `#if DEBUG` → debug `:18000` / release `scatchlm.duckdns.org`. Android는 `BuildConfig` flavor로 대응. **주의: debug 포트는 18000** (CLAUDE.md 본문의 8000과 불일치 — 실제 코드 기준 18000 채택).
- **로컬 DB 최종 스키마**: `DatabaseService.swift:29-130`(v1~v6). §4.3에 1:1 반영.
- **드로잉 직렬화는 로컬 전용 BLOB**: iOS `PKDrawing.dataRepresentation()` → `note_pages.drawing_data`. 서버 미전송(서버엔 렌더된 이미지만 감). 따라서 Ink 포맷이 iOS와 달라도 무방.
- **의존성 버전(iOS)**: `project.yml` — Supabase 2.0.0+, GRDB 7.0.0+, MarkdownUI 2.0.0+. iOS 17.0 타겟, 패키지 prefix `com.joho54`.
- **노트 동기화 미구현**: `docs/notes-sync-todo.md` 존재 — 로컬 캐시 전제 확정.

### 6.x 미확인 항목
| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | Jetpack Ink API 안정성/최소 SDK 요구사항, PencilKit 수준 기능(압력/틸트/지연 최소화) 충족 여부 | androidx.ink 릴리스 노트 + 실기기 PoC. 미충족 시 `Canvas`+`MotionEvent` 직접 구현으로 폴백 |
| 2 | AndroidX Pdf vs Pdfium 중 어느 쪽이 다크모드 색반전·페이지 캐싱에 적합한지 | 두 라이브러리 PoC 비교 |
| 3 | minSdk 결정 (Ink/Pdf 최소 요구의 교집합) | A-1에서 라이브러리 요구사항 확정 후 결정 |
| 4 | supabase-kt가 iOS와 동일 Supabase 프로젝트에서 동일 JWT(ES256) 발급하는지 | supabase-kt 로그인 후 backend 호출 E2E 테스트 |
| 5 | 피드백 카드 좌표계: iOS는 캔버스 포인트 단위. Android dp/px 환산 시 카드 위치 정합 | G-3 구현 중 실측 |
| 6 | `previous_context` / 박제(pin) 의 정확한 페이로드 포맷 | iOS `NoteView.swift` `requestFeedback`/`pinToCanvas` 정독(스펙 구현 단계에서) |
| 7 | Android 패키지명/Supabase redirect·allowed origins 설정 충돌 여부 | Supabase 대시보드 확인 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| Jetpack Ink가 PencilKit 수준 펜 경험(지연/압력/예측) 미달 | 높음 — 앱 핵심 가치 훼손 | 초반 D-1에서 실기기 PoC. 미달 시 `Canvas`+저지연 스타일러스(`MotionEvent` historical points) 직접 구현. 일정 버퍼 확보 |
| Ink 드로잉 직렬화 포맷 불안정/버전간 비호환 | 중간 — 저장 데이터 손상 | 자체 스트로크 모델(좌표/압력 배열)을 정의해 직접 직렬화하는 안을 백업으로. 로컬 전용이라 마이그레이션 부담은 낮음 |
| NoteScreen의 피드백 카드 위치/frozen 로직 복잡도 | 높음 — Track G 지연이 전체 지연 | iOS `NoteView.swift`(1302줄) 로직을 G-2~G-4로 잘게 분할. 좌표계 정합을 §6.x-5로 조기 검증 |
| AndroidX Pdf 미성숙(다크모드/대용량 PDF 성능) | 중간 | Pdfium 폴백 준비. PoC로 조기 비교(§6.x-2) |
| supabase-kt ↔ backend JWKS(ES256) 인증 불일치 | 높음 — 전 기능 차단 | B-1 직후 E2E 인증 테스트를 최우선(§6.x-4). 실패 시 backend `verify_aud=False` 등 옵션 재확인(이미 설정됨: `auth.py:37`) |
| 태블릿 화면 다양성(해상도/종횡비)으로 split 레이아웃 깨짐 | 낮음 | Compose `WindowSizeClass` 기반 반응형. 1차는 대표 태블릿 1~2종 타겟 |
| iOS/Android 노트 데이터 비공유에 대한 사용자 기대 불일치 | 낮음 | 기존 제약(§1.1). 동기화는 별도 phase(`notes-sync-todo.md`)로 명시 |
