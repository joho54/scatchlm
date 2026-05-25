# AI 피드백에 대한 사용자 피드백 수집 Spec

> **Status:** Draft
> **Date:** 2026-05-25
> **Author:** (auto-generated)

---

## 1. Background

### 1.1 운영 이력 / 현재 상태

- 현재 AI 피드백 흐름:
  - iOS가 `POST /api/feedback` 호출 → Claude Vision 응답 수신 → `FeedbackRecord`로 로컬 GRDB에 저장 → `FeedbackCardView`로 노트 캔버스에 카드 렌더 (`backend/app/routers/feedback.py:30-155`, `ios-app/ScatchLM/Models/Note.swift:65-111`, `ios-app/ScatchLM/Views/FeedbackCardView.swift:1-27`).
- **백엔드는 개별 피드백 응답 본문을 저장하지 않는다.** `LLMUsage` 테이블에 호출 메타데이터(모델/토큰/비용/언어/컨텍스트 유무/오류)만 남기고, AI가 실제로 어떤 텍스트를 출력했는지는 기록되지 않는다 (`backend/app/models/usage.py:10-27`).
- 피드백 본문은 iOS 로컬 SQLite에만 존재한다. 따라서 **현재 구조로는 프롬프트 튜닝에 활용할 비정형 지표(비표준 표현, 부적절한 톤, 사용자 불만 등)를 서버 측에서 수집할 수단이 전혀 없다.**
- `FeedbackRecord`에는 평점/사용자 코멘트 컬럼이 없고, `FeedbackCardView`는 표시 전용이라 입력 위젯이 없다.
- 인증은 `get_current_user_id` (Supabase JWT) 의존성으로 통일되어 있다 (`backend/app/core/auth.py:62-82`).

### 1.2 Out of Scope

| 항목 | 이유 |
|---|---|
| 자동 어휘 분류기(LLM-as-judge로 비표준 표현 자동 태깅) | Phase 2. 일단 raw 지표가 쌓여야 분류기 학습/평가 가능 |
| 어드민 대시보드(피드백 검색/필터/통계 UI) | Phase 2. 우선 DB에 적재 후 ad-hoc SQL로 분석 |
| 채팅(`/api/feedback/chat`) 응답에 대한 별도 thumbs | Phase 2. 초기 카드 피드백에만 도입해 UX/스키마 검증 |
| 음성/녹음 형태의 사용자 코멘트 | 초기엔 텍스트만 |
| 자동 재생성("나쁨" 클릭 시 즉시 retry) | UX 결정 후 별도 트랙 |

### 1.3 기존 코드 정리 대상

없음. 신규 컬럼/엔드포인트 추가 위주.

---

## 2. 현재 플로우

```
[iOS NoteView]
  drawingCapture → POST /api/feedback (image, note_id, ...)
                                │
                                ▼
                       feedback_service.get_feedback (Claude)
                                │
                                ▼
                       LLMUsage INSERT (메타데이터만)
                                │
                                ▼
                       FeedbackResponse {type, content, ...}
                                │
                                ▼
[iOS] FeedbackRecord 로컬 저장 → FeedbackCardView 렌더
        ❌ 평가 UI 없음, ❌ 서버 응답 본문 미저장
```

### 2.1 목표 플로우

```
[iOS] FeedbackCardView
  ├─ 👍 / 👎 버튼 (즉시 전송)
  └─ "자세히 알려주기" → 코멘트 시트 (사유 태그 + 자유 텍스트)
                                │
                                ▼
                       POST /api/feedback/{feedback_id}/rate
                                │
                                ▼
                       ai_feedback_record + ai_feedback_rating UPSERT
                                │
                                ▼
                       [BE] 분석용 raw 데이터 적재
```

`feedback_id`는 **백엔드가 `/api/feedback` 응답에서 부여**하고 iOS는 로컬 FeedbackRecord에 이를 저장한다 (현재는 iOS가 UUID 생성).

---

## 3. Backend API Inventory

| Method | Path | 설명 | 상태 |
|---|---|---|---|
| POST | `/api/feedback` | 손글씨 → AI 피드백 | 기존, **응답에 `feedback_id` 추가 필요** |
| POST | `/api/feedback/chat` | 후속 채팅 | 기존, 변경 없음 (Phase 2 평가 도입) |
| POST | `/api/feedback/{feedback_id}/rate` | thumbs + 코멘트 제출 | **신규** |
| PATCH | `/api/feedback/{feedback_id}/rate` | 평가 수정 (선택, UPSERT로 합칠 수 있음) | **신규(선택)** |

### 3.1 신규 엔드포인트 스펙

`POST /api/feedback/{feedback_id}/rate`

요청:
```json
{
  "rating": -1 | 1,                  // -1: 👎, 1: 👍
  "reason_tags": ["wrong_language", "tone_off", "factually_wrong", "unhelpful", "other"],
  "comment": "string (optional, <= 2000자)",
  "client_ts": "2026-05-25T12:34:56Z"
}
```

응답: `204 No Content` (또는 `{ "id": "..." }`).

권한: `get_current_user_id`로 본인 소유 피드백만 평가 가능.

---

## 4. 데이터 모델 설계

### 4.1 Backend (Postgres)

**신규 테이블 1: `ai_feedback_record`**

| 컬럼 | 타입 | 비고 |
|---|---|---|
| `id` | uuid PK | 서버 발급. `/api/feedback` 응답으로 내려보냄 |
| `user_id` | string, index | |
| `note_id` | string, index | iOS가 보낸 값 그대로 (로컬 ID — FK 아님) |
| `task_type` | string | `complex` / `simple` |
| `language` | string | 입력 언어 |
| `response_language` | string | 응답 언어 |
| `model` | string | 실제 호출된 모델 |
| `textbook_id` | uuid? | nullable |
| `current_page` | int? | nullable |
| `has_textbook_context` | bool | |
| `prompt_context_snippet` | text? | RAG/챕터 컨텍스트의 앞 N자(예: 2000) — 풀텍스트는 비용 |
| `previous_context` | text? | 클라이언트가 보낸 prev 컨텍스트 그대로 |
| `response_content` | text | AI 응답 본문 (FeedbackResponse.content) |
| `request_id` | string? | 추적용 |
| `created_at` | timestamp | |

- 이미지는 저장하지 않는다(용량/프라이버시). 필요해지면 Phase 2에서 S3 키만 추가.
- `llm_usage`와는 별도. `llm_usage.id`를 FK로 묶고 싶다면 `usage_id` 컬럼 추가 검토(선택).

**신규 테이블 2: `ai_feedback_rating`**

| 컬럼 | 타입 | 비고 |
|---|---|---|
| `id` | uuid PK | |
| `feedback_id` | uuid FK → `ai_feedback_record.id`, **unique** | 1:1 (재평가는 update) |
| `user_id` | string, index | |
| `rating` | smallint | -1 / 1 |
| `reason_tags` | text[] | Postgres 배열 |
| `comment` | text? | nullable |
| `client_ts` | timestamp? | 클라이언트 시각 |
| `created_at` | timestamp | |
| `updated_at` | timestamp | |

### 4.2 iOS (GRDB)

**`FeedbackRecord` 확장** (`Models/Note.swift`):
- `serverFeedbackId: String?` — `/api/feedback` 응답에서 받은 ID
- `userRating: Int?` — -1 / 1 / nil
- `userRatingSyncedAt: Date?` — 서버 전송 성공 시각 (실패 시 재시도 큐 판단용)

**마이그레이션 `v5_feedback_user_rating`** (`DatabaseService.swift`):
- 위 3개 컬럼 추가.

---

## 5. 구현 단계 (Tracks)

```
                ┌── Track A: Backend 스키마 + API (블로커)
                │
시작 ──────────┤
                │
                ├── Track B: iOS 데이터 모델/저장 (A의 응답 스키마에 의존)
                │            └── B 완료 후 ──> Track D
                │
                ├── Track C: iOS UI (Track B와 병렬 가능, mock 응답으로 진행)
                │
                └── Track D: 통합/E2E 검증 (A + B + C 완료 후)
```

**트랙 간 의존성:**
- Track A의 응답 스키마 (`feedback_id` 추가)가 정해져야 Track B/C가 안전하게 통합된다. → A의 §5-A-1만 먼저 PR 가능.
- Track C는 mock 데이터로 단독 진행 가능 (실제 API 연결만 D에서 합본).

**인원별 배분:**

| 인원 | 추천 배분 |
|---|---|
| 1명 | A → B → C → D 순차 |
| 2명 | P1: A + D / P2: B + C |
| 3명 | P1: A / P2: B / P3: C, D는 합류해서 분담 |
| 4명 | P1: A / P2: B / P3: C / P4: D + 분석 SQL 준비 |

---

### Track A: Backend 스키마 + API
**의존:** 없음
**내부 순서:** A-1 → A-2 → A-3 (모델 → 마이그 → 라우터)
**작업량:** 중간. 가장 복잡한 부분은 `/api/feedback` 응답에 `feedback_id`를 추가하면서 기존 호출자(iOS 구버전 포함)를 깨뜨리지 않게 옵셔널 필드로 합치는 것.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `backend/app/models/feedback.py` (신규) | `AIFeedbackRecord`, `AIFeedbackRating` SQLAlchemy 모델 |
| A-2 | `backend/alembic/versions/{rev}_ai_feedback_rating.py` | `ai_feedback_record`, `ai_feedback_rating` 테이블 + FK/unique index 마이그레이션. `alembic revision --autogenerate -m "ai feedback rating"` |
| A-3 | `backend/app/routers/feedback.py` | `/api/feedback` 핸들러에서 `AIFeedbackRecord` insert → `FeedbackResponse`에 `feedback_id` 추가 |
| A-4 | `backend/app/routers/feedback.py` | `POST /api/feedback/{feedback_id}/rate` 라우트 추가 (소유권 검증, UPSERT) |
| A-5 | `backend/tests/unit/test_feedback_rating.py` (신규) | 평가 생성/재평가(UPSERT)/타인 평가 거절/존재하지 않는 feedback_id 케이스 |
| A-6 | `backend/app/routers/feedback.py` | `previous_context`/`prompt_context_snippet` 저장 시 길이 truncate(예: 2000자) 로직 |

---

### Track B: iOS 데이터 모델 + API 클라이언트
**의존:** Track A의 `feedback_id` 응답 스키마 확정 후 (A-1, A-3까지면 충분)
**내부 순서:** B-1 → B-2 → B-3
**작업량:** 작음~중간. 핵심은 GRDB 마이그레이션과 재시도 큐(오프라인 대응).

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `ios-app/ScatchLM/Models/Note.swift` | `FeedbackRecord`에 `serverFeedbackId`, `userRating`, `userRatingSyncedAt` 추가 + CodingKeys 매핑 |
| B-2 | `ios-app/ScatchLM/Services/DatabaseService.swift` | `v5_feedback_user_rating` 마이그레이션 등록 (기존 v1~v4 마이그레이션은 절대 수정 금지). save/update 메서드 시그니처 갱신 |
| B-3 | `ios-app/ScatchLM/Services/APIClient.swift` | `postFeedbackRating(feedbackId:rating:reasonTags:comment:)` 메서드 추가 |
| B-4 | `ios-app/ScatchLM/Models/AIResponse.swift` 또는 신규 응답 모델 | `/api/feedback` 응답 디코딩에 `feedback_id` 추가 |
| B-5 | `ios-app/ScatchLM/Views/NoteView.swift` | `appendFeedbackCard` 부근에서 응답의 `feedback_id`를 FeedbackRecord에 저장하도록 수정 |
| B-6 | `ios-app/ScatchLMTests/DatabaseServiceTests.swift` | v5 마이그레이션 후 평가 컬럼 저장/조회 테스트 |

---

### Track C: iOS UI (평가 위젯)
**의존:** Track B와 독립 (mock으로 진행 가능). 실제 연결은 D에서.
**내부 순서:** C-1 → C-2 → C-3 병렬
**작업량:** 중간. 가장 복잡한 부분은 `FeedbackCardView`가 현재 표시 전용 구조라 카드 크기/배치(`bboxWidth`)와 충돌하지 않게 위젯을 끼워넣는 것.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `ios-app/ScatchLM/Views/FeedbackCardView.swift` | 카드 하단에 thumbs up/down 버튼 + "자세히 알려주기" 링크 추가. 선택 상태 시각화 |
| C-2 | `ios-app/ScatchLM/Views/FeedbackRatingSheet.swift` (신규) | 사유 태그 칩(다중 선택) + 자유 텍스트 필드 + 제출 버튼. SwiftUI sheet |
| C-3 | `ios-app/ScatchLM/Views/NoteView.swift` | thumbs 클릭/시트 제출 시 viewModel → APIClient.postFeedbackRating 호출 + 로컬 FeedbackRecord 업데이트 |
| C-4 | `ios-app/ScatchLM/Services/LogService.swift` 활용 | `appLog("rating", ...)`로 클릭 이벤트 로깅 (서버 도달 전 클릭 비율 확인용) |

**사유 태그(C-2 초안):** `wrong_language` / `tone_off` / `factually_wrong` / `too_long` / `too_short` / `unhelpful` / `other`. 카피는 한국어로.

---

### Track D: 통합/검증
**의존:** A + B + C 완료
**내부 순서:** D-1 → D-2 → D-3
**작업량:** 작음.

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | (수동) | iPad 실기기 빌드 후 피드백 받기 → 👍/👎 → DB 적재 확인 (`backend/logs/uvicorn.log` + Postgres `select * from ai_feedback_rating`) |
| D-2 | `backend/tests/unit/` | `/api/feedback` 응답에 `feedback_id` 포함되는지 회귀 테스트 |
| D-3 | `docs/user-feedback-analysis.md` (선택) | 운영자가 돌릴 분석 쿼리 모음(부정 비율, 사유 태그 분포, 비교 시점별 추이) |

---

## 6. 확인 완료 사항 (코드 검증)

- **백엔드에 피드백 본문 저장이 없다**: `backend/app/routers/feedback.py:140-152`는 `LLMUsage`만 insert하고 응답 본문은 폐기. `FeedbackResponse` 스키마 (`feedback.py:21-27`)에 식별자 필드 없음.
- **인증 패턴**: `get_current_user_id` (`backend/app/core/auth.py:62-82`)는 Supabase JWT의 `sub`를 사용하고, 신규 라우터에서도 동일하게 `Depends(get_current_user_id)`로 통일하면 됨. user 자동 생성도 자동 처리됨.
- **iOS FeedbackRecord 스키마**: `ios-app/ScatchLM/Models/Note.swift:65-111`. 현재 평가 컬럼 없음. CodingKeys로 snake_case 매핑하는 패턴 따름.
- **iOS GRDB 마이그레이션 패턴**: `ios-app/ScatchLM/Services/DatabaseService.swift:26-124`. v1~v4가 누적 등록되어 있고 v5를 새로 등록하는 방식 (CLAUDE.md §"iOS DB 마이그레이션"과 일치).
- **iOS 피드백 카드 컴포넌트**: `ios-app/ScatchLM/Views/FeedbackCardView.swift:1-27`. 현재 본문만 렌더. `bboxWidth`로 캔버스 좌표 고정 — 위젯 추가 시 높이만 증가하고 폭은 유지하도록 설계 필요.
- **API 클라이언트**: `ios-app/ScatchLM/Services/APIClient.swift`에 `postMultipart` 등 존재. JSON POST 헬퍼가 있으면 재사용, 없으면 추가.
- **Alembic 베이스라인**: `backend/alembic/versions/fff3137aa9b9_initial_schema.py` 단일 — 신규 마이그레이션은 이로부터 분기 ([[project_alembic_baseline]] 참고).

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | `APIClient.swift`에 JSON POST 헬퍼가 이미 있는지 (multipart만 확인됨) | `grep -n "func post" ios-app/ScatchLM/Services/APIClient.swift` |
| 2 | `/api/feedback/chat` 응답에도 식별자를 부여해야 하는지(Phase 2 범위) | Phase 2 결정 시점에 재논의 |
| 3 | `ai_feedback_record.user_id`와 `users` 테이블 FK 강제 여부 | 기존 `LLMUsage`는 FK 없이 string. 동일 정책 추천 |
| 4 | 평가 사유 태그 enum을 DB 레벨로 강제할지 (현재는 text[]) | 초기엔 free-form, Phase 2에서 정규화 검토 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| `/api/feedback` 응답 스키마 변경으로 구버전 iOS 깨짐 | 중 | `feedback_id`를 옵셔널 필드로 추가. 기존 필드 유지. 구버전은 평가 기능만 빠짐 |
| 사용자 코멘트에 PII 포함 가능 | 중 | (a) iOS 시트 가이드 문구로 PII 자제 요청 (b) 분석 시 마스킹 도구 분리 |
| 카드 UI에 위젯 추가하면서 캔버스 좌표 깨짐 | 중 | `bboxWidth/Height`는 그대로, 위젯은 카드 내부 하단 — 외부 좌표 재계산 금지. 회귀 테스트(`PencilKitCanvasViewTests`) |
| 오프라인 상태에서 평가 클릭 → 유실 | 낮 | `userRatingSyncedAt` nil이면 앱 재시작/네트워크 복귀 시 재전송 (Phase 1.5에 큐 도입) |
| `prompt_context_snippet` 저장이 DB 비대화 | 중 | 길이 cap(2000자) + 90일 후 익명화/삭제 정책 별도 수립 |
| iOS GRDB 기존 마이그레이션 수정 사고 | 높 | v5 신규 등록만, v1~v4 절대 수정 금지 (CLAUDE.md 명시) |
