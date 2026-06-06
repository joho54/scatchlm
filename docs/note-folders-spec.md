# Note Folders Spec: 평면 노트 목록 → 폴더 기반 정리

> **Status:** Draft
> **Date:** 2026-06-06
> **Author:** (auto-generated)

---

## 1. Background

### 1.1 현재 상태 / 운영 이력

ScatchLM의 노트는 **단일 평면 리스트**로만 관리된다. 폴더/디렉토리/카테고리 개념이 코드베이스 어디에도 존재하지 않는다 (iOS 로컬 모델·Backend 모델·동기화 계층 모두 확인 완료, §6).

- **홈 화면**: `HomeView.swift:20-49`가 `filteredNotes`를 `LazyVGrid`(adaptive, min 240pt) + `NoteCardView`로 평면 렌더링. 그룹핑·섹션 없음.
- **분류 수단**: 제목 검색(`localizedCaseInsensitiveContains`, `HomeView.swift:15-18`)과 교재(textbook) 연결뿐. 교재는 노트당 0~1개 참조 메타(`Note.textbookId/Name/Pages`)일 뿐 폴더가 아니다.
- **데이터 모델**: `Note`(`Models/Note.swift:10-127`)에 폴더 관계 필드 없음. 노트는 (1) 독립 또는 (2) 교재 참조만 가진다.
- **동기화**: 노트는 이미 멀티 디바이스 delta-sync(LWW) 대상이다 (`cloud-data-sync-spec.md`). 따라서 **폴더도 디바이스 간 동기화되어야** 일관된 정리 상태가 유지된다.

노트 수가 늘면서 평면 리스트의 탐색 비용이 커지는 것이 이 기능의 동기다.

### 1.2 Out of Scope

| 항목 | 이유 |
|---|---|
| **중첩 폴더(폴더 안의 폴더)** | v1은 **단일 레벨 플랫 폴더**로 한정. 트리 탐색 UI·재귀 sort·순환참조 방지 등 복잡도가 큼. `parent_id` 도입은 Phase 2 (§4.6) |
| 드래그&드롭으로 노트 이동/폴더 정렬 | v1은 contextMenu("폴더로 이동") + 시트 선택으로 충분. DnD는 UX 개선 Phase 2 |
| 폴더 색상/아이콘/이모지 커스터마이징 | 메타 확장. v1은 이름만. 컬럼 추가만으로 후속 가능 |
| 폴더별 공유/협업 | 단일 사용자 멀티 디바이스가 목표 (sync 스펙과 동일 전제) |
| 교재(textbook)를 폴더로 자동 매핑 | 교재와 폴더는 직교 개념. 자동 분류는 추측 — v1은 수동 분류만 |
| 스마트 폴더(필터 기반 가상 폴더) | 물리적 소속(folder_id)만 v1. 규칙 기반은 별도 기능 |

### 1.3 기존 코드 정리 대상

없음. 순수 추가 기능 — 기존 노트는 `folder_id = NULL`(= "전체"/루트)로 자연 호환된다.

---

## 2. 현재 / 목표 시스템 도식

### 2.1 현재 (평면)

```
HomeView
  └─ LazyVGrid
       └─ ForEach(filteredNotes)  ← 전체 노트 평면 나열
            └─ NoteCardView
```

### 2.2 목표 (폴더)

```
HomeView (HStack)
  ├─ 좌측 사이드바 (FolderSidebar)        ← selectedFolderId 상태
  │     ├─ "전체"
  │     ├─ 폴더A · 폴더B · …  (sort_order 순)
  │     └─ "+ 폴더" / 이름변경 / 삭제
  └─ 우측 LazyVGrid (기존 그리드)
       └─ ForEach(notes where folder_id == selectedFolderId)
            └─ NoteCardView (contextMenu에 "폴더로 이동" 추가)

동기화: folders 엔티티가 notes/note_pages/… 와 동일하게
        POST /api/sync/push · pull 로 delta-sync (user_id 스코프, LWW, soft delete)
        note.folder_id 도 note 엔티티 변경분으로 함께 전송
```

---

## 3. Backend API Inventory & Contracts

폴더는 기존 sync 인프라(`/api/sync/push`·`/pull`)를 **재사용**한다. 신규 라우트는 없고, sync의 `Changes` 페이로드에 `folders` 엔티티를 추가하고 `note` dict에 `folder_id`를 추가한다.

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| POST | /api/sync/push | dirty 레코드 업로드 (LWW) | 변경 (folders 엔티티·note.folder_id 추가) | §3.2-a |
| POST | /api/sync/pull | since 이후 변경분 pull | 변경 (folders 엔티티·note.folder_id 추가) | §3.2-b |
| POST | /api/sync/blob | PKDrawing blob 업로드 | 변경없음 | — |
| GET | /api/sync/blob/{hash} | blob 다운로드 | 변경없음 | — |

### 3.2 신규/변경 엔드포인트 계약 (동결)

#### 3.2-a POST /api/sync/push (변경)

- **Request body** (`Changes`, `sync.py:24-28`에 `folders` 추가):
  ```
  {
    "notes":         [ <NoteDTO + folder_id> ... ],
    "note_pages":    [ ... ],
    "feedbacks":     [ ... ],
    "chat_messages": [ ... ],
    "folders":       [ <FolderDTO> ... ]      // 신규
  }
  ```
- **FolderDTO** (신규 엔티티):
  | 필드 | 타입 | 제약 |
  |---|---|---|
  | `id` | string (UUID) | required, 클라 생성 |
  | `name` | string | required, 1~100자 |
  | `sort_order` | int | required, 기본 0 (오름차순 표시) |
  | `created_at` | string (ISO8601) | required |
  | `updated_at` | string (ISO8601) | required, LWW 키 |
  | `deleted` | bool | required, soft delete |
- **NoteDTO 변경**: 기존 필드(`cloud-data-sync-spec.md` §3.2 NoteDTO)에 다음 추가:
  | 필드 | 타입 | 제약 |
  |---|---|---|
  | `folder_id` | string (UUID) \| null | optional, null = 미분류(전체) |
- **Response 200** (`PushResponse`, 형식 변경 없음):
  ```
  { "results": [ {"id": str, "entity": "folder"|"note"|..., "status": "applied"|"stale", "server_updated_at": str} ],
    "missing_blobs": [str] }
  ```
  - `entity`에 `"folder"` 값이 추가될 수 있음.
- **Error**: 기존과 동일. 401(인증 실패), 422(스키마 위반). `folder_id`가 존재하지 않는 폴더를 가리켜도 **거부하지 않음** — FK 강제 없이 dangling 허용(LWW 순서 무관성 보장, §7 R1).
- **예시 payload**:
  ```json
  { "notes": [], "note_pages": [], "feedbacks": [], "chat_messages": [],
    "folders": [
      {"id":"f1a2...","name":"라틴어","sort_order":0,
       "created_at":"2026-06-06T01:00:00Z","updated_at":"2026-06-06T01:00:00Z","deleted":false}
    ] }
  ```
  - 빈 케이스: `"folders": []` (생략 아님, 빈 배열).

#### 3.2-b POST /api/sync/pull (변경)

- **Request** (`PullRequest`, 변경 없음): `{ "since": str|null, "limit": int }`
- **Response 200**: `Changes` 형식과 동일하게 `folders` 키 추가. since 이후 `updated_at`이 갱신된 folder 레코드(삭제분 `deleted:true` 포함)를 반환. note 레코드는 `folder_id` 포함.
- **빈/null 케이스**: 변경 없으면 `"folders": []`.
- **MSW**: 해당 없음 — iOS 클라이언트(Swift)이고 FE는 MSW를 쓰지 않는다. iOS track은 **§3.2 동결 계약으로 `SyncModels.swift`에 `FolderDTO` Codable을 먼저 정의**하여 Backend 구현 완료 전 독립 작업한다 (이것이 본 스펙의 병렬 메커니즘).

---

## 4. 구현 설계

### 4.1 데이터 모델 (신규 엔티티 `folders`)

**iOS GRDB** (`Models/Note.swift`에 `Folder` 추가, `Note`에 컬럼 추가):
```
folders 테이블:
  id TEXT PK, name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  user_id TEXT, deleted INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 0
notes 테이블:
  + folder_id TEXT NULL     (인덱스 권장: idx_notes_folder_id)
```
- sync 메타(`user_id`/`deleted`/`dirty`)는 기존 엔티티와 동일 패턴(`DatabaseService.swift` v7_sync_metadata 참조).

**Backend SQLAlchemy** (`app/models/sync.py`에 `Folder` 추가):
```
class Folder: id(PK, 클라 UUID), user_id(FK), name, sort_order,
              created_at, updated_at, deleted
  인덱스: (user_id, updated_at)   # pull 성능, 기존 Note와 동일
class Note: + folder_id (nullable, FK 강제 안 함 / 단순 컬럼)
```

### 4.2 GRDB 마이그레이션 (iOS)

`DatabaseService.swift`에 **신규** 마이그레이션 등록 (기존 v8_chat_sessions 다음, 예: `v9_note_folders`). 기존 마이그레이션 블록 수정 금지(이미 실행분 스킵됨, CLAUDE.md 규칙):
```swift
migrator.registerMigration("v9_note_folders") { db in
    try db.create(table: "folders") { ... }
    try db.alter(table: "notes") { $0.add(column: "folder_id", .text) }
    try db.create(index: "idx_notes_folder_id", on: "notes", columns: ["folder_id"])
}
```

### 4.3 Alembic 마이그레이션 (Backend)

`app/models/sync.py` 변경 후 `alembic revision --autogenerate -m "add folders + note.folder_id"` → `alembic upgrade head`. 배포 시 app startup CMD가 자동 적용([[project_alembic_autoapply_on_deploy]]).

### 4.4 동기화 배선

- **iOS** (`SyncService.swift`): `pushDirty()`가 dirty folder를 수집해 `folders` 배열에 포함, `pullChanges()`가 응답의 `folders`를 LWW 머지. note의 `folder_id` 변경은 기존 note dirty 경로로 자동 흐름(`folder_id` 변경 시 note `dirty=1`, `updated_at` 갱신).
- **Backend** (`sync.py`): `Changes` 스키마에 `folders: list[dict]` 추가. push 핸들러에 folder LWW 분기, pull 핸들러에 folder 쿼리 추가. note upsert에 `folder_id` 매핑 추가.
- **삭제 규칙**: 폴더 soft delete 시 **그 안의 노트는 삭제하지 않고 `folder_id=NULL`(전체)로 이동**시킨다(클라이언트에서 처리, dirty 표시). 노트 데이터 유실 방지.

### 4.5 홈 화면 UI

`HomeView.swift`:
- **레이아웃**: 최상위를 `HStack { FolderSidebar; 기존 그리드 }`로 변경. 좌측 사이드바는 고정 폭(예: 220pt), 우측이 기존 노트 그리드. iPad 가로 기준 레이아웃이며, 좁은 폭(Split View/세로)에서는 사이드바를 접고 toolbar 버튼으로 토글하는 폴백 고려(§6.x 3).
- **상태 추가**: `@State selectedFolderId: String?`(nil = "전체"), `@State folders: [Folder]`.
- **좌측 사이드바 (`FolderSidebar`)**: "전체" + 폴더 목록(`sort_order` 순)을 세로 리스트로. 선택 시 `selectedFolderId` 갱신 → `filteredNotes`를 `folder_id == selectedFolderId`로 추가 필터(검색과 AND). 현재 선택 항목 하이라이트.
- **폴더 관리**: 사이드바 하단 "+ 폴더" 버튼 → `FolderEditSheet`(이름 입력). 각 폴더 행 contextMenu(또는 swipe) → 이름변경/삭제.
- **노트 이동**: `NoteCardView` contextMenu에 "폴더로 이동" 추가(`HomeView.swift:35-46` 기존 contextMenu 확장) → 폴더 선택 시트(`MoveToFolderSheet`).
- 새 노트 생성 시 현재 `selectedFolderId`를 기본 폴더로 설정(전체 화면이면 NULL).

### 4.6 Phase 2 훅 (구현 안 함, 설계 메모)

중첩 폴더가 필요해지면 `folders`에 `parent_id TEXT NULL` 추가 + 트리 렌더 + 순환참조 가드. v1 스키마는 이를 막지 않음(컬럼 추가만으로 확장 가능).

---

## 5. 구현 단계 (Tracks)

```
                ┌─── Track A: Backend (sync 폴더 엔티티 + alembic)
                │
계약 동결(§3.2)─┤
(완료됨)        ├─── Track B: iOS 데이터 계층 (Folder 모델/마이그레이션/CRUD/sync 배선)
                │         │
                │         └────────── Track C: iOS UI (HomeView 폴더 탐색·관리·이동)
                │                     (Track B의 모델/CRUD 필요)
                └─── (A와 B는 §3.2 동결로 진짜 병렬)
```

**트랙 간 의존성:**
- Track A ↔ Track B: §3.2 계약이 동결되어 **병렬**. iOS는 `FolderDTO` Codable을 동결 계약으로 선작성, Backend는 동일 계약으로 모델/핸들러 구현. 단, **end-to-end 동기화 통합 테스트**는 Track A 완료 필요(MSW 부재, 실 BE 호출).
- Track C → Track B: UI는 `Folder` 모델·`DatabaseService` CRUD(`allFolders`/`saveFolder`/`deleteFolder`/`moveNote`)에 의존. B-1, B-2 완료 후 시작.
- Track B 내부 순서: B-1(모델+마이그레이션) → B-2(CRUD) → B-3(sync 배선). B-3은 Track A 통합 시점에만 검증 가능.

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | A → B → C 순차 (Backend 먼저 동결·구현 후 iOS) |
| 2명 | 개발자1=Track A, 개발자2=Track B→C |
| 3명 | 개발자1=A, 개발자2=B, 개발자3=C(B-2 완료 후 합류, 그 전엔 시트 UI 스캐폴딩) |

### Track A: Backend sync 폴더 엔티티
**의존:** 없음 (§3.2 동결됨)
**내부 순서:** A-1 → A-2 → A-3
**작업량:** 중간. 가장 복잡: pull/push 핸들러에 folder LWW 분기를 기존 4개 엔티티와 일관되게 추가.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `backend/app/models/sync.py` | `Folder` 모델 추가(id PK, user_id, name, sort_order, created_at, updated_at, deleted, 인덱스 (user_id, updated_at)). `Note`에 `folder_id` nullable 컬럼 추가 |
| A-2 | `backend/alembic/versions/*` | `alembic revision --autogenerate` → folders 테이블 + notes.folder_id. `alembic upgrade head` |
| A-3 | `backend/app/routers/sync.py` | `Changes`에 `folders: list[dict]` 추가(24-28). push 핸들러 folder LWW upsert 분기, pull 핸들러 folder 쿼리(since/limit), note upsert에 folder_id 매핑. `PushResponse.results[].entity`에 `"folder"` |

### Track B: iOS 데이터 계층
**의존:** 없음 (§3.2 동결됨). 통합 검증만 Track A 필요.
**내부 순서:** B-1 → B-2 → B-3
**작업량:** 중간. 가장 복잡: B-3 sync 배선(dirty 수집·LWW 머지를 기존 노트 경로와 일관되게).

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `ios-app/ScatchLM/Models/Note.swift` | `Folder` GRDB 모델(Codable, CodingKeys snake_case). `Note`에 `folderId: String?` 추가 |
| B-1 | `ios-app/ScatchLM/Services/DatabaseService.swift` | `v9_note_folders` 마이그레이션 등록(folders 테이블 + notes.folder_id + 인덱스) |
| B-2 | `ios-app/ScatchLM/Services/DatabaseService.swift` | CRUD: `allFolders()`, `saveFolder()`, `deleteFolder()`(soft delete + 소속 노트 folder_id=NULL 전환), `moveNote(id:toFolder:)`. 모든 write에 `dirty=1`·`updated_at` 갱신 |
| B-3 | `ios-app/ScatchLM/Services/SyncModels.swift` | `FolderDTO` Codable 추가(§3.2-a 계약). `NoteDTO`에 `folder_id` 추가 |
| B-3 | `ios-app/ScatchLM/Services/SyncService.swift` | `pushDirty()`에 folder 수집·전송, `pullChanges()`에 folder LWW 머지. note folder_id는 기존 note 경로로 흐름 |

### Track C: iOS 홈 화면 UI
**의존:** Track B (B-1, B-2 완료 후)
**내부 순서:** C-1 → (C-2, C-3 병렬)
**작업량:** 중간~큼. 가장 복잡: `HStack` 좌측 사이드바 레이아웃 + 필터 상태와 기존 검색 필터의 AND 결합, 좁은 폭(Split View) 폴백, 빈 폴더/전체 전환 시 그리드 갱신.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `ios-app/ScatchLM/Views/HomeView.swift` | 최상위 `HStack { FolderSidebar; 기존 그리드 }` 레이아웃, `selectedFolderId`/`folders` 상태, `filteredNotes`에 folder 필터 AND 결합, 새 노트 생성 시 현재 폴더 기본값 |
| C-2 | `ios-app/ScatchLM/Views/HomeView.swift` (또는 신규 `FolderSidebar.swift` + `FolderEditSheet.swift`) | 좌측 사이드바 뷰("전체"+폴더 리스트, 선택 하이라이트, "+ 폴더" 버튼), 폴더 생성/이름변경 시트, 폴더 행 contextMenu(이름변경/삭제) |
| C-3 | `ios-app/ScatchLM/Views/HomeView.swift` (또는 신규 `MoveToFolderSheet.swift`) | 노트 카드 contextMenu "폴더로 이동" + 폴더 선택 시트 → `moveNote()` 호출 |

---

## 6. 확인 완료 사항 (코드 검증)

- **폴더 개념 부재 (전 계층)**: 폴더/디렉토리/카테고리 필드·UI 없음.
  - iOS 모델: `Models/Note.swift:10-127` (Note에 textbook 참조만, 폴더 없음).
  - iOS UI: `HomeView.swift:20-49` 평면 `LazyVGrid`, 섹션/그룹핑 없음.
  - Backend 모델: `backend/app/models/sync.py:32` Note에 폴더 필드 없음.
  - 동기화 DTO: `SyncModels.swift`(iOS)·`sync.py:24-28`(BE) folders 미포함.
- **재사용 가능한 sync 인프라**: delta-sync + LWW + soft delete가 4개 엔티티(notes/note_pages/feedbacks/chat_messages)에 확립 — 동일 패턴으로 folders 추가가 표준 경로. `sync.py:40`(pull), `sync.py:57`(push), `SyncService.swift`(pushDirty/pullChanges).
- **GRDB 마이그레이션 규칙**: 신규 `registerMigration`만 추가, 기존 블록 수정 금지 (`DatabaseService.swift` v1~v8 누적, CLAUDE.md 규칙).
- **Alembic 자동 적용**: 배포 시 app startup이 `upgrade head` 실행 ([[project_alembic_autoapply_on_deploy]]). 수동 적용 불필요.
- **홈 화면 데이터 소스**: `@State notes` ← `DatabaseService.shared.allNotes()` (`HomeView.swift:5`, `DatabaseService.swift:124-131`). 폴더 상태도 동일 패턴(`@State folders`) 추가.

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | `sync.py` push/pull의 엔티티 분기 정확한 구현(LWW 비교·upsert 코드) | `sync.py:57-90` 실제 핸들러 본문 정독 후 folder 분기 위치 확정 |
| 2 | `SyncService.swift`의 dirty 수집·pull 머지 정확한 함수 시그니처 | `SyncService.swift` pushDirty/pullChanges 본문 정독 |
| 3 | 좌측 사이드바의 좁은 폭(Split View/세로) 폴백 동작 | 사이드바 고정 폭 시 그리드가 과하게 좁아지는지 실기기 확인 → 필요 시 toolbar 토글로 접기. 데이터 계층은 무관 |
| 4 | `PushResponse.results[].entity`가 enum인지 free string인지 | `sync.py` PushResponse 정의 확인 — enum이면 "folder" 추가 필요 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| R1: note.folder_id가 아직 sync 안 된 폴더를 가리킴(기기 간 순서) | 중 | FK 강제 안 함(단순 컬럼). UI는 미존재 folder_id를 "전체"로 폴백 렌더. 폴더가 나중에 pull되면 자연 복원 |
| R2: 폴더 삭제 시 소속 노트 유실 우려 | 높 | soft delete + 소속 노트 `folder_id=NULL` 전환(§4.4). 노트 자체는 절대 삭제 안 함 |
| R3: 두 기기서 같은 폴더 동시 rename | 낮 | 기존 LWW 정책 그대로(updated_at 최신 승). 폴더는 이름만이라 충돌 영향 미미 |
| R4: GRDB 마이그레이션을 기존 블록에 추가하는 실수 | 중 | 반드시 신규 `v9_note_folders` 등록(§4.2). 코드리뷰 체크포인트 |
| R5: alembic 미적용 상태로 BE 배포 → folders 쿼리 500 | 중 | startup 자동 적용([[project_alembic_autoapply_on_deploy]]) 확인. 배포 후 `/api/sync/pull` 스모크 |
