# Cloud Data Sync Spec: 로컬 전용 → 멀티 디바이스 동기화

> **Status:** Draft
> **Date:** 2026-06-01
> **Author:** (auto-generated)

---

## 1. Background

### 1.1 현재 상태 / 운영 이력

ScatchLM iOS 앱은 현재 **오프라인 전용 로컬 저장**으로 동작한다.

- 노트/페이지/피드백/채팅이 단일 GRDB 파일 `Application Support/scatchlm.db`에 저장됨 (`DatabaseService.swift:18-19`).
- 백엔드에는 **Note / NotePage 테이블이 아예 없다.** iOS가 로컬 전담. (`backend/app/models/` 조사 결과)
- 피드백/채팅은 LLM 생성 로그로서 `AIResponse` 테이블에만 부분적으로 적재됨 (`feedback.py:15-33`). 클라이언트의 카드 위치(bbox/position/stroke_range)·노트 연결·평가 상태는 **로컬에만** 존재.
- 부분 동기화 흔적만 있음: `FeedbackRecord.serverFeedbackId`, `ChatMessageRecord.serverMessageId`, `userRatingSyncedAt` (평가 제출 시 서버 반영). 노트/페이지 본문은 서버에 전혀 없음.

**치명적 결함 (선행 발견, [[project_local_db_user_isolation]]):**
로컬 DB가 **유저별로 격리돼 있지 않다.** 모델에 `user_id` 컬럼이 없고(`Models/` 전체), 로그아웃(`SettingsSheet.swift` Sign Out)은 Supabase 세션만 지우고 로컬 DB는 비우지 않는다. → **다른 유저로 로그인해도 이전 유저의 노트가 그대로 보임.** 이 스펙이 이 문제를 함께 해결한다.

### 1.2 Out of Scope

| 항목 | 이유 |
|---|---|
| 실시간 협업(동시 편집, OT/CRDT) | 단일 사용자 멀티 디바이스가 목표. 동시 편집은 별도 phase |
| PKDrawing의 stroke 단위 머지 | drawing은 blob 단위 LWW로 처리. stroke 머지는 과도한 복잡도 |
| PDF 교재 파일 재동기화 | `TextbookSource`는 이미 서버 보유(`pdf.py` upload). 메타 링크만 sync |
| `pdf_drawings` 테이블 sync | **휴면 테이블** — 모델/메서드(`PdfDrawing`, `savePdfDrawing`/`pdfDrawing`)는 정의돼 있으나 어떤 View에서도 호출되지 않음(미사용). sync해도 빈 테이블. 향후 PDF 주석 기능을 살리면 그때 sync 대상에 추가 (§6.x 5) |
| 실시간 push(웹소켓/APNs 트리거) | 1차는 폴링/이벤트 기반 pull. push 알림은 Phase 2 |
| 주기적 백그라운드 fetch(`BGAppRefreshTask`) | 수동 조작 없이 타 기기 변경을 받으려면 필요하나, 서버 push 부재 1차에선 과함. foreground 진입 pull로 대체. Phase 2 |
| 과거 단일 공유 `scatchlm.db` 데이터의 서버 업로드 | 테스트 데이터로 간주, 첫 로그인 유저 로컬에만 귀속 (§4.5) |

### 1.3 기존 코드 정리 대상

- Hard delete 경로(`DatabaseService.deleteNote/deleteFeedback`)는 sync와 충돌. soft delete로 전환 필요(§4.3).
- 로그아웃 시 로컬 DB 미정리 로직(`SettingsSheet.swift`) — §4.5에서 유저별 스코프로 대체.

---

## 2. 현재 / 목표 시스템 도식

### 2.1 현재 (로컬 전용)

```
iOS A ──write──> scatchlm.db (단일 파일, user 무관)
iOS B ──write──> scatchlm.db (별도 기기, 완전 분리, 동기화 없음)
                         │
        feedback/chat 생성 시에만 ─POST /feedback─> AIResponse (서버, 일부)
```

### 2.2 목표 (delta sync)

```
                          ┌──────────────── Backend ────────────────┐
iOS A ──push(dirty)──────>│ POST /api/sync/push                      │
iOS A <──pull(since)──────│ POST /api/sync/pull   sync 테이블        │
                          │   notes/note_pages/feedbacks/chats       │
iOS B ──push/pull────────>│   (user_id 스코프, updated_at, deleted)  │
                          │ blob: POST /api/sync/blob (PKDrawing)    │
                          └──────────────────────────────────────────┘
   로컬: user_id 스코프 + dirty 플래그 + soft delete + sync cursor
```

---

## 3. Backend API Inventory & Contracts

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| POST | `/api/sync/pull` | since 커서 이후 변경분 내려받기 | **신규** | §3.2-a |
| POST | `/api/sync/push` | 로컬 dirty 레코드 올리기 | **신규** | §3.2-b |
| POST | `/api/sync/blob` | PKDrawing 등 바이너리 업로드(content-addressed) | **신규** | §3.2-c |
| GET | `/api/sync/blob/{hash}` | blob 다운로드 | **신규** | §3.2-d |
| POST | `/api/feedback` | 손글씨 피드백(기존) | 변경없음 | — |
| POST | `/api/feedback/{id}/rate` | 평가(기존) | 변경없음 | — |
| GET | `/api/pdf/textbooks` | 교재 목록(기존) | 변경없음 | — |

모든 sync 엔드포인트는 기존 `get_current_user_id` 의존성(`core/auth.py:62-82`)으로 인증하고 `user_id` 스코프를 강제한다.

**sync 대상 = 로컬 5개 테이블 중 4개.** `notes`, `note_pages`, `feedbacks`, `feedback_chats`(→ 서버 `chat_messages`)만 동기화한다. `pdf_drawings`는 휴면 테이블이라 **제외**(§1.2).

### 3.2 신규 엔드포인트 계약 (동결)

**공통 엔티티 스키마** (push/pull 양쪽 동일). PK는 **클라이언트 생성 UUID**(iOS `Note.id` 등 이미 TEXT UUID)를 서버·클라 공유 canonical id로 사용 → id 재매핑 불필요.

```
Entity = {
  id: string(uuid),            // 클라 생성, 서버 PK 공유
  updated_at: string(iso8601 UTC),  // LWW 기준
  deleted: boolean,            // soft delete tombstone
  ...엔티티별 필드 (아래)
}

note:        { title: string, language: string, textbook_id: string|null,
               textbook_name: string|null, textbook_pages: int,
               last_page: int, pdf_open: bool, current_page_index: int,
               drawing_hash: string|null, created_at: iso8601 }
note_page:   { note_id: string(uuid), page_index: int,
               drawing_hash: string|null, created_at: iso8601 }
feedback:    { note_id: string, page_id: string|null, content: string,
               position_x: double, position_y: double,
               bbox_x: double, bbox_y: double, bbox_width: double, bbox_height: double,
               stroke_range_start: int|null, stroke_range_end: int|null,
               server_feedback_id: string|null, user_rating: int|null,
               created_at: iso8601 }
chat_message:{ feedback_id: string, role: string, content: string,
               server_message_id: string|null, user_rating: int|null,
               created_at: iso8601 }
```

> `drawing_hash`: PKDrawing blob의 sha256(hex). 본문(blob)은 §3.2-c로 따로 전송. null이면 빈 드로잉.

```
### 3.2-a POST /api/sync/pull
- Request body:
  { since: string(iso8601)|null,   // null이면 전체(최초 동기화)
    limit: int (optional, default 500, max 1000) }
- Response 200:
  { changes: {
      notes: Entity[], note_pages: Entity[],
      feedbacks: Entity[], chat_messages: Entity[] },
    cursor: string(iso8601),    // 다음 pull의 since 로 사용
    has_more: boolean }         // true면 cursor로 재요청
- 정렬: 각 배열 updated_at ASC. deleted=true 도 포함(tombstone).
- Error: 401 (토큰 무효), 400 (since 파싱 실패)
- 예시:
  req: { "since": "2026-06-01T00:00:00Z", "limit": 500 }
  res: { "changes": { "notes": [
           { "id":"3f...","updated_at":"2026-06-01T08:12:00Z","deleted":false,
             "title":"불어 1과","language":"fr","textbook_id":null,
             "textbook_name":null,"textbook_pages":0,"last_page":1,
             "pdf_open":false,"current_page_index":0,
             "drawing_hash":null,"created_at":"2026-05-30T10:00:00Z" } ],
           "note_pages":[], "feedbacks":[], "chat_messages":[] },
         "cursor":"2026-06-01T08:12:00Z", "has_more":false }
  빈 케이스: { "changes":{"notes":[],"note_pages":[],"feedbacks":[],"chat_messages":[]},
              "cursor":"2026-06-01T08:12:00Z","has_more":false }

### 3.2-b POST /api/sync/push
- Request body:
  { changes: {
      notes: Entity[], note_pages: Entity[],
      feedbacks: Entity[], chat_messages: Entity[] } }
  // 각 Entity는 클라의 dirty 레코드. deleted=true 면 tombstone push.
- 서버 처리: 엔티티별 LWW — incoming.updated_at > server.updated_at 이면 적용, 아니면 conflict.
- Response 200:
  { results: [
      { id: string, entity: "note"|"note_page"|"feedback"|"chat_message",
        status: "applied"|"conflict"|"missing_blob",
        server_updated_at: iso8601 } ],
    missing_blobs: string[] }   // 서버에 없어 업로드 필요한 drawing_hash 목록
- status=conflict: 서버가 더 최신 → 클라는 다음 pull로 서버본 수용.
- status=missing_blob: drawing_hash 참조하나 blob 미보유 → §3.2-c 업로드 후 재push.
- Error: 401, 400 (스키마 위반), 413 (배치 과대)
- 예시:
  req: { "changes": { "notes":[{ "id":"3f...","updated_at":"2026-06-01T09:00:00Z",
          "deleted":false,"title":"수정됨","language":"fr","textbook_id":null,
          "textbook_name":null,"textbook_pages":0,"last_page":2,"pdf_open":true,
          "current_page_index":1,"drawing_hash":"ab12...","created_at":"2026-05-30T10:00:00Z"}],
          "note_pages":[],"feedbacks":[],"chat_messages":[] } }
  res: { "results":[{ "id":"3f...","entity":"note","status":"applied",
          "server_updated_at":"2026-06-01T09:00:00Z" }],
         "missing_blobs":["ab12..."] }

### 3.2-c POST /api/sync/blob
- Request: multipart/form-data — fields: hash(string sha256 hex), file(binary)
- 서버: 저장 키 = f"sync/{user_id}/{hash}", storage 추상화 재사용(storage.py). 동일 hash 멱등.
- Response 200: { hash: string, stored: boolean }
- Error: 401, 400 (hash != 실제 내용 sha256 → 거부), 413
- 예시: res { "hash":"ab12...", "stored":true }

### 3.2-d GET /api/sync/blob/{hash}
- 서버: 키 f"sync/{user_id}/{hash}" 조회. 로컬이면 FileResponse, S3면 StreamingResponse (pdf.py 패턴 재사용).
- Response 200: application/octet-stream (binary)
- Error: 401, 404 (미보유)
```

> **MSW 비고:** 이 프로젝트는 iOS(Swift) 클라이언트라 MSW(웹) 해당 없음. iOS track은 위 동결 계약을 `APIClient` 프로토콜 + 테스트 더블(또는 로컬 스텁 서버)로 모킹해 백엔드 구현 완료 전에 sync 엔진을 개발한다. 이것이 BE/iOS 병렬의 메커니즘.

---

## 4. 구현 설계

### 4.1 동기화 모델: delta sync + LWW

- **canonical id 공유**: 클라 UUID를 서버 PK로 그대로 사용 → id 재매핑·임시키 불필요.
- **변경 추적**: 클라는 로컬 `dirty` 플래그로 미전송 변경을 표시. push 성공 시 클리어.
- **pull 커서**: 마지막 성공 pull의 `cursor`(서버 max updated_at)를 로컬에 저장, 다음 since로 사용.
- **충돌 해결**: `updated_at` 기준 LWW(엔티티 단위). drawing은 hash 참조이므로 blob 단위 LWW.
- **삭제**: soft delete tombstone(`deleted=true`)을 sync. 양쪽에서 전파 후 일정 기간 뒤 GC(Phase 2).

### 4.2 동기화 트리거

트리거는 **송신 시작점 / 송신 보장 / 복원력** 세 층으로 본다. 시작점만 있으면 디바운스 대기·오프라인·실패 구간에서 데이터가 샌다.

**(1) 송신 시작점**

| 시점 | 동작 |
|---|---|
| 로그인 직후 | 최초 full pull(since=null) → 로컬 머지 |
| 앱 foreground 진입 | dirty push → pull |
| 로컬 write 발생(노트/페이지/피드백/채팅 저장) | dirty 표시, 디바운스 후 push |
| 수동 새로고침(선택) | push → pull |

**(2) 송신 보장**

| 시점 | 동작 | 이유 |
|---|---|---|
| 앱 background/종료 직전(`scenePhase` → `.background`/`.inactive`) | 대기 중 디바운스 취소하고 **즉시 dirty flush push** | write 후 디바운스 대기 중 background/kill 시 마지막 편집 유실 방지 |

**(3) 복원력**

| 시점 | 동작 | 이유 |
|---|---|---|
| 네트워크 복구(reachability online 전환) | 남은 dirty push → pull 재개 | foreground 유지 중 네트워크만 끊겼다 복구된 경우 재시도 트리거 |
| push/pull 실패(5xx·타임아웃·오프라인) | 지수 backoff 큐로 재시도 | 다음 시작점 트리거까지 방치 방지. 성공 시 큐 클리어 |

> dirty 플래그가 단일 진실원(source of truth): 어떤 트리거든 "dirty인 것을 push, 커서 이후를 pull"만 수행하므로 트리거가 중복돼도 멱등하다.

### 4.3 데이터 모델 변경

**iOS GRDB (마이그레이션 v7):** 모든 sync 대상 테이블에 컬럼 추가
- `user_id TEXT NOT NULL` (현재 세션 user.id; §4.5)
- `deleted BOOLEAN NOT NULL DEFAULT 0` (soft delete)
- `dirty BOOLEAN NOT NULL DEFAULT 1` (미전송 변경)
- note에는 `drawing_hash TEXT` 추가(현재 `drawing_data BLOB`은 유지하되 hash 계산 보관). note_page도 동일.
- 기존 hard delete(`deleteNote`/`deleteFeedback`)를 `deleted=1, dirty=1, updated_at=now` 업데이트로 교체.
- 모든 조회 쿼리에 `WHERE user_id = ? AND deleted = 0` 필터 추가.

**Backend (Alembic, HEAD=a1b2c3d4e5f6 위에 신규 1개):** sync 테이블 신규 생성
- `notes`, `note_pages`, `feedbacks`, `chat_messages` (각각 §3.2 스키마 + `user_id` FK→users, `updated_at` indexed, `deleted`).
- 인덱스: `(user_id, updated_at)` — pull 쿼리 핵심.
- `AIResponse`는 그대로(LLM 로그). 신규 `feedbacks`는 클라 카드 메타 저장, `server_feedback_id`로 AIResponse 참조(옵션).

### 4.4 PKDrawing(blob) 처리

- 로컬 저장 시 `drawing_data`의 sha256 계산 → `drawing_hash` 보관.
- push 응답 `missing_blobs`에 hash가 있으면 `/api/sync/blob`로 업로드 후 재push.
- pull로 받은 레코드의 `drawing_hash`가 로컬에 없으면 `/api/sync/blob/{hash}` 다운로드 → `drawing_data` 복원.
- 빈 드로잉은 `drawing_hash=null`.

### 4.5 유저별 로컬 격리 (선행 결함 해결)

**확정: user_id 컬럼 스코프 방식** (2026-06-01). 유저별 DB 파일 분리안은 폐기 — sync 메타와 이중 관리가 되고 blob 스코프도 어긋나기 때문.

- 단일 `scatchlm.db` 유지. 모든 sync 테이블에 `user_id TEXT NOT NULL`(§4.3) 보유.
- **모든 read/write에 `WHERE user_id = ?` 강제** — 현재 세션 user.id 주입. 누락 쿼리 1곳이 곧 타 유저 데이터 노출이므로 §6.9 write 지점 + 전 조회를 빠짐없이 전환(B-3/B-4).
- write 시 항상 현재 user.id를 채워 저장. 세션 없는 상태(미로그인)에서는 sync 대상 write를 막거나 보류.
- blob 저장 키도 user 스코프: `sync/{user_id}/{hash}`(§3.2-c)와 일관.
- **로그아웃**: Supabase 세션만 지우고 로컬 데이터는 보존(다음 로그인 시 user_id 필터로 자동 격리). 공용 기기 대응 "이 기기에서 삭제" 옵션은 Phase 2.

> 기존 단일 공유 `scatchlm.db`의 레거시 행 처리는 §4.6에서 확정.

### 4.6 레거시 행 처리 (v7 마이그레이션 backfill)

v7에서 `user_id TEXT NOT NULL`을 추가할 때 기존 행에 채울 값이 필요하다. 현재 단일 공유 DB의 행은 어느 유저 것인지 알 수 없으므로:

- **결정**: v7 마이그레이션은 `user_id`를 **빈 문자열 `""`(sentinel)** 로 backfill 한다(NOT NULL 충족). 컬럼은 `DEFAULT ''`.
- 앱은 로그인된 user.id로만 sync 대상을 조회(`WHERE user_id = ?`)하므로, sentinel 행은 **어떤 실제 유저에게도 노출되지 않는다**(자연 격리).
- 첫 로그인 시 **일회성 귀속(claim)**: sentinel(`user_id = ''`) 행을 현재 user.id로 UPDATE + `dirty = 1` 표시 → 이후 sync로 서버에 올라감. (이는 §1.2 "서버 업로드 제외"의 예외가 아니라, **로컬 레거시를 현재 유저 데이터로 1회 흡수**하는 것. 운영 중 실데이터가 없던 개발 단계라 안전.)
- claim을 원치 않으면(테스트 데이터 폐기) sentinel 행을 삭제하는 옵션도 가능 — B-1 구현 시 플래그로 선택. 기본은 claim.

---

## 5. 구현 단계 (Tracks)

```
                         ┌─── Track A: Backend sync 테이블 + 엔드포인트
                         │       (계약 §3.2 구현)
                         │
   §3.2 계약 동결 ───────┼─── Track B: iOS 로컬 스키마 v7 (user_id/dirty/deleted/hash)
   (이 문서)             │       + 유저별 격리 (§4.5)
                         │
                         ├─── Track C: iOS Sync 엔진 (push/pull/blob/충돌)
                         │       의존: Track B 스키마
                         │
                         └─── Track D: iOS 통합 (트리거/로그아웃/인디케이터)
                                 의존: Track C
```

**트랙 간 의존성:**
- 계약(§3.2)은 본 문서에서 **동결됨** → A와 B/C는 즉시 병렬 시작 가능.
- C는 B의 로컬 스키마(dirty/deleted/user_id) 완료 후 본격화. B 진행 중 C는 `APIClient` 프로토콜 모킹으로 선행.
- **통합 테스트(C↔A)**는 Track A 실서버 완료 필요.
- D는 C 완료 후.

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | A → B → C → D 순차 |
| 2명 | P1: A(백엔드 전담) / P2: B→C→D(iOS 전담) |
| 3명 | P1: A / P2: B→C / P3: C 보조(blob/충돌)→D |
| 4명 | P1: A / P2: B / P3: C / P4: D + 통합 테스트 |

### Track A: Backend sync 테이블 + 엔드포인트
**의존:** 없음 (계약 동결됨)
**내부 순서:** A-1 → A-2 → A-3 (A-4 병렬 가능)
**작업량:** 큼. 가장 복잡: A-3 push의 LWW/멱등/blob 부재 처리.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `backend/app/models/sync.py` (신규) | Note/NotePage/Feedback/ChatMessage SQLAlchemy 모델 (user_id FK, updated_at, deleted) |
| A-2 | `backend/alembic/versions/{new}.py` | A-1 테이블 생성 마이그레이션 + `(user_id, updated_at)` 인덱스. down_revision=a1b2c3d4e5f6 |
| A-3 | `backend/app/routers/sync.py` (신규) | `/api/sync/pull`,`/push`,`/blob` 구현. get_current_user_id 스코프. §3.2 계약 준수 |
| A-4 | `backend/app/services/sync.py` (신규) | pull 쿼리/push LWW 로직 분리, storage.py 재사용 blob 저장 |
| A-5 | `backend/app/main.py` | sync 라우터 등록 |
| A-6 | `backend/tests/test_sync.py` (신규) | pull/push/충돌/blob 멱등/유저 격리 테스트 |

### Track B: iOS 로컬 스키마 v7 + 유저별 격리
**의존:** 없음 (계약과 무관, 로컬 작업)
**내부 순서:** B-1 → B-2 → B-3
**작업량:** 중간. 가장 복잡: 기존 hard delete → soft delete 전환 + 전 쿼리 user_id 필터.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `ScatchLM/Services/DatabaseService.swift` | 마이그레이션 `v7_sync_metadata`: user_id/deleted/dirty/drawing_hash 컬럼 추가 |
| B-2 | `ScatchLM/Models/Note.swift` | 4개 모델에 userId/deleted/dirty/drawingHash 필드 + CodingKeys |
| B-3 | `ScatchLM/Services/DatabaseService.swift` | 전 조회에 `user_id=? AND deleted=0` 필터, delete→soft delete, write 시 dirty=1·updated_at 갱신 |
| B-4 | `ScatchLM/Services/DatabaseService.swift` + 호출부 | dbQueue 접근 시 현재 user_id 주입 경로(§4.5 권장안) |

### Track C: iOS Sync 엔진
**의존:** Track B 스키마 (모킹으로 선행 가능)
**내부 순서:** C-1 → (C-2, C-3 병렬) → C-4
**작업량:** 큼. 가장 복잡: C-3 충돌/재시도 + blob missing 핸들링.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `ScatchLM/Services/APIClient.swift` | pull/push/blob 메서드 추가(§3.2). 기존 multipart 재사용 |
| C-2 | `ScatchLM/Services/SyncService.swift` (신규) | pull→로컬 머지(LWW), 커서 저장(UserDefaults/테이블) |
| C-3 | `ScatchLM/Services/SyncService.swift` | dirty 수집→push, conflict/missing_blob 처리, blob 업/다운로드 |
| C-4 | `ScatchLM/Services/DrawingHash.swift` (신규) | PKDrawing dataRepresentation sha256 계산 유틸 |
| C-5 | `ScatchLMTests/SyncServiceTests.swift` (신규) | 모킹 APIClient로 머지/충돌/커서 진행 테스트 |
| C-6 | `ScatchLM/Services/SyncService.swift` | **복원력**: reachability(`NWPathMonitor`) online 전환 시 재개 + 실패 시 지수 backoff 재시도 큐 (§4.2-3). Track D는 이 API를 호출만 함 |

### Track D: iOS 통합 (트리거 §4.2 전부 결선)
**의존:** Track C 완료 (D-4는 C-6 reachability API 호출)
**내부 순서:** D-1 → D-2 → D-3 (D-4 병렬)
**작업량:** 중간. 가장 복잡: D-3 background flush 경합(디바운스 취소↔즉시 push).

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `ScatchLM/Services/AuthService.swift` | 로그인 후 최초 full pull 트리거, 로그아웃 시 sync 중단/커서 클리어 |
| D-2 | `ScatchLM/App/ScatchLMApp.swift` + Views | **시작점**: foreground 진입 push→pull, 로컬 write 디바운스 push 훅 (write 지점: §6.9) |
| D-3 | `ScatchLM/App/ScatchLMApp.swift` | **송신 보장**: `scenePhase` `.background`/`.inactive` 시 디바운스 취소 + 즉시 dirty flush |
| D-4 | `ScatchLM/Views/` | 동기화 상태 인디케이터(진행/오류/오프라인 대기), 수동 새로고침(선택). C-6 reachability 상태 표시 |

---

## 6. 확인 완료 사항 (코드 검증)

1. **User PK = Supabase UUID 직접 매핑** — `backend/app/models/user.py:11-18`(id String PK), `core/auth.py:29-49`(sub→user_id), `:52-59`(JIT). sync user_id 스코프 근거.
2. **백엔드에 Note/NotePage 테이블 부재** — `backend/app/models/`에 note/page 없음. feedback/chat은 `AIResponse`(`feedback.py:15-33`)로만 부분 존재. → sync 테이블 신규 생성 필요(A-1).
3. **iOS 로컬 모델 sync 메타 부분 보유** — Note `created_at`/`updated_at`(`Note.swift:17-18`), Feedback `serverFeedbackId`/`userRatingSyncedAt`(`:81,83`), Chat `serverMessageId`(`:216`). **부재: user_id, deleted, dirty**(전 모델). → B-1/B-2 필요.
4. **PKDrawing = 바이너리 blob** — `NoteView.swift:551` `drawing.dataRepresentation()`→BLOB, `:564` 역직렬화. JSON 불가 → §3.2-c blob 채널 + drawing_hash 설계 근거.
5. **GRDB 현재 v6** — `DatabaseService.swift:26-141`(v1~v6). 신규는 v7로 추가(이미 실행된 마이그레이션 수정 금지).
6. **Alembic HEAD = a1b2c3d4e5f6** — `rename_ai_feedback_to_ai_response`. 신규 마이그레이션 down_revision 기준.
7. **Storage 추상화 재사용 가능** — `storage.py:21-30`(Protocol save/read/delete/stream), 로컬/S3 구현. blob 채널 즉시 적용.
8. **인증 토큰 주입 경로** — `APIClient.swift:20-26`(Bearer). sync 호출에 그대로 사용.
9. **로컬 write 지점(sync hook 대상)** — Note 저장 `HomeView.createNote/updateNote`, NotePage `NoteView.savePageDrawing(:549-558)`, Feedback `NoteView.appendFeedbackCard(:459-535)`, Chat `FeedbackChatSheet.sendMessage(:235)`. delete: `DatabaseService.deleteNote(:163-167)`/`deleteFeedback(:223-227)`(hard, 전환 대상).
10. **로컬 테이블 5개, 그중 `pdf_drawings`는 휴면** — `DatabaseService.swift`에 `notes(:30)`,`feedbacks(:44)`,`pdf_drawings(:57)`,`feedback_chats(:69)`,`note_pages(:80)` 정의. `savePdfDrawing`/`pdfDrawing`(`:240,248`)은 정의만 있고 View 호출부 없음 → sync 제외(§1.2).

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | ~~유저별 격리 방식 확정~~ | **결정됨(2026-06-01): user_id 컬럼 스코프**(§4.5). 파일 분리안 폐기 |
| 2 | drawing blob 크기 분포(평균/최대) → 업로드 배치/타임아웃 정책 | 실데이터 측정 |
| 3 | feedbacks 신규 테이블 vs 기존 AIResponse 통합 범위 | A-1 설계 시 결정 — 본 스펙은 분리(메타) 가정 |
| 4 | 커서 정확성: 동일 updated_at 다수 시 누락 위험 | (user_id, updated_at, id) 보조 정렬/경계 처리 검토 |
| 5 | tombstone GC 정책(보존 기간) | Phase 2 |
| 6 | `pdf_drawings` 부활 시 sync 추가 | **결정됨: 현재 제외**(휴면). PDF 주석 기능 살릴 때 재검토 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| LWW로 인한 사용자 편집 손실(두 기기 동시 수정) | 중 | drawing은 blob 단위, 메타는 필드 단위로 분리. updated_at 정밀도 ms. Phase 2서 충돌 UI 검토 |
| 동일 `updated_at` 경계에서 pull 누락 | 높 | 커서를 `(updated_at, id)` 복합으로, since는 `>=` + 클라 중복 무시(멱등 upsert) |
| 기존 hard delete 코드 잔존 → tombstone 누락 | 높 | B-3에서 전 delete 경로를 soft delete로 일괄 전환, grep 검증 |
| 유저 격리 누락 쿼리 1곳 → 타 유저 데이터 노출 | 높 | B-3 전 쿼리 user_id 필터 + A-6/통합 테스트에 cross-user 격리 케이스 필수 |
| blob 미업로드 상태로 메타만 sync → 빈 드로잉 표시 | 중 | push 응답 missing_blobs로 강제 업로드, 미완료 시 dirty 유지 후 재시도 |
| drawing blob 대량 → 트래픽/저장 비용 | 중 | content-addressed(중복 제거), 변경된 페이지만 hash 갱신 |
| 최초 full pull 대용량 | 중 | limit/has_more 페이지네이션(§3.2-a) |
| background flush가 iOS 실행시간 한도 내 미완료 | 중 | `.background` 전환 시 `beginBackgroundTask`로 짧은 유예 확보, 미완료분은 dirty 유지 후 다음 트리거 재시도 |
| 오프라인 누적 dirty가 재시도 폭주(thundering) | 낮 | C-6 단일 backoff 큐로 직렬화, 네트워크 복구 1회 트리거로 일괄 처리 |

---

## 8. 관련 문서

- 선행 결함 메모: 로컬 DB 유저 격리 부재 ([[project_local_db_user_isolation]])
- Alembic 베이스라인 주의 ([[project_alembic_baseline]])
- Swift 마이그레이션 배경 ([[feedback_swift_migration]])
- 배포 절차: `backend/DEPLOY.md`
