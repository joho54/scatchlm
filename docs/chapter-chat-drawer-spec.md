# 챕터 채팅 서랍(Chat Drawer): 캔버스 종속 채팅 → 캔버스 비종속 세션

> **Status:** Draft
> **Date:** 2026-06-06
> **Author:** (auto-generated)

---

## 1. Background

### 1.1 현재 상태

채팅이 두 종류이고, **저장 위치가 근본적으로 비대칭**이다.

| | 페이지/챕터 가이드 채팅 | 피드백 채팅 |
|---|---|---|
| 저장 | **없음** (`@State`, 시트 닫으면 `= []`로 소멸) | GRDB `feedback_chats` 테이블 |
| 캔버스 종속성 | 없음 (PDF 뷰어 안에서만 떠다님) | **강하게 종속** — `feedback_chats.feedback_id → feedbacks.id`. 채팅은 *캔버스에 박힌 카드*에 매달려서만 존재 |
| 위치 | 없음 | `feedbacks`의 `page_id` + `position_y` + `stroke_range_start/end` |
| Sync | 안 됨 (애초에 영속화 안 됨) | 됨 (`SyncChatDTO`, key=`feedback_id`) |

구현 위치:
- 가이드 채팅(ephemeral): `PdfViewerView.swift:200-643` — `guideChatMessages`/`chapterChatMessages` `@State`, 시트 dismiss 시 `= []` (line 371, 554). 전송 `sendGuideChat()` (390-443) / `sendChapterChat()` (591-643).
- 피드백 채팅(영속): `FeedbackChatSheet.swift` 전체. `ChatMessageRecord`(`Note.swift:329-397`), CRUD `DatabaseService.swift:588-611`.
- 스크랩(저장=배치 결합): `NoteView.swift` `appendFeedbackCard()` (659-737), `pasteFromClipboard()` (744-751). 카드는 `FeedbackRecord` 1개 = 캔버스 위치 확정.

### 1.2 문제 (이 작업의 동기)

현재 **"채팅 저장 = 캔버스에 위치 확정"** 이 한 동작으로 묶여 있다. 그래서:
- 가이드 채팅은 캔버스에 박지 않으면 사라지고(휘발성), 박자니 위치가 마음에 안 든다.
- 피드백 채팅은 저장되지만 *채팅만 모아 보는 곳*이 없고, 챕터 단위로 묶이지 않는다.

이 작업은 **저장(드로어 입주)** 과 **배치(캔버스 스크랩)** 를 분리한다. 채팅을 캔버스에서 독립시킨 `chat_session` 엔티티를 도입하고, 피드백 카드는 *세션을 캔버스에 배치한 뷰*로 재정의한다 (통합형 정공법).

### 1.3 결정 사항 (사용자 확정)

1. **데이터 모델: 통합형.** 캔버스 비종속 `chat_session` 도입. 피드백 채팅도 세션의 한 종류(`kind=feedback`)로 흡수. 피드백 카드(`FeedbackRecord`)는 세션을 가리키는 placement가 된다.
2. **세션 제목 = 사용자가 던진 첫 질문 텍스트.** (가이드 채팅의 "챕터 N 요약"류 동일 제목 문제 해소.)
3. **스코프 전부:** ① 가이드 채팅 영속화 ② 피드백 채팅도 드로어에 챕터별 모아보기 + 선택 시 캔버스 위치로 점프 ③ 드로어→캔버스 재스크랩(저장·배치 분리) ④ 드로어 안에서 세션 열어 대화 이어가기.
4. **챕터 귀속:** `textbook_id` + 세션의 `anchor_page`로 보관하고, 표시 시점에 backend `chapters`(`page_start`/`page_end`)로 page→챕터 매핑을 계산. 챕터 식별은 page 기준(재업로드로 `chapter_id`가 바뀌어도 견고하게).

### 1.4 Out of Scope

| 항목 | 이유 |
|---|---|
| 서버 `/feedback/chat` 응답 형태 변경 | 채팅은 stateless. 세션은 클라이언트+sync 레이어에서만 구성. 엔드포인트 무변경 |
| 세션 LLM 자동 요약 제목 | 사용자가 "첫 질문 사용" 선택. 추후 옵션 |
| 한 세션의 다중 캔버스 동시 배치 UI | 데이터는 허용(1 session → N cards)하되, v1 UI는 1회 배치 흐름만 |
| 서버 측 세션 검색/분석 화면 | 운영 분석은 별개. 본 작업은 클라이언트 UX |

---

## 2. 현재 vs TOBE 데이터 흐름

### 2.1 현재

```
가이드 채팅:  PdfViewerView @State ──(시트 닫힘)──> 소멸
                    │
                    └─ POST /feedback/chat (history는 메모리에서만)

피드백 채팅:  feedbacks(카드,위치) ──1:N──> feedback_chats(메시지)
                    │                              │
              캔버스 위치 확정                 POST /feedback/chat + GRDB 저장 + sync
```

### 2.2 TOBE

```
              chat_session (캔버스 비종속, 챕터 귀속)
              ├ kind: page_guide | chapter_guide | feedback
              ├ title: 첫 사용자 질문
              ├ textbook_id + anchor_page  ──(표시 시)──> chapters(page_start..end)로 챕터 계산
              │
              ├──1:N──> chat_message (메시지; 기존 feedback_chats 흡수)
              │
              └──1:N──> feedbacks (placement; session을 캔버스에 배치한 뷰. nullable session_id)
                              │
                        page_id + position_y  ──> 드로어에서 "캔버스로 점프"

드로어(ChapterDrawerView): 챕터별 세션 리스트
   ├ 세션 열기 → 대화 이어가기(메시지 추가)
   ├ 캔버스로 점프 (placement 있으면)
   └ 캔버스로 재스크랩 (placement 신규 생성 = 저장과 분리된 배치)
```

---

## 3. API / 계약 Inventory

### 3.1 백엔드 엔드포인트

| Method | Path | 설명 | 상태 |
|---|---|---|---|
| POST | `/api/feedback/chat` | 채팅 turn (stateless) | **변경없음** |
| GET | `/api/pdf/{id}/chapters` | 챕터 목록 (page→챕터 계산용) | **변경없음** |
| GET | `/api/pdf/{id}/guide`, `/chapter-guide` | 가이드 본문 | **변경없음** |
| POST | `/sync/push`, `/sync/pull` | 로컬-퍼스트 sync | **변경** (§3.2-a) |
| POST/GET | `/sync/blob` | drawing blob | 변경없음 |

**핵심:** `/feedback/chat`은 그대로다. 세션은 클라이언트가 구성하고 sync로 멀티디바이스 보존만 한다. 따라서 백엔드 작업은 **sync 레이어 한정**.

### 3.2 동결 계약 — Sync 스키마 변경

이 계약이 iOS(Track A/E) ↔ 서버(Track F) 병렬의 인터페이스다.

```
### 3.2-a Sync: chat_session 신규 테이블 + chat_message 키 이전

신규 DTO — SyncSessionDTO (push/pull 양방향):
  id: str (uuid)
  updated_at: datetime (LWW)
  deleted: bool
  kind: str  ∈ {"page_guide","chapter_guide","feedback"}
  title: str
  note_id: str | null          # 세션이 생성된 노트 (가이드는 null 가능)
  textbook_id: str | null
  anchor_page: int | null      # 페이지→챕터 계산 기준 (1-based, 가이드/피드백 모두)
  chapter_title: str | null    # 표시용 스냅샷 (교재 미로드 시 폴백)
  source_feedback_id: str | null  # feedback 세션의 원본 AIResponse id (rating 연계)
  created_at: datetime

변경 DTO — SyncChatDTO:
  - 추가:  session_id: str            # 신규 FK (필수)
  - 유지:  feedback_id: str | null    # 레거시. 마이그레이션 후 null 가능, 하위호환 위해 유지
  - 나머지(role/content/server_message_id/user_rating/created_at/updated_at/deleted) 동일

변경 DTO — SyncFeedbackDTO:
  - 추가:  session_id: str | null     # placement가 가리키는 세션 (없으면 레거시 단독 카드)
  - 나머지 동일

Sync 프로토콜:
  - push: SyncChanges에 sessions: [SyncSessionDTO] 배열 추가
  - pull: SyncPullResponse에 sessions 페이지 추가 (cursor 기반, 기존과 동일 LWW)
  - 서버는 chat_session 테이블 신설(컬럼 = DTO 필드 + user_id). chat_message/feedback에 컬럼 추가.
  - 적용 순서(참조 무결성): pull 시 sessions를 chat_message보다 먼저 apply. push 동일.

에러: 기존 sync 에러(missing_blob 등) 그대로. 세션은 blob 없음.
예시 payload(push):
  {"sessions":[{"id":"a1","updated_at":"2026-06-06T01:00:00Z","deleted":false,
    "kind":"chapter_guide","title":"이 챕터에서 제일 중요한 게 뭐야?","note_id":null,
    "textbook_id":"tb_9","anchor_page":42,"chapter_title":"3장 동사 변화",
    "source_feedback_id":null,"created_at":"2026-06-06T01:00:00Z"}],
   "chat_messages":[{"id":"m1","session_id":"a1","feedback_id":null,"role":"user",
    "content":"이 챕터에서 제일 중요한 게 뭐야?", ...}]}
  빈 케이스: {"sessions":[], ...} → 정상.
```

---

## 4. 구현 설계

### 4.1 iOS 데이터 모델 (GRDB, Track A)

**신규 `chat_session` 테이블 / `ChatSessionRecord`** (`Note.swift` 신규):

| 컬럼 | 타입 | 비고 |
|---|---|---|
| id | TEXT PK | uuid |
| kind | TEXT | `page_guide`/`chapter_guide`/`feedback` |
| title | TEXT | 첫 사용자 질문 (피드백 세션은 §4.5 폴백) |
| note_id | TEXT? | FK notes (가이드는 null 허용) |
| textbook_id | TEXT? | |
| anchor_page | INT? | page→챕터 계산 기준 (1-based) |
| chapter_title | TEXT? | 표시용 스냅샷 |
| source_feedback_id | TEXT? | feedback 세션 원본 AIResponse id |
| created_at, updated_at | DATETIME | |
| user_id, deleted, dirty | (v7 sync 메타 동일) | |

**`ChatMessageRecord` 변경** (`Note.swift:329-397`):
- `session_id: String` 추가 (신규 FK, 필수).
- `feedback_id: String?` → nullable 로 완화 (레거시 유지).

**`FeedbackRecord` 변경** (`Note.swift:129-239`):
- `session_id: String?` 추가 (placement→세션. 레거시 단독 카드는 null).

**마이그레이션 `v8_chat_sessions`** (`DatabaseService.swift`, v7 다음):
1. `chat_session` 테이블 생성 (sync 메타 포함).
2. `feedback_chats`에 `session_id TEXT` 추가, `feedbacks`에 `session_id TEXT` 추가.
3. **백필:** 기존 `feedback_chats`를 `feedback_id`로 그룹핑 → 그룹마다 `chat_session`(kind=feedback) 1개 생성. 세션 `title`=해당 그룹 첫 `role='user'` 메시지 content(없으면 부모 `feedbacks.content` 요약/"피드백 대화"). `source_feedback_id`=부모 `feedbacks.server_feedback_id`. `note_id`=부모 `feedbacks.note_id`. `anchor_page`=부모 카드의 페이지→(노트의 `textbook_id`+페이지) 매핑은 챕터 정보 없이 알 수 없으므로 **null 허용**(드로어에서 "교재 없음"/"기타"로 분류). 그 후 메시지의 `session_id`를 채우고, 부모 `feedbacks.session_id`도 신규 세션으로 연결.
4. 신규 세션·갱신 행 `dirty=1`로 두어 다음 sync에 push (멀티디바이스 일관성). **주의:** 같은 백필이 디바이스마다 독립 실행되면 세션 중복 생성 위험 → §7 Risk R1.

> GRDB 규칙: v7 안에 끼워넣지 말고 **새 `registerMigration("v8_chat_sessions")`** 로 추가 (`DatabaseService.swift` migrate()). 이미 실행된 마이그레이션은 스킵됨.

### 4.2 챕터 귀속 계산 (Track A 헬퍼)

iOS에는 챕터 로컬 테이블이 없다(`PdfViewerView`가 `@State chapters: [ChapterItem]`로 휘발 보관, `AIResponse.swift:82-88`). 드로어가 챕터별로 묶으려면 챕터 목록이 필요하므로:
- 드로어 진입 시 교재별 `GET /pdf/{id}/chapters` 호출 → 세션의 `anchor_page`를 `pageStart..pageEnd`에 매칭해 그룹핑.
- 헬퍼 `func chapter(for page: Int, in chapters: [ChapterItem]) -> ChapterItem?` (가장 좁은 level≥1 매칭). 교재 미로드/매칭 실패 시 `chapter_title` 스냅샷 또는 "기타".

### 4.3 드로어 UI (Track B)

신규 `ChapterDrawerView.swift`:
- 입력: 현재 노트의 `textbook_id`(및 연결 교재 전체). 진입점은 PDF 뷰어 또는 노트 툴바(§6.x 미확인 — 진입 위치 확정 필요).
- 구조: 교재 → 챕터 섹션 → 세션 행(제목, kind 배지, 최근 시각, placement 유무 아이콘).
- 세션 행 액션:
  - **열기** → 세션 상세(메시지 리스트 + 입력창). 기존 `FeedbackChatSheet`를 세션 기반으로 일반화하여 재사용(§4.4).
  - **캔버스로 점프** (placement 존재 시) → 해당 `feedbacks.session_id` 행의 `page_id`/`position_y`로 노트 이동·스크롤.
  - **캔버스로 스크랩** → 현재 노트 페이지에 placement 신규 생성(§4.5).

### 4.4 세션 채팅 뷰 일반화 (Track D)

`FeedbackChatSheet.swift`를 `feedbackId` 종속에서 `sessionId` 종속으로 일반화:
- 메시지 로드: `db.chatMessages(feedbackId:)` → `db.messages(sessionId:)`.
- 전송: 기존 `sendMessage()` 흐름 유지(`POST /feedback/chat`, history는 세션 메시지에서 구성), 저장 시 `session_id` 채움.
- **세션 첫 메시지 전송 시 `title` 미설정이면 그 user content로 세팅** (결정 2).
- 드로어/카드/PDF 뷰어 모두 같은 뷰로 진입.

### 4.5 스크랩 = placement (저장·배치 분리, Track D)

- `appendFeedbackCard()`(`NoteView.swift:659-737`)를 "세션을 배치"로 재정의: `FeedbackRecord` 생성 시 `session_id` 채움(기존 위치/stroke range 로직 유지).
- 가이드/드로어에서 "스크랩" = 세션은 그대로 두고 placement(`FeedbackRecord`)만 신규 생성. 같은 세션을 다른 페이지에 또 배치 가능(1 session→N cards).
- 기존 "복사→길게눌러 붙여넣기"(commit f0e85eb) 경로는 세션 없는 단독 텍스트 카드로 유지 가능(하위호환), 또는 세션 생성으로 통일(§6.x 결정 필요).
- 카드 "대화" 버튼 → 카드의 `session_id` 세션 채팅 열기.

### 4.6 가이드 채팅 영속화 (Track C)

`PdfViewerView`의 가이드/챕터 채팅:
- 사용자가 첫 메시지를 보내는 순간 `chat_session`(kind=page_guide|chapter_guide, `textbook_id`, `anchor_page`=현재 페이지|챕터 시작 페이지, `chapter_title` 스냅샷, `title`=첫 질문) 생성.
- 이후 메시지를 세션에 영속화. 시트 닫혀도 소멸하지 않음(기존 `= []` 클리어 제거 또는 세션 detach).
- 가이드 본문(첫 assistant 컨텍스트)은 §6.x: 세션 메시지로 저장할지(이어가기 시 컨텍스트 복원) vs 매번 재요청할지 결정 필요.

---

## 5. 구현 단계 (Tracks)

```
                  ┌─ Track F: 백엔드 sync (chat_session/DTO)  ─┐ (계약 §3.2-a 동결됨 → A와 병렬)
                  │
시작 ─ Track A: iOS 데이터 레이어(모델/v8/CRUD/챕터헬퍼) ─┬─ Track B: 드로어 UI
       (블로커)                                          ├─ Track C: 가이드 채팅 영속화
                                                         └─ Track D: 세션 채팅 일반화 + 스크랩/점프
                                                              (B/C/D는 A 완료 후, 서로 다른 파일 → 병렬)
       Track E: iOS sync 연동(SyncService/DTO/+Sync) ── A의 스키마 확정 후, F와 계약으로 병렬
```

**트랙 간 의존성:**
- **Track A가 전체 블로커** (모델/스키마 확정). A의 GRDB 스키마 = §3.2-a 계약과 1:1.
- 계약 §3.2-a 동결 후 **F(서버)와 E(iOS sync)는 병렬**. F 미완이어도 E는 로컬 작동(sync는 백그라운드).
- B/C/D는 A 완료 후 병렬(파일 분리: `ChapterDrawerView.swift` / `PdfViewerView.swift` / `FeedbackChatSheet.swift`+`NoteView.swift`). D는 `NoteView.swift`/`FeedbackChatSheet.swift` 둘 다 만지므로 한 트랙으로 묶음.

**인원별 배분:**
| 인원 | 추천 |
|---|---|
| 1명 | A → F → E → C → D → B 순차 |
| 2명 | P1: A→E→D / P2: F→C→B (A 완료 후 P2 합류) |
| 3명 | P1: A→D / P2: F→E / P3: A 후 C→B |
| 4명 | P1: A(블로커) / P2: F / 이후 P1:D, P2:E, P3:C, P4:B |

### Track A: iOS 데이터 레이어
**의존:** 없음 (블로커)
**내부 순서:** A-1 → A-2 → A-3 (순차)
**작업량:** 중간. 가장 복잡: v8 백필(기존 feedback_chats→session 그룹핑) + sync 중복 회피.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `Models/Note.swift` | `ChatSessionRecord` 신규; `ChatMessageRecord`에 `session_id`/`feedback_id` nullable화; `FeedbackRecord`에 `session_id?` |
| A-2 | `Services/DatabaseService.swift` | `registerMigration("v8_chat_sessions")`: 테이블+컬럼+백필. CRUD: `sessions(textbookId:)`/`messages(sessionId:)`/`saveSession`/`saveMessage`(session_id)/`placement(sessionId:)` |
| A-3 | `Services/DatabaseService.swift` | 챕터 헬퍼 `chapter(for:in:)`; 세션 제목 세팅 헬퍼 |

### Track B: 드로어 UI
**의존:** A 완료 후
**작업량:** 중간. 가장 복잡: 챕터 그룹핑(교재별 chapters fetch + anchor_page 매칭) + 점프 네비게이션.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `Views/ChapterDrawerView.swift` (신규) | 교재→챕터→세션 리스트, kind 배지, placement 아이콘 |
| B-2 | `Views/ChapterDrawerView.swift` + 진입점 | 열기/점프/스크랩 액션 와이어링 |
| B-3 | 진입점 뷰(§6.x) | 드로어 진입 버튼 배치 |

### Track C: 가이드 채팅 영속화
**의존:** A 완료 후
**작업량:** 중간.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `Views/PdfViewerView.swift` | `sendGuideChat`/`sendChapterChat`: 첫 메시지에 세션 생성, 메시지 영속화 |
| C-2 | `Views/PdfViewerView.swift` | 시트 dismiss 시 `= []` 클리어 제거(line 371,554), 세션 재진입 시 메시지 로드 |

### Track D: 세션 채팅 일반화 + 스크랩/점프
**의존:** A 완료 후
**작업량:** 큼. 가장 복잡: `appendFeedbackCard` placement 재정의 + 점프 네비게이션 + 카드↔세션 연결.

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `Views/FeedbackChatSheet.swift` | `feedbackId`→`sessionId` 일반화, 로드/저장/제목 세팅 |
| D-2 | `Views/NoteView.swift` | `appendFeedbackCard`/`pasteFromClipboard`에 `session_id`; "대화" 버튼이 세션 채팅 열기 |
| D-3 | `Views/NoteView.swift` | 드로어→캔버스 스크랩(placement 신규) + 캔버스로 점프(page_id/position_y 스크롤) |

### Track E: iOS sync 연동
**의존:** A 스키마 확정 후 (F와 계약 병렬)
**작업량:** 중간.

| ID | 파일 | 내용 |
|---|---|---|
| E-1 | `Services/SyncModels.swift` | `SyncSessionDTO` 신규, `SyncChatDTO`/`SyncFeedbackDTO`에 session_id |
| E-2 | `Services/DatabaseService+Sync.swift` | `dirtySessions()`/`applyPulledSession()`, 적용 순서(session 먼저) |
| E-3 | `Services/SyncService.swift` | `chat_session` 테이블 push/pull 루프 등록, `tableForEntity` 매핑 |

### Track F: 백엔드 sync
**의존:** 계약 §3.2-a 동결 후 (A/E와 병렬)
**작업량:** 중간. 가장 복잡: 마이그레이션 + 참조 무결성 적용 순서.

| ID | 파일 | 내용 |
|---|---|---|
| F-1 | `backend/app/models/` | `ChatSession` 모델 신규; chat/feedback sync 모델에 session_id |
| F-2 | alembic | `chat_session` 테이블 + 컬럼 추가 마이그레이션 (`alembic revision --autogenerate`) |
| F-3 | `backend/app/routers/` sync | push/pull에 sessions 배열, LWW, session→message 적용 순서 |

---

## 6. 확인 완료 사항 (코드 검증)

- `/feedback/chat` **stateless** — `ChatRequest`(`feedback.py:251-259`)는 `history`를 클라이언트가 매번 전달. 세션 도입에 엔드포인트 변경 불필요. 서버는 turn마다 `AIResponse`(task_type="chat") 기록(`feedback.py:410-426`)하지만 그룹핑/세션 개념 없음.
- **서버에 세션 엔티티 없음** — `app/models/`에 `AIResponse`/`AIResponseRating`만(`feedback.py:16-50`). 세션은 신규.
- **Sync는 제네릭 dirty-flag** — `SyncService.swift:201-207`가 notes/note_pages/feedbacks/feedback_chats 4테이블 루프. 새 테이블 추가 레시피: 모델→migration→DTO→`SyncChanges`→`dirtyXxx`/`applyPulledXxx`→`tableForEntity` 매핑(`SyncService.swift:292-297`). → Track E/F가 이 레시피를 따름.
- **LWW** — `DatabaseService+Sync.swift:72-76` `shouldApply`가 `incoming.updated_at > local`. 세션도 동일 패턴 적용.
- **ChatMessageRecord는 `feedback_id` FK** (`Note.swift:329-397`, `SyncChatDTO` `SyncModels.swift:55-65`) — 통합 시 이 키를 `session_id`로 이전하므로 DTO/서버까지 번짐. → §3.2-a, Track E/F.
- **챕터는 iOS 로컬 미보관** — `PdfViewerView` `@State chapters` 휘발(`AIResponse.swift:82-88` `ChapterItem`: id/level/title/pageStart/pageEnd). page→챕터는 `pageStart..pageEnd` 매칭으로 계산(`pdf.py:463-494`).
- **GRDB 최신 마이그레이션 v7_sync_metadata** (`DatabaseService.swift:176`) — v8로 추가.

### 6.x 미확인 항목
| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | 드로어 진입점 위치 (PDF 뷰어 툴바 vs 노트 툴바 vs 별도 탭) | 사용자 UX 결정 |
| 2 | 가이드 본문(첫 assistant 컨텍스트)을 세션 메시지로 저장할지 vs 이어가기 시 재요청 | 컨텍스트 복원 정확도 vs 비용 — 결정 필요 |
| 3 | "복사→붙여넣기" 단독 텍스트 카드를 세션화 통일할지 vs 레거시 유지 | §4.5 결정 |
| 4 | v8 백필이 멀티디바이스에서 독립 실행될 때 세션 중복 — 결정적 id 생성으로 회피 가능한지 | §7 R1, sync 머지 동작 검증 |
| 5 | 피드백 세션 `anchor_page` 백필 — 노트에 페이지·교재 매핑이 있는지(`note_id`→`current_page`) | `NoteView` 페이지/교재 연결 코드 재확인 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| **R1. v8 백필 멀티디바이스 중복** — 각 기기가 독립적으로 feedback_chats→session 생성 시 세션 N배 중복 | 높음 | 세션 id를 `feedback_id` 기반 **결정적**으로 생성(예: `"sess_" + feedback_id`). 같은 입력→같은 id→sync가 동일 행으로 머지 |
| **R2. session/message/feedback 참조 무결성** — pull 적용 순서가 어긋나면 FK dangling | 중간 | sessions를 messages/feedbacks보다 **먼저** apply(§3.2-a). FK는 앱 레벨(soft)로 두고 missing 세션 시 "기타"로 표시 |
| **R3. 통합 리팩토링이 v1 출시 sync 안정성 흔듦** — `feedback_chats` 키 이전이 기존 동기화 깸 | 높음 | `feedback_id` 컬럼 **유지(nullable)**, `session_id` 가산. 구버전 클라이언트와 한동안 공존. 단계적 롤아웃 |
| **R4. 가이드 채팅 컨텍스트 손실** — 세션 이어가기 시 원래 가이드 본문 없으면 답변 품질↓ | 중간 | §6.x-2 결정: 가이드 본문을 세션 첫 메시지로 영속화 |
| **R5. 챕터 매칭 실패**(교재 미연결/스캔 PDF) | 낮음 | `chapter_title` 스냅샷 폴백, "기타" 그룹 |
| **R6. D 트랙 `NoteView` 좌표/stroke range 회귀** — 카드 렌더·frozen 로직 민감 | 중간 | 기존 `appendFeedbackCard` 위치/stroke 로직 그대로, `session_id`만 가산. placement 신규 경로만 추가 |

---

## 8. 권장 진행 순서

1. **A-1/A-2 스키마 확정 → §3.2-a 계약 동결** (이후 F/E 병렬 해금).
2. R1(결정적 세션 id), R3(레거시 컬럼 유지) 먼저 합의.
3. §6.x 미확인 1~5 사용자 결정 → 스펙 갱신(`/make-spec edit`).
4. A 완료 후 B/C/D 병렬, F/E 병렬.
