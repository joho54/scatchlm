# Frozen 영역 빨강 주석 (Frozen-Region Red Annotation) Spec

> **Status:** 보류 (출시 후) — 설계 동결, 우선순위 뒤로 미룸
> **Date:** 2026-06-02
> **Author:** (auto-generated)
> **Scope:** iOS only (`ios-app/`). 백엔드/API 변경 없음.

---

## 0. 보류 사유 (왜 지금 안 하나)

**구현이 불가능해서가 아니라 출시 우선순위 뒤이기 때문.** 최근 작업은 출시 준비(Track A–H, Sentry). 이 기능은 core가 아니라 polish — 현재 거부 동작도 기능적으로 동작한다.

1차 구현 실패 후 "너무 어렵다"는 인상의 8할은 **불필요한 2-스크롤-캔버스 아키텍처**에서 왔다. 이 스펙은 그 헛고생을 들어내고 격리만 살린 형태로 동결한다 → 재개 시 출발점이 명확하다.

---

## 1. Background

### 1.1 현재 동작 (리버트 후, 메인라인)

피드백을 받은(=frozen) 영역에 다시 필기하면 **거부**(reject) — 입력을 되돌려 사라지게 한다.

- frozen 거부 가드: `NoteView.swift:1308-1322` (`canvasViewDrawingDidChange`). `frozenBottom > 0 && strokes.count > previousStrokeCount`일 때 `minY < frozenBottom` stroke를 `PKDrawing(strokes: kept)`로 제거 + `onStrokeRejected?()`.
- `frozenBottom`/`frozenEndIndex`는 **DB 비영속, 런타임 파생**: `NoteView.swift:1007-1017` (`recalculateFrozenBottom`).
  - `frozenBottom = max(feedback.bboxY + bboxHeight)`
  - `frozenEndIndex = max(feedback.strokeRangeEnd)`
- 피드백 캡처: `allStrokes.dropFirst(frozenEndIndex)`로 신규 stroke만 → `PKDrawing` → JPEG: `NoteView.swift:725-836` (`requestFeedback`), `APIClient.swift:98-139` (`postMultipart`).
- 되돌리기: **마지막 카드만**, soft-delete, **stroke 미삭제**: `NoteView.swift:660-674` (`revertFeedback`).
- 직렬화: 단일 `PKDrawing.dataRepresentation()` → `note_pages.drawing_data` (BLOB): `Note.swift:254-316`, `DatabaseService.swift:483` (`savePageDrawing`).

### 1.2 목표 UX (재구현 후)

frozen 영역에 필기하면 거부하는 대신:

1. **자동으로 빨강(주석)으로 표시** — "새 학습이 아니라 받은 피드백에 대한 메모"라는 신호.
2. **다음 피드백 대상에서 제외** — 주석은 채점 대상 아님.
3. **해당 피드백 되돌리기 시 함께 삭제** — 피드백과 메모가 한 묶음.

멘탈 모델: **"빨강 = 주석"**.

### 1.3 소유권 모델 (확정: 세로 band 방식)

피드백 #N이 동결한 구간 = `[이전 frozenBottom, 이번 frozenBottom)`.
되돌리기 시 그 band 안의 **빨강 stroke만 삭제**, 검정 콘텐츠는 보존(동결만 풀려 재요청 대상 복귀).
이전 피드백 영역의 빨강은 `minY < 새 frozenBottom`이라 생존.
→ per-stroke 소유권 추적 불필요, 순수 공간 계산으로 성립.

### 1.4 Out of Scope

| 항목 | 이유 |
|---|---|
| 백엔드/API 변경 | 피드백 API는 캡처된 이미지만 받는다. 캡처 대상 선정만 바뀜 → 계약 불변. §3. |
| GRDB 스키마 변경 / 마이그레이션 | 단일 blob 유지. 색·분류를 blob+geometry에서 파생. §4.4. |
| `drawing_hash` 재정의 / 클라우드 sync 변경 | 단일 blob 머지 유지 → 해시 정의 불변, sync 무영향. §4.4. |
| 멀티 band 부분 되돌리기 UI | 마지막 카드만 revert 정책 유지(`NoteView.swift:660-674`). |
| 주석 색 커스터마이즈 | 주석 = 고정 빨강. |

---

## 2. 핵심 결정: 격리는 core, 2-스크롤-캔버스는 불필요

### 2.1 왜 격리가 필요한가 (양보 불가)

단일 평면 PKCanvasView에서는 frozen 콘텐츠를 확실히 보호할 수 없다. 증거:

- **버그 2 (eraser):** frozen 가드가 stroke 증가만 검사(`NoteView.swift:1310`)하므로 지우개(stroke 감소)는 frozen 콘텐츠를 지운다. count 기반 가드로는 **원리적으로** 못 막는다.
- **버그 1 (undo desync):** 빨강 재색칠을 `canvasView.drawing = PKDrawing(strokes: mutated)` **통째 swap**으로 구현 → PencilKit undo 매니저는 사용자 액션만 추적하므로 swap이 undo 스택과 어긋남.

→ **frozen 콘텐츠를 편집 가능한 drawing에서 물리적으로 빼내야** 격리가 성립한다. 이건 양보 불가.

### 2.2 격리 ≠ 두 번째 스크롤 캔버스

1차 구현/이전 스펙 초안의 난점은 "두 PKCanvasView를 형제로 겹치고 contentOffset/contentSize를 동기화"하는 부분이었다. **격리에 그게 필요하지 않다.**

**핵심: frozen 레이어를 활성 캔버스의 비-인터랙티브 subview로 둔다.**

이미 동작하는 패턴이다 — 피드백 카드(tag 9999), frozen 오버레이(tag 9997), 가이드라인(tag 9998)은 전부 PKCanvasView의 subview로 content 좌표에 앵커되어 **스크롤과 자동으로 함께 움직인다**(`NoteView.swift:1019-1054`, `1059-1209`). 별도 동기화 코드가 없다.

```
┌─ 활성 PKCanvasView (유일한 스크롤 소스) ───────────┐
│  drawing: 신규 검정 + 빨강 주석                     │  ← 입력/지우개/undo 담당
│  ┌─ subview: frozen 레이어 (비-인터랙티브) ───────┐ │
│  │  frozen PKDrawing 렌더 (검정, 읽기 전용)        │ │  ← 활성 drawing에 없음 →
│  │  isUserInteractionEnabled=false                 │ │     지우개/undo가 못 건드림
│  │  content 좌표 앵커 → 스크롤 자동 추종            │ │
│  └─────────────────────────────────────────────────┘ │
│  + 카드(9999) + 오버레이(9997) + 가이드라인(9998)     │
└───────────────────────────────────────────────────────┘
```

이러면:
- frozen 콘텐츠가 **활성 drawing에 존재하지 않으므로** 지우개/undo가 절대 못 건드림 → **버그 2 해결**.
- 스크롤 소스가 **하나** → 동기화/지터 문제 증발(이전 스펙 §6.4 불필요).
- frozen 레이어는 복원을 위해 **PKDrawing으로 보유**(이미지 아님), 표시용으로 렌더.

빨강 색칠은 swap이 아니라 **입력 시점 펜 색 지정**으로 → 버그 1 회피(§2.3).

### 2.3 빨강 색칠 (swap 금지) — 본질적 난점

frozen 영역에 들어가는 stroke를 **입력 시점에** 빨강으로 만들어야 한다(사후 swap 금지). `canvasViewDrawingDidChange`는 stroke 완료 후 발화하므로 사전 색 지정이 어렵다. 두 방안 — §6.2에서 spike로 결정:

- **(a) 도구 자동 전환 (권장):** 펜이 frozen y-범위에 진입하면 `canvasView.tool`을 빨강 펜으로 전환, 벗어나면 복귀. touch 위치 감지(보조 `UIGestureRecognizer` 등) 필요.
- (b) 사후 단일 stroke 재생성: undo desync 회피 방법 검증 필요 — 위험.

이 난점은 **2-캔버스든 subview든 동일하게 마주친다** — 격리 방식이 풀어주지 않는 이 기능 고유의 작업.

---

## 3. Backend API Inventory & Contracts

**백엔드 변경 없음. 계약 동결 대상 없음.**

| Method | Path | 설명 | 상태 |
|---|---|---|---|
| POST | `/api/feedback` | 캔버스 이미지 → 피드백 | **변경없음** |

근거: `requestFeedback`(`NoteView.swift:725-822`)는 신규 stroke로 만든 `PKDrawing`을 JPEG로 렌더해 multipart `image`로 전송. 레이어 분리 후에도 "활성 drawing의 비-주석 stroke"를 같은 방식으로 캡처 → 스키마 불변.

---

## 4. 구현 설계

### 4.1 frozen 레이어 (subview)

- `PencilKitCanvasView`/`Coordinator`(`NoteView.swift:849-1345`)에 frozen 레이어 추가.
- frozen된 strokes를 담는 `frozenDrawing: PKDrawing`(Coordinator 상태)을 유지.
- 표시: 비-인터랙티브 subview(`isUserInteractionEnabled=false, isScrollEnabled=false`인 PKCanvasView, 또는 렌더 이미지). content 좌표 전체 frame에 앵커 → 스크롤 자동 추종. 카드/오버레이와 동일 부착 방식.
- 새 전용 tag 부여(예: 9996), z-order는 오버레이(9997) 위·카드(9999) 아래로 확정 → §6.3.

### 4.2 frozen 승급 (promotion)

피드백 확정(`appendFeedbackCard`, `NoteView.swift:459-546`) 시:
1. 활성 `drawing`에서 band `[frozenEndIndex, currentCount)` 중 **빨강 아님(검정)** stroke를 `frozenDrawing`에 append.
2. 같은 stroke를 활성 `drawing`에서 제거.
3. 빨강 주석은 활성 drawing에 잔류(되돌리기 대상).
4. frozen 레이어 subview 재렌더 + `recalculateFrozenBottom`(`1007-1017`).

### 4.3 빨강 주석 입력

§2.3 권장 (a): frozen y-범위 진입 시 도구를 빨강 펜으로 자동 전환. 기존 거부 로직(`NoteView.swift:1308-1322`)을 **거부 → 빨강 허용**으로 교체.

### 4.4 데이터 모델 / 직렬화 — 단일 blob 유지

**스키마 변경 없음.** PencilKit `dataRepresentation()`은 stroke별 ink 색을 직렬화하므로 빨강은 blob에 이미 보존된다.

- **Save (`savePageDrawing`, `DatabaseService.swift:483`):** `frozenDrawing.strokes ++ activeDrawing.strokes`를 머지해 단일 `PKDrawing` → 기존 단일 blob. `drawing_hash` 정의 불변 → 클라우드 sync(v7) 무영향.
- **Load:** 단일 blob → `PKDrawing` → geometry+색으로 partition:
  - frozen 레이어 = 검정 + `minY < frozenBottom`
  - 활성 drawing = 나머지(신규 검정 + 빨강 주석)
  - `frozenBottom`은 feedbacks에서 파생(`recalculateFrozenBottom`)되므로 partition 기준이 결정적.

**머지 순서 = `frozen ++ active`가 원래 append 순서와 일치해야** feedbacks의 `strokeRangeStart/End`(`Note.swift:118-228`, GRDB v4) 절대 인덱스가 유지된다 → §6.1 검증.

### 4.5 피드백 대상 선정

`requestFeedback`(`725-836`): 활성 drawing의 `dropFirst(frozenEndIndex)` 중 **빨강 아님** stroke만 캡처. 주석/빈 경우 스킵(`739-742` 패턴 유지).

### 4.6 되돌리기 (band 기반)

`revertFeedback`(`660-674`) 확장:
1. 해당 feedback band `[strokeRangeStart 대응 Y, bboxY+bboxHeight)` 계산.
2. `frozenDrawing`에서 band 내 검정 stroke를 활성 drawing으로 복귀(동결 해제).
3. 활성 drawing에서 band 내 **빨강 주석 stroke 삭제**.
4. frozen 레이어 재렌더 + feedback soft-delete + `recalculateFrozenBottom`.

---

## 5. 구현 단계 (Tracks)

```
시작 ─── A: frozen-subview 격리 코어 (블로커)
              │
        A 완료 ┼── B: 빨강 주석 입력 (색칠 spike 의존)
              │
        B 완료 ┼── C: 승급·되돌리기·캡처 band 로직
              │
        C 완료 └── D: 저장/로드 머지·partition + 회귀
```

**병렬성:** 거의 전부 `NoteView.swift`의 `PencilKitCanvasView`/`Coordinator` 단일 영역 → 진짜 병렬성 낮음. 순차 권장. 1~2명.

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | A → B → C → D 순차 |
| 2명 | P1: A·C, P2: B(색칠 spike·입력)·D(저장/회귀) |

### Track A: frozen-subview 격리 코어
**의존:** 없음 (블로커)
**작업량:** 중간. 가장 복잡: subview 부착·z-order·content 좌표 앵커(§6.3), frozenDrawing 상태 도입.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `NoteView.swift:955-1054` (`Coordinator`) | `frozenDrawing: PKDrawing` 상태 + frozen 레이어 subview(tag 9996) 생성·재렌더 메서드. |
| A-2 | `NoteView.swift:1028-1054` (overlay) 인접 | frozen 레이어 z-order: 오버레이(9997) 위, 카드(9999) 아래. content 좌표 앵커. |
| A-3 | `NoteView.swift:1308-1322` | 기존 거부 가드 제거(격리로 대체). 버그 2(eraser) 해소 확인. |

### Track B: 빨강 주석 입력
**의존:** A 완료. **색칠 spike(§6.2) 선행.**
**작업량:** 중간. 가장 복잡: 입력 시점 빨강 강제 + undo 무결(버그 1 재발 방지).

| ID | 파일 | 내용 |
|---|---|---|
| B-0 | (spike) | frozen 진입 시 도구 자동 빨강 전환 PoC + undo 무결 검증(§6.2). |
| B-1 | `NoteView.swift:1302-1343` (didChange) | frozen y-범위 진입 시 빨강 펜 전환, 벗어나면 복귀. |

### Track C: 승급·되돌리기·캡처 band
**의존:** B 완료
**작업량:** 중간. 가장 복잡: band stroke 이동 정확도.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `NoteView.swift:459-546` (`appendFeedbackCard`) | 승급: 활성 검정 stroke → frozenDrawing, 주석 잔류, 레이어 재렌더. |
| C-2 | `NoteView.swift:725-836` (`requestFeedback`) | frozenEndIndex 이후 + 빨강 아님만 캡처. |
| C-3 | `NoteView.swift:660-674` (`revertFeedback`) | band: frozenDrawing→활성 복귀 + band 내 빨강 삭제. |

### Track D: 저장/로드 + 회귀
**의존:** C 완료
**작업량:** 작음~중간. 가장 복잡: 머지/partition 인덱스 안정성(§6.1).

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `NoteView.swift` save/load (`560-589`), `DatabaseService.swift:483` | save: `frozen ++ active` 머지 → 단일 blob. load: geometry+색 partition. 스키마 불변. |
| D-2 | (수동/QA) | undo가 주석에만 작동·frozen 불가침. eraser가 frozen 못 건드림. save→load 후 색·승급 보존. revert가 band 빨강만 삭제. |
| D-3 | 빌드 검증 | CLAUDE.md 정책: 실기기 + 시뮬레이터 둘 다 컴파일. |

---

## 6. 확인 완료 사항 (코드 검증)

- **frozen 거부(현재):** `NoteView.swift:1308-1322` — `minY < frozenBottom` stroke 제거 + `onStrokeRejected?()`. 빨강화 아닌 거부.
- **frozen 파생(비영속):** `NoteView.swift:1007-1017` — feedbacks에서 `frozenBottom`/`frozenEndIndex` 런타임 계산, DB 저장 안 함, 페이지 로드 시 리셋.
- **subview 스크롤 추종(격리 설계의 전제):** 카드(9999)·오버레이(9997)·가이드라인(9998)이 캔버스 subview로 content 좌표 앵커되어 스크롤과 함께 이동 — `NoteView.swift:1019-1054`(overlay), `1059-1209`(cards). frozen 레이어도 동일 방식 적용 가능.
- **피드백 캡처 범위:** `NoteView.swift:725-836` — `dropFirst(frozenEndIndex)` → `PKDrawing` → JPEG. API 계약 불변(`APIClient.swift:98-139`).
- **stroke range 기록:** `FeedbackRecord.strokeRangeStart/End`(`Note.swift:118-228`, GRDB v4 `DatabaseService.swift:147`).
- **revert 정책:** `NoteView.swift:660-674` — 마지막 카드만, soft-delete, stroke 미삭제.
- **직렬화:** 단일 `drawing_data` BLOB(`Note.swift:260`, `savePageDrawing:483`), sha256 `drawing_hash`(v7 sync). PencilKit `dataRepresentation()`이 stroke별 색 보존 → 단일 blob으로 빨강 표현 가능.
- **eraser 선재 버그:** `NoteView.swift:1310` count 기반 가드는 stroke 감소를 못 막음 → frozen 레이어를 활성 drawing에서 빼내(subview)야 해소.

### 6.x 미확인 항목
| # | 항목 | 확인 방법 |
|---|---|---|
| 6.1 | 머지(`frozen ++ active`)·partition이 feedbacks 절대 인덱스(`strokeRangeStart/End`)를 보존하는가 | save→load 라운드트립 + 인덱스 검증 |
| 6.2 | 입력 시점 빨강 강제(도구 자동전환) + undo desync 회피 가능 여부 | Track B-0 spike (1~2h) |
| 6.3 | frozen 레이어 subview의 z-order·터치 패스스루(입력 비방해) | 2-레이어 PoC 터치/스크롤 테스트 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 빨강 재색칠 swap으로 undo desync 재발(버그 1) | 1차 실패 반복 | swap 금지, 입력 시점 도구 전환(§2.3 a). B-0 spike에서 undo 회귀 필수. |
| 머지/partition 인덱스 드리프트 | feedbacks band 오작동 | §6.1 라운드트립 검증. 머지 순서 = 원 append 순서 보장. |
| frozen subview z-order 오선택으로 터치 막힘 | 입력 불가 회귀 | §6.3 PoC에서 패스스루 검증. |
| 단일 파일(`NoteView.swift`) 집중 → 병렬성 낮음 | 일정 직렬화 | 1~2명. A를 최우선 블로커로. |
| 빨강 펜을 사용자가 실제 콘텐츠에 의도적으로 사용 | 주석 오분류 | geometry 가드(frozen 위만 주석)로 완화. 색 커스터마이즈는 out of scope(§1.4). |

---

## 8. 폐기된 대안 (왜 안 하나 — 재개 시 헷갈리지 말 것)

| 대안 | 폐기 이유 |
|---|---|
| **2-스크롤-캔버스** (두 PKCanvasView 형제로 겹쳐 contentOffset/contentSize 동기화) | 격리는 되지만 스크롤 동기화/지터가 난점의 핵심. frozen을 subview로 두면 동일 격리를 단일 스크롤 소스로 달성 → 불필요. |
| **GRDB v8 칼럼 분리** (content/active blob 두 컬럼) | content/active 구분은 frozenBottom·색에서 파생 가능(중복 저장). 마이그레이션이 기존 blob 디코드·분할 필요(데이터 손상 위험), `drawing_hash` 재정의로 sync 위험. 단일 blob 머지로 대체. |
| **단일 평면 + 가드 강화** | eraser는 stroke를 줄이므로 count 가드(`NoteView.swift:1310`)로 원리적으로 못 막음 → 격리 불가. |
