# 온보딩(첫 실행) — 가이드된 첫 성공 Spec

> **Status:** Draft
> **Date:** 2026-06-08
> **Author:** (auto-generated)
> **Scope:** iOS 앱 + 백엔드(소폭). 자작 2쪽 데모 교재 + 실제 PencilKit 필기 + 교재 기준 AI 피드백.

---

## 1. Background

### 1.1 현재 상태

- **온보딩이 전무하다.** firstLaunch 게이팅 플래그·intro/welcome 뷰가 없다. `ScatchLMApp.swift:30-42`는 `isLoading → isAuthenticated → LoginView` 3분기뿐이고, 인증되면 곧장 `HomeView`/`PhoneHomeView`로 떨군다.
- 그 결과 신규 사용자가 **빈 화면 + 빈 캔버스**에 떨궈진다. 운영 텔레메트리상 외부 신규 사용자(`c9e3dcca`)가 안내 없이 헤매다(교재 업로드 실패 → 빈 캔버스 피드백 7회 무반응) 이탈한 사례가 있다(`docs/known-issues.md`, `pdf-upload-cloud-materialize-spec.md`).
- 목표: **첫 실행에서 "데모 교재 페이지를 보고 → 손으로 답을 쓰고 → 그 교재 기준 AI 피드백을 받는" 핵심 루프를 직접 체험**시켜 활성화(activation)시킨다. 슬라이드 투어가 아니라 guided first success.

### 1.2 Out of Scope

| 항목 | 이유 |
|---|---|
| 슬라이드형 기능 투어 | magic-moment 제품은 체험형이 정석. 슬라이드는 별도 |
| 다국어 데모 교재 | 1세트(자작 2쪽)만. 확장은 후속 |
| 온보딩 재진입/설정에서 다시 보기 | v1은 첫 1회만. 필요 시 후속 |
| 펜 페어링 안내·튜토리얼 | 별도. 본 스펙은 필기→피드백 루프에 집중 |
| RAG 임베딩 인덱싱(데모 교재) | `ENABLE_EMBEDDING=false` 기본. 교재 컨텍스트는 챕터 텍스트 주입으로 충분 |

### 1.3 note_id / textbook_id 필수 여부 (정정)

- 코드 확정: **`note_id`는 필수**(`feedback.py:48` `note_id: str = Form(...)`), **`textbook_id`(교재/PDF)는 optional**(`:52` `str|None=Form(None)`). 즉 "교재 없이 피드백은 가능, 그러나 note_id는 항상 필요"가 정상 설계다.
- 함의: 온보딩 피드백 호출도 **note_id가 있어야 한다.** → **백엔드 변경 없이**, 온보딩이 노트를 1개 만들어 그 note_id로 호출한다(설계 결정 §4.4, Track B-0). `/feedback` 핫패스는 손대지 않는다.
- (대안 A — 채택 안 함) `/feedback`의 note_id를 optional로 바꾸는 길도 있으나, 핫패스 변경 + downstream(quota/영속화) 영향 검증이 필요하고 note_id를 필수로 둔 모델을 깨므로 보류.

---

## 2. 목표 플로우

```
첫 실행 (isAuthenticated && !onboardingCompleted)
   │  .fullScreenCover (HomeView 위)
   ▼
[1] 환영 — "30초면 핵심을 보여드릴게요"   [건너뛰기 항상 노출]
   ▼
[2] 데모 교재 2쪽 (PDFKit PDFView, 번들 PDF)
   + 캔버스(bare PKCanvasView) — "이 페이지를 보고 빈칸에 답을 써보세요"
   [코치마크: 캔버스 → sparkles 버튼 순]
   ▼
[3] sparkles 탭 → "AI가 필기를 읽고 있어요…" 연출 (첫 1회뿐이라 OK)
   │  내부: 스트로크→이미지→POST /feedback (textbook_id=데모 고정, current_page)
   ▼
[4] 실제 교재 기준 피드백 카드 등장
   (실패 시 → 준비된 예시 피드백 폴백)
   ▼
[5] "교재 PDF를 연결하면 이렇게 그 교재 기준으로 피드백해요" → [시작하기]
   ▼
onboardingCompleted = true → HomeView
```

---

## 3. Backend API Inventory & Contracts

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| POST | `/api/feedback` | 캔버스 이미지 → 피드백 | **변경없음** | note_id+textbook_id 그대로 전송 |
| GET | `/api/pdf/{id}/file` | PDF 서빙 | 변경없음 (온보딩은 번들 PDF 사용, 미호출) |
| GET | `/api/pdf/{id}/chapters` | 챕터 목록 | 변경없음 |

**API 엔드포인트 변경 없음.** 단 백엔드 **코드 변경은 있다** — `ensure_demo_textbook(user_id)`(§4.3): 각 유저에게 데모 교재 **딥카피본**을 idempotent하게 보장. `/feedback`은 textbook_id 소유권을 `user_id`로 검사하므로(`feedback.py:78-85`), 데모 교재는 **유저별 소유 복사본**이어야 한다(공용/시스템 교재 불가).

→ **API 계약 동결 N/A** (신규/변경 엔드포인트 없음). 데모 교재 textbook_id는 **결정적**: `demo-{user_id}` (iOS·백엔드 공유 규칙).

### 3.2 온보딩 피드백 호출 (기존 계약 그대로)

- **Request (예시, 온보딩):** `multipart: image=<jpeg>, note_id="<온보딩 노트 id>", textbook_id="demo-<user_id>", current_page=1, language="English", response_language=<Config.responseLanguage>, request_id="ONB-xxxx"`
- note_id = 온보딩이 생성한 노트 id(B-0). textbook_id = `demo-{세션 user id}` (iOS가 세션 sub로 계산).
- Response 200: `{ type, content?, feedback_id? }` (`AIResponse`, 변경 없음). 데모 교재 복사본이 있으면 소유권 통과 → 교재 컨텍스트 주입.

---

## 4. 구현 설계

### 4.1 첫 실행 게이팅 (iOS)

- `@AppStorage("onboardingCompleted") var onboardingCompleted = false` (`Config` 또는 App 레벨).
- `ScatchLMApp.swift:30-42`의 `isAuthenticated` 분기에서, Home을 띄우되 `!onboardingCompleted`면 `.fullScreenCover`로 `OnboardingView`를 덮는다.
- 완료/건너뛰기 → `onboardingCompleted = true` → cover dismiss.
- 참고: 첫 실행 감지 패턴은 `AuthService.swift:64-68`(`freshInstallKey`)에 선례 있음. 단 그건 Keychain purge용이라 별개 플래그 사용.

### 4.2 OnboardingView (iOS) — 얇은 호스트

- **PDF 표시**: bare `PDFView` (`PdfViewerView.swift:948-959` 최소 구성 참고 — `autoScales/displayMode=.singlePage`), 번들 PDF(`Bundle.main.url(forResource:)`)를 `PDFDocument(url:)`로 로드. 노트의 `PdfViewerView`(잉크오버레이/스냅페이징) 재사용 금지.
- **필기**: bare `PKCanvasView`. 노트 설정 복제(`NoteView.swift:1337-1378`): `drawingPolicy`(시뮬 `.anyInput`/기기 `.default`), `isScrollEnabled=false`, `backgroundColor=.clear`, `tool=PKInkingTool(.pen, .black, 3)`. toolPicker는 선택(온보딩엔 생략 가능).
- **피드백 호출**: §4.4 추출 함수 사용.
- **코치마크/연출/카드**: 온보딩 전용 경량 UI. 피드백 카드는 노트의 카드 렌더(DB 결합) 재사용하지 말고 단순 텍스트 카드로 표시.

### 4.3 데모 교재 — 유저별 딥카피 (idempotent ensure, 둘 다 호출)

`/feedback`이 textbook_id 소유권을 `user_id`로 검사하므로(`feedback.py:78-85`), **공용/시스템 교재는 불가** — 각 유저가 데모 교재를 **소유**해야 한다. 그래서 정적 템플릿을 **유저별로 딥카피**한다.

**정적 템플릿 (소유자 없는 에셋):**
- 데모 PDF 파일: repo/스토리지의 **고정 key**(예: `demo-template.pdf`). 텍스트 레이어 PDF(스캔본 아님 — 백엔드 챕터 텍스트 추출용).
- 챕터 정의: 코드/JSON 상수(2쪽 → 챕터 1개 `level=1, p1-2`). 자작이라 TOC 없음.
- → DB row가 아니라 **에셋**이므로 시스템 유저·템플릿 소유자 불필요.

**`ensure_demo_textbook(user_id) → textbook_id` (idempotent, 신규):**
```
id = f"demo-{user_id}"
if textbook_sources[id] 존재: return id          # idempotent — 재호출 안전
storage.copy(template_pdf → f"{user_id}_demo.pdf")  # 파일도 복사(2쪽이라 저렴, 삭제 결합 회피)
INSERT textbook_sources(id, user_id, server_path=복사본, total_pages=2,
                        is_scanned=false, scan_evaluated=true, ...)   # textbook.py:10-38
INSERT chapters(textbook_id=id, level=1, page_start=1, page_end=2)    # chapter.py:9-22
return id
```
- **결정적 id `demo-{user_id}`** → iOS가 세션 user id로 계산, 조회 불필요.
- **반드시 idempotent** (있으면 no-op). 내부 retry 2~3회 권장(스토리지 transient 대비).

**두 지점에서 호출 (belt-and-suspenders):**
1. **프로비저닝** `_ensure_user_exists`(`auth.py:76-84`) 직후 — **best-effort**. try/except로 감싸 **실패해도 인증·유저생성은 절대 안 깨지게**. (모든 유저가 데모 교재를 받음 — 제품적으로 OK 합의됨: 빈 목록보다 샘플 1개가 나음.)
2. **온보딩 진입** — 백스톱 재시도. 그래도 textbook 컨텍스트가 안 잡히면(피드백이 일반 응답) → 준비된 예시 피드백 폴백(§7).

> 템플릿 PDF는 **백엔드(텍스트 추출용 복사 원본)** 와 **앱 번들(온보딩 표시용)** 두 곳에 동일 파일.

### 4.4 피드백 경로 추출 (iOS, 공유)

**B-0 — 온보딩 노트 생성 (note_id 확보):** note_id는 필수이므로 온보딩 진입 시 노트를 1개 생성(`DatabaseService.createNote` 등 기존 경로 재사용)해 그 id를 피드백에 쓴다. 완료 시 처리는 §4.6.

`NoteView.requestFeedback`(`NoteView.swift:1077-1217`)에서 **순수 부분**(라인 1099-1155: `PKDrawing(strokes:) → bounds → image → UIGraphicsImageRenderer → jpegData`)을 **자유 함수/유틸로 추출**해 노트·온보딩이 공유. multipart 구성·호출(`APIClient.postMultipart`, `APIClient.swift:116-157`)도 공유하되:
- 노트: note_id + textbook_id + current_page + previous_context …
- 온보딩: **note_id=온보딩 노트 id**, textbook_id=`demo-{세션 user id}`, current_page=1, language/response_language(`Config`). (진입 시 `ensure_demo_textbook` 백스톱 호출 후)

> 최소 추출만. requestFeedback 통째 리팩토링으로 노트 흐름(frozen/카드/DB) 회귀 내지 말 것.

### 4.6 온보딩 노트 처리 — 첫 노트로 남김 (확정)

완료 시 B-0의 온보딩 노트를 **사용자의 첫 노트로 남긴다** — 온보딩 후 "이미 노트 하나가 있는" 모멘텀. 캔버스의 데모 필기·피드백은 그대로 둔다(첫 결과물 보존). "연습 노트" 등으로 명명 권장.
- 데모 교재(textbook_id)를 노트에 **영속 attach하지 않는다** — 피드백 호출 시에만 textbook_id를 명시 전달. (데모 교재가 노트에 묶이는 혼란 방지.) 재오픈 시엔 일반 노트.

### 4.5 데모 콘텐츠 (디자인 산출물)

- 자작 2쪽 PDF. 저작권 안전. **누구나 접근 가능**(기초 영어 권장: 페이지가 간단한 문제/빈칸 제시 → 사용자가 답 손글씨).
- **페이지 내용 ↔ "써보세요" 프롬프트 ↔ 기대 피드백**을 한 세트로 설계해야 "교재 기준"이 체감됨. (예: p.1에 "Translate: 사과 → ___" → 사용자 "apple" → 그 교재 기준 피드백.)
- 텍스트 레이어 포함(백엔드 챕터 텍스트 추출용). 이미지-only 스캔 금지.

---

## 5. 구현 단계 (Tracks)

> 규모: 1~2인. 데모 콘텐츠 제작은 디자인/문안 작업이라 병렬 가능.

```
시작
 ├─ Track A (backend): 데모 교재 딥카피 (ensure_demo_textbook)
 │     A-1 ensure_demo_textbook(user_id) idempotent 함수 + 정적 템플릿(PDF+챕터)
 │     A-2 프로비저닝 훅(_ensure_user_exists)에서 best-effort 호출
 │     A-3 템플릿 PDF를 storage에 1회 업로드 + DEPLOY.md 절차
 │
 ├─ Track C (디자인): 자작 2쪽 데모 PDF + 프롬프트 세트 ── (A·B의 입력)
 │
 └─ Track B (iOS): 온보딩 플로우
        B-0 온보딩 노트 생성(note_id 확보)
        B-1 게이팅(@AppStorage + fullScreenCover)
        B-2 피드백 경로 추출(공유 유틸) + textbook_id=demo-{userId}
        B-3 OnboardingView(PDF+캔버스+코치마크+연출+카드+폴백+건너뛰기)
              │
              ▼
        Track V: 실기기 검증 (A·B·C 완료 후, 필수)
```

**의존성:**
- **API 엔드포인트 변경 없음** → iOS Track B는 기존 `/feedback` 계약으로 바로 개발. *실제 교재 기준 피드백*은 A(딥카피)+C(데모 PDF) 후 — 그 전엔 폴백 예시로 개발.
- B-0→B-1→B-2→B-3 순차(같은 온보딩 영역).
- Track A(backend)·Track B(iOS) **다른 repo** → 병렬. `demo-{user_id}` 규칙만 공유.
- 온보딩 진입의 백스톱 `ensure_demo_textbook` 호출(§4.3-2)은 A-1 배포 후 실효.

**인원별 배분:**
| 인원 | 배분 |
|---|---|
| 1명 | C(데모 제작) → A-1·A-2·A-3 → B-0~B-3 → V. 순차 |
| 2명 | 1명 A+C(backend+데모), 1명 B(iOS). 합류 후 V |

### Track A: Backend (데모 교재 딥카피) — API 엔드포인트 변경 없음
**의존:** A-1/A-3는 Track C의 PDF 필요
**작업량:** 중간. 복잡점: idempotent ensure(결정적 id + storage copy + 2 INSERT), 프로비저닝 핫패스 best-effort 가드

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `backend/app/services/`(신규 `demo_textbook.py` 등) | `ensure_demo_textbook(user_id)` idempotent(id=`demo-{user_id}`, 있으면 no-op, 없으면 storage copy + textbook_sources + chapters INSERT). 내부 retry. 정적 템플릿(PDF key + 챕터 상수) |
| A-2 | `backend/app/core/auth.py:76-84` | `_ensure_user_exists`에서 유저 생성 직후 `ensure_demo_textbook` **best-effort 호출**(try/except — 인증 절대 차단 금지) |
| A-3 | storage + `backend/DEPLOY.md` | 템플릿 PDF를 storage 고정 key로 1회 업로드 + 절차 문서화 |

### Track B: iOS 온보딩
**의존:** API 변경 없음 → 기존 `/feedback` 계약으로 바로 개발. 실교재 피드백은 A+C 후
**작업량:** 중간~큼. 복잡점: OnboardingView의 PDF+캔버스+코치마크+연출 합성, 폴백

| ID | 파일 | 내용 |
|---|---|---|
| B-0 | `Views/OnboardingView.swift`, `DatabaseService` | 온보딩 진입 시 노트 1개 생성(note_id 확보). 완료 처리는 §4.6 |
| B-1 | `ScatchLMApp.swift`, `Config.swift` | `@AppStorage("onboardingCompleted")` + `isAuthenticated && !완료`시 `.fullScreenCover` |
| B-2 | `NoteView.swift:1099-1155` → 신규 유틸 | 스트로크→이미지 렌더 순수 함수 추출(노트·온보딩 공유). 온보딩은 textbook_id=`demo-{세션 userId}` 전송 |
| B-3 | `Views/OnboardingView.swift` (신규) + 번들 PDF | bare PDFView + bare PKCanvasView + 코치마크 + "읽는 중" 연출 + 피드백 카드 + 폴백 + 건너뛰기 |

### Track C: 데모 콘텐츠 (디자인)
**의존:** 없음. A·B-3의 입력
**작업량:** 작음(문안/레이아웃). 텍스트 레이어 PDF로 출력

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | (디자인) 에셋 + 백엔드 템플릿 key | 자작 2쪽 PDF + 페이지↔프롬프트↔기대피드백 세트. 저작권 안전·텍스트 레이어. 앱 번들·백엔드 storage 양쪽 동일 파일 |

### Track V: 실기기 검증 (필수)
PencilKit/PDFKit 기기 종속 — 시뮬/빌드 성공은 동작 확인 아님. 첫 호출 성공/실패(폴백)/건너뛰기/완료 플래그 영속까지.

---

## 6. 확인 완료 사항 (코드 검증)

| # | 확인 | 근거 |
|---|---|---|
| 1 | **note_id 필수** (온보딩은 노트 생성으로 충족, 백엔드 변경 없음) | `feedback.py:48` `note_id: str = Form(...)` |
| 2 | textbook_id/current_page는 optional | `feedback.py:52-53` `str\|None=Form(None)` |
| 3 | 교재 컨텍스트 우선순위 (page범위 → current_page→챕터) | `feedback.py:75-135` |
| 4 | **current_page 주입은 chapters에 의존** | `feedback.py:96-120` 챕터 lookup; 없으면 단일 페이지만 |
| 5 | textbook_context 없으면 일반 피드백(정상) | `feedback_service.py:33-66,198` `has_textbook` 분기 |
| 6 | TextbookSource `user_id` NOT NULL FK | `textbook.py:11` |
| 7 | Chapter 스키마(level/title/page_start/page_end) | `chapter.py:9-22` |
| 8 | storage key 규칙 + s3/local 분기 | `pdf_service.py:30-58`, `storage.py:150-176` |
| 9 | seed 선례(chapters INSERT 패턴) | `scripts/backfill_toc.py` |
| 10 | 앱 루트 인증 분기(온보딩 게이트 지점) | `ScatchLMApp.swift:30-42` |
| 11 | 첫 실행 감지 선례 | `AuthService.swift:64-68` `freshInstallKey` |
| 12 | 피드백 순수 렌더 경로(추출 대상) | `NoteView.swift:1099-1155` |
| 13 | multipart fields 출처 | `NoteView.swift:1173-1190` |
| 14 | postMultipart 시그니처 + AIResponse | `APIClient.swift:116-157`, `AIResponse.swift:3-31` |
| 15 | bare PDFView 최소 구성 | `PdfViewerView.swift:948-959` |
| 16 | Config.responseLanguage/apiBaseURL | `Config.swift:22-33,73-76` |
| 17 | **/feedback이 textbook_id 소유권을 user_id로 검사** (공용 교재 불가 → 유저별 딥카피 필요) | `feedback.py:78-85` `TextbookSource.user_id == user_id` |
| 18 | JIT 프로비저닝 지점(딥카피 best-effort 훅) | `auth.py:76-84` `_ensure_user_exists` (`db.add(user)` 직후) |

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| R1 | 온보딩 노트가 **sync/홈 목록에 어떻게 나타나는지** (첫 노트로 남길 시) + 데모 textbook_id를 노트에 attach 안 해도 피드백 정상인지 | `DatabaseService.createNote`·sync 경로 + 추출한 피드백 호출 검증 |
| R2 | 데모 교재 복사본이 **GET /pdf/textbooks·sync·교재 피커에 어떻게 노출**되는지 (모든 유저가 받음 — 의도됨) | `/pdf/textbooks` 응답 + iOS 교재 목록/sync 확인 |
| R3 | 온보딩 피드백이 **신규 유저 quota를 소모**하는지 / 429 가능성 | quota 집계 로직 확인(`check_daily_quota`). 데모는 quota 면제 필요할 수 있음 |
| R4 | "AI 읽는 중" 연출 + 실 API 지연 체감(수 초)이 첫인상에 OK인지 | 실기기 재현(Track V) |
| R5 | 전체 플로우 동작(필기 인식·PDF 표시·폴백) | 실기기(Track V) |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 온보딩 노트가 sync/홈에 어수선하게 남음(첫 노트로 둘 때) | UX 혼란 | §4.6 처리 결정(연습 노트 명명 or 삭제). 데모 textbook attach 안 함 |
| 첫 `/feedback` 실패(네트워크/429/서버)로 wow 자리 붕괴 | 첫인상 최악 | **준비된 예시 피드백 폴백 필수**(B-3). 타임아웃 짧게 |
| `ensure_demo_textbook` **비idempotent**(중복 row/파일) | 데이터 오염 | 결정적 id `demo-{user_id}` + create-if-not-exists. "둘 다 호출"의 절대 전제 |
| 프로비저닝 훅의 딥카피가 **인증을 차단/지연** | 로그인 브릭 | A-2 **best-effort**(try/except, 비동기 가능). 실패해도 유저 생성·인증은 무조건 성공 |
| 딥카피 실패로 textbook 컨텍스트 없음 | "교재 기준" wow 소실 | 두 지점 호출(프로비저닝+온보딩)+내부 retry. 그래도 없으면 예시 피드백 폴백 |
| chapters 누락 → current_page 주입 실패(단일 페이지만) | 교재 컨텍스트 약화 | ensure_demo_textbook이 chapters 1개 반드시 INSERT(A-1) |
| 데모 PDF가 이미지-only(텍스트 레이어 없음) | 백엔드 챕터 텍스트 추출 0 | C-1에서 텍스트 레이어 PDF 보장 |
| 온보딩이 무거워져 이탈 유발 | 역효과 | 항상 건너뛰기, 플로우 1개·데모 1세트 최소 |
| 실기기 미검증으로 "됐다" 단정 | 낙관 금지 위반 | Track V 전까지 미검증 명시 |

---

## 부록: 관련 문서
- `docs/known-issues.md` — 신규 사용자 이탈(안내 0) 맥락
- `docs/pdf-upload-cloud-materialize-spec.md` — 같은 이탈 사례의 교재 업로드 버그
- `backend/DEPLOY.md` — seed 수동 절차 추가 대상
