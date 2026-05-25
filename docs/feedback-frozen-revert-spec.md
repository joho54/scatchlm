# Feedback Frozen + Revert 모델 Spec

> **Status:** Draft
> **Date:** 2026-05-25
> **Author:** auto-generated
> **Scope:** ios-app only (backend 영향 없음)

---

## 1. Background

### 1.1 현재 동작

- `NoteView`의 `requestFeedback`(NoteView.swift:488)은 **이미 stroke 기반 incremental input**으로 구현돼 있다: `newStrokes = allStrokes.dropFirst(lastFeedbackStrokeCount)` (NoteView.swift:499)로 새 stroke만 추출 → 그 영역만 cropped 이미지로 Claude API 전송. 완료 후 `lastFeedbackStrokeCount = allStrokes.count`로 갱신 (NoteView.swift:590).
- 그러나 `lastFeedbackStrokeCount`는 **`@State` 변수**(NoteView.swift:22)로만 존재한다 — DB에 영속화되지 않고, 페이지 전환/노트 재진입 시 0으로 리셋된다 (NoteView.swift:340, 451, 482).
- 카드 위치는 `calculateNextCardY`(NoteView.swift:903)에서 `max(lastRenderedBottom, strokeMaxY) + 24`로 계산. **stroke가 어디에 그려졌는지는 무관**하게 최대 Y만 본다.
- 캔버스는 단일 PencilKit 레이어. 카드는 `UIView`(`tag == 9999`) subview로 올라가 stroke 위를 덮는다.

### 1.2 문제

| # | 시나리오 | 결과 |
|---|---|---|
| 1 | 카드 영역 위에 직접 필기 | 카드 흰 배경이 stroke를 덮어 사용자에게 안 보임 (데이터는 남음) |
| 2 | 카드와 카드 *사이* 빈 공간에 필기 | `strokeMaxY < lastRenderedBottom` → 새 카드는 마지막 카드 바로 아래 추가, 새 필기와 카드의 시각적 연결 끊김 |
| 3 | 캔버스 위쪽에 실수로 점 1개 | 그 점이 `newStrokes`에 포함되어 LLM이 의도치 않은 영역까지 분석 |
| 4 | 노트 재진입 후 첫 피드백 호출 | `lastFeedbackStrokeCount = 0`이라 이미 피드백 받은 stroke까지 재전송 → 중복 분석, 토큰 낭비 |

### 1.3 모델 정의 (To-Be)

1. **Frozen**: 피드백 받은 stroke 묶음은 "확정". 그 위 새 필기 불가.
2. **단방향 입력**: 새 stroke는 `lastRenderedCardBottom` 아래에서만 입력 가능.
3. **Revert**: 카드에 `↩︎` 버튼 → 카드 삭제 + 해당 stroke 범위 frozen 해제 → 해당 영역 다시 자유.

### 1.4 Out of Scope

| 항목 | 이유 |
|---|---|
| Backend API 변경 | 현재 incremental crop이 이미 클라이언트에서 수행됨. LLM 호출 구조 그대로 |
| Crop 이미지에 frozen 영역 일부 포함 (문맥 주입) | Phase 2 — 우선 frozen/revert mental model부터 |
| PKCanvasView 자체 입력 차단 (gesture 레벨) | PencilKit이 stroke reject API를 제공하지 않음. post-hoc 제거로 대체 |
| undo/redo 시 frozen 범위 자동 보정 | Phase 2 — undo는 일단 frozen 범위 *외*에서만 동작하도록 (사용자가 frozen 안쪽을 undo하면 보호) |
| Stroke 객체 자체의 안정적 ID | PencilKit `PKStroke`에 안정 ID 없음. 이 spec은 **인덱스 + bbox 기반**으로 추적 (§4.2 참조) |
| 기존 DB row의 stroke_range backfill | **무시한다** (사용자 결정). 마이그레이션 시점에 모든 기존 row의 strokeRangeStart/End = 0. 기존 카드는 frozen으로 작동하지 않음 — 사용자가 해당 페이지에서 첫 새 피드백을 호출하면 그 시점부터 frozen 적용 |

### 1.5 기존 코드 정리 대상

- `lastFeedbackStrokeCount: Int = 0` (NoteView.swift:22) 및 그 리셋 지점 3곳(340, 451, 482) — frozen 범위가 영속화되면 이 @State는 *현재 페이지의 frozen 상한*으로 의미가 바뀌고, DB로부터 재구성된다.

---

## 2. 현재 플로우

```
[user draws] ──► canvasView.drawing.strokes += [new]
                  │
                  └─► canvasViewDrawingDidChange
                       ├─► updateNextPositionIndicator (indicator 위치 갱신)
                       └─► auto-expand contentSize.height

[user taps ✨]  ──► requestFeedback
                  ├─► newStrokes = strokes.dropFirst(lastFeedbackStrokeCount)
                  ├─► render newStrokes → image → POST /api/feedback
                  ├─► appendFeedbackCard(content) → FeedbackRecord DB save + renderCard
                  ├─► auto-scroll to new card
                  └─► lastFeedbackStrokeCount = strokes.count
```

## 3. 목표 플로우 (To-Be)

```
[user draws] ──► [pre-check] new stroke.renderBounds.minY < frozenBottom ?
                  ├─ yes → drop from strokes array + show toast
                  └─ no  → keep
                  │
                  └─► canvasViewDrawingDidChange (변경 없음)

[user taps ✨]  ──► requestFeedback
                  ├─► newStrokes = strokes[currentFrozenEndIndex...]
                  ├─► (이전과 동일하게 이미지 생성/전송)
                  ├─► appendFeedbackCard(content, strokeRangeStart, strokeRangeEnd)
                  │      └─► FeedbackRecord DB save (range 포함)
                  ├─► frozenBottom 재계산
                  └─► (lastFeedbackStrokeCount 제거 — frozen range에서 도출)

[user taps ↩︎ on card] ──► revertFeedback(fb)
                            ├─► DB delete FeedbackRecord
                            ├─► UI remove card (tag 9999)
                            ├─► frozenBottom 재계산
                            └─► 해당 stroke들은 그대로 남음 (자유 편집 가능)
```

---

## 4. 설계

### 4.1 데이터 모델

`FeedbackRecord` (Note.swift:65)에 컬럼 2개 추가:

| 필드 | 타입 | 의미 |
|---|---|---|
| `strokeRangeStart` | `Int` | 분석 대상 `strokes[]` 시작 인덱스 (inclusive) |
| `strokeRangeEnd` | `Int` | 분석 대상 `strokes[]` 끝 인덱스 (exclusive) |

DB 컬럼: `stroke_range_start`, `stroke_range_end` (snake_case).

**왜 index 기반인가** — PencilKit `PKStroke`에 안정적 ID가 없다. 그래서 다음 규칙으로 인덱스를 안정화한다:

- frozen 안쪽 stroke는 입력 차단으로 변경 금지 → 인덱스 유지됨
- undo/redo는 frozen 범위 밖에서만 동작 (Phase 2에서 보장; 현재는 사용자가 undo로 frozen 영역을 건드릴 가능성이 낮으므로 best effort)
- 페이지별로 strokes는 독립 (이미 NotePage별 drawing_data 저장됨)

### 4.2 Frozen 범위 계산

페이지 진입 시 `FeedbackRecord.feedbacks(pageId:)`로 모든 카드를 가져온 뒤:

```swift
// 인덱스 기반 — LLM input cropping에 사용
let frozenEndIndex = feedbacks.map { $0.strokeRangeEnd }.max() ?? 0

// Y 기반 — 입력 차단에 사용
let frozenBottom = feedbacks.map { $0.bboxY + $0.bboxHeight }.max() ?? 0
```

두 값은 페이지 로드 직후 + 카드 추가/삭제 시 갱신된다.

### 4.3 입력 차단

`canvasViewDrawingDidChange`(NoteView.swift:921) 시작부에 추가:

```swift
let newStrokes = canvasView.drawing.strokes
if newStrokes.count > previousStrokeCount {
    // 새로 추가된 stroke
    let added = newStrokes.suffix(newStrokes.count - previousStrokeCount)
    let invalid = added.filter { $0.renderBounds.minY < frozenBottom }
    if !invalid.isEmpty {
        let kept = newStrokes.filter { stroke in !invalid.contains(where: { $0 === stroke }) }
        // PKStroke는 struct이므로 === 사용 불가 → 별도 식별 방법 필요 (§6.3 참조)
        canvasView.drawing = PKDrawing(strokes: kept)
        showToast("이 영역은 피드백이 완료됐습니다. 되돌리려면 카드의 ↩︎를 누르세요")
    }
}
previousStrokeCount = canvasView.drawing.strokes.count
```

**식별 방법** — `PKStroke`는 struct이므로 참조 비교 불가. 대안:
1. `previousStrokeCount` 기준으로 `Array.suffix(n)`만 검사 (가장 단순; 인덱스 의존)
2. stroke의 `path`(`PKStrokePath`)의 첫 점 좌표 + creationDate 조합으로 해시

**선택**: (1) — 단순성 우선. canvasViewDrawingDidChange는 stroke 추가/삭제 시 모두 호출되므로 count 비교로 추가/삭제 구분.

### 4.4 Revert UI

`renderCard`(NoteView.swift:727)에서 `buttonBar`(NoteView.swift:770)에 두 번째 버튼 추가:

```swift
let revertBtn = UIButton(type: .system)
revertBtn.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
revertBtn.setTitle(" 되돌리기", for: .normal)
revertBtn.titleLabel?.font = .systemFont(ofSize: 12)
revertBtn.tintColor = .systemRed.withAlphaComponent(0.7)
let revertGesture = FeedbackTapGesture(target: self, action: #selector(feedbackRevertTapped(_:)))
revertGesture.feedbackRecord = fb
revertBtn.addGestureRecognizer(revertGesture)
buttonBar.addArrangedSubview(revertBtn)
```

확인 alert → 확인 시 `onFeedbackRevert?(fb)` 콜백 → NoteView가 처리:

```swift
private func revertFeedback(_ fb: FeedbackRecord) {
    try? db.deleteFeedback(id: fb.id)
    feedbacks.removeAll { $0.id == fb.id }
    if let coordinator = canvasView.delegate as? PencilKitCanvasView.Coordinator {
        coordinator.removeCard(on: canvasView, feedbackId: fb.id)
        coordinator.recalculateFrozenBottom(feedbacks: feedbacks)
    }
}
```

### 4.5 Toast UI

기존 `loading` indicator(NoteView.swift:65)와 유사한 패턴으로 `@State private var toastMessage: String?` 추가. 2초 후 자동 dismiss.

### 4.6 영속화 흐름

- 카드 생성 시 (`appendFeedbackCard`, NoteView.swift:354): `strokeRangeStart = frozenEndIndex`, `strokeRangeEnd = canvasView.drawing.strokes.count`
- 페이지 진입 시: feedbacks 로드 → frozenEndIndex / frozenBottom 계산 → Coordinator에 주입
- Revert 시: DB delete → 메모리/UI에서 제거 → 두 값 재계산

### 4.7 Frozen 영역 오버레이

사용자가 frozen 범위를 시각적으로 인지할 수 있도록 **옅은 회색 반투명 오버레이**를 frozen 영역에 깐다.

- 위치: `(0, 0) ~ (canvasView.bounds.width, frozenBottom)` 영역
- 색상: `UIColor.systemGray.withAlphaComponent(0.07)` — **잉크/카드 가독성을 해치지 않도록 매우 옅게**
- 다크모드: `UIColor.systemGray.withAlphaComponent(0.10)` (배경이 검정이라 약간 더 진하게)
- 구현: 별도 UIView (`tag == 9997`) subview로 추가. 카드(9999) / indicator(9998) / 오버레이(9997) 3계층 분리
- `isUserInteractionEnabled = false` — 터치 통과
- frozenBottom 변경 시 frame.height만 갱신 (재생성 X — indicator와 동일 패턴)
- frozenBottom = 0이면 hidden

다크모드 전환 시 색상 갱신은 `updateUIView`에서 처리.

---

## 5. 구현 단계 (Tracks)

단일 개발자 작업. 의존성 순서로 진행한다.

```
A (데이터) ──► B (frozen 상태 관리) ──► C (입력 차단) ──► D (Revert UI) ──► E (정리)
                                       ├──► F (Toast UI)
                                       └──► G (Frozen 오버레이)
```

**의존성:**
- B는 A의 마이그레이션 + 컬럼이 있어야 함
- C는 B의 frozenBottom 계산 필요
- D는 A의 deleteFeedback + B의 재계산 로직 필요
- F는 C와 병렬 가능 (UI 인프라만)
- G는 B의 frozenBottom 필요. C/D/F와 병렬 가능
- E는 모든 트랙 후

**작업량 추정** — 절대 시간 X, 상대 크기로:

### Track A: 데이터 모델 마이그레이션
**의존:** 없음
**작업량:** 작음
**핵심:** GRDB v4 마이그레이션 + 기존 row backfill 처리

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `ios-app/ScatchLM/Models/Note.swift:65-105` | `FeedbackRecord`에 `strokeRangeStart: Int`, `strokeRangeEnd: Int` 추가 + CodingKeys/Columns 갱신 |
| A-2 | `ios-app/ScatchLM/Services/DatabaseService.swift:117` 앞 | `migrator.registerMigration("v4_feedback_stroke_range")` 추가: `ALTER TABLE feedbacks ADD COLUMN stroke_range_start INTEGER NOT NULL DEFAULT 0` + `..._end INTEGER NOT NULL DEFAULT 0`. **기존 row backfill 없음** (사용자 결정 — 모두 0) |
| A-3 | `ios-app/ScatchLM/Services/DatabaseService.swift:194` 인근 | `deleteFeedback(id: String) throws` 메서드 추가 |

**검증:** 빌드 → 시뮬레이터 실행 → DB 파일에서 컬럼 존재 확인 (`PRAGMA table_info(feedbacks)`).

### Track B: Coordinator의 Frozen 상태 관리
**의존:** Track A 완료
**작업량:** 중간
**핵심:** Coordinator가 frozenBottom / frozenEndIndex 두 값을 관리하고, 카드 추가/제거 시 자동 갱신

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `NoteView.swift:670` 인근 (`Coordinator` 클래스 내부) | `var frozenBottom: CGFloat = 0`, `var frozenEndIndex: Int = 0`, `var previousStrokeCount: Int = 0` 추가 |
| B-2 | `NoteView.swift:717` `renderAllCards` 끝 | feedbacks로부터 frozenBottom/frozenEndIndex 재계산 후 저장 |
| B-3 | `NoteView.swift:781` `renderCard` 끝 (lastRenderedBottom 갱신 직후) | 같은 갱신을 frozenBottom에도 (단일 카드 추가 케이스) |
| B-4 | `NoteView.swift:354` `appendFeedbackCard` | record 생성 시 `strokeRangeStart = coordinator.frozenEndIndex`, `strokeRangeEnd = canvasView.drawing.strokes.count` 주입 |
| B-5 | `NoteView.swift:499` `requestFeedback` | `dropFirst(lastFeedbackStrokeCount)` → `dropFirst(coordinator.frozenEndIndex)`로 교체 |
| B-6 | `NoteView.swift:22, 340, 451, 482, 590` | `lastFeedbackStrokeCount` @State 및 4개 리셋/갱신 지점 제거 (frozen에서 도출) |

**검증:** 페이지 진입 시 로그로 `frozenBottom`, `frozenEndIndex` 출력 확인. 카드 추가 후 두 값이 즉시 갱신되는지 확인.

### Track C: 입력 차단
**의존:** Track B 완료
**작업량:** 중간
**핵심:** 새 stroke의 minY < frozenBottom이면 즉시 strokes 배열에서 제거. count 비교 기반.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `NoteView.swift:921` `canvasViewDrawingDidChange` 시작부 | `strokes.count`와 `previousStrokeCount` 비교 → 증가했으면 `suffix(diff)` 검사 → invalid 발견 시 valid stroke만으로 `PKDrawing` 재구성 후 `canvasView.drawing = ...` 설정 |
| C-2 | 같은 함수 끝 | `previousStrokeCount = canvasView.drawing.strokes.count` 갱신 |
| C-3 | `NoteView.swift:921` | invalid가 있으면 `onStrokeRejected?()` 클로저 호출 (NoteView가 토스트 띄움) |
| C-4 | `PencilKitCanvasView` `Coordinator` init/struct | `var onStrokeRejected: (() -> Void)?` 추가 + makeCoordinator에서 주입 |

**검증:**
- frozen 카드 위에 마우스로 stroke 그리기 → 즉시 사라지고 토스트
- 카드 아래에 stroke 그리기 → 정상 유지
- 로그: `[fe][canvas] stroke rejected count=<n>`

### Track D: Revert UI + 로직
**의존:** Track A (deleteFeedback) + Track B (frozenBottom 재계산)
**작업량:** 중간
**핵심:** 카드에 ↩︎ 버튼, 확인 alert, DB+UI 정리, frozen 갱신

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `NoteView.swift:727` `renderCard` 내부 buttonBar | 채팅 버튼 옆에 revert 버튼 추가 (SF Symbol: `arrow.uturn.backward`) |
| D-2 | `Coordinator` 내부 | `@objc func feedbackRevertTapped(_:)` + `var onFeedbackRevert: ((FeedbackRecord) -> Void)?` 추가 |
| D-3 | `Coordinator` 내부 | `func removeCard(on: feedbackId:)` — `subviews.filter { ($0.tag == 9999) && (찾기) }`. 카드 view에 fb.id를 accessibilityIdentifier로 저장하여 식별 |
| D-4 | `Coordinator` 내부 | `func recalculateFrozenBottom(feedbacks:)` 추가 (B-2와 같은 로직) |
| D-5 | `NoteView.swift` body 또는 ZStack | revert 확인 alert (`.alert("이 피드백을 되돌리시겠습니까?", ...)`) — `@State private var pendingRevert: FeedbackRecord?` |
| D-6 | `NoteView.swift` | `revertFeedback(_:)` 메서드 — DB delete → feedbacks.removeAll → Coordinator.removeCard → Coordinator.recalculateFrozenBottom |
| D-7 | `PencilKitCanvasView` init | `onFeedbackRevert: ((FeedbackRecord) -> Void)?` propagation |

**검증:**
- 카드의 ↩︎ 탭 → alert → 확인 → 카드 사라짐, DB row 삭제, frozenBottom 감소
- 그 영역에 다시 stroke 가능
- 페이지 재진입 후에도 삭제된 카드 안 나타남

### Track G: Frozen 영역 오버레이
**의존:** Track B 완료
**작업량:** 작음
**핵심:** 옅은 회색 반투명 UIView를 frozen 영역에 배치, frozenBottom 갱신마다 frame.height 조정

| ID | 파일 | 내용 |
|---|---|---|
| G-1 | `NoteView.swift` `Coordinator` 내부 | `func updateFrozenOverlay(on canvasView:)` 추가 — viewWithTag(9997) 조회 → 없으면 생성 (옅은 회색, `isUserInteractionEnabled = false`), frame = `(0, 0, width, frozenBottom)`. frozenBottom == 0이면 `isHidden = true` |
| G-2 | B-2, B-3, D-6의 frozenBottom 갱신 직후 | `updateFrozenOverlay(on: canvasView)` 호출 추가 |
| G-3 | `PencilKitCanvasView.updateUIView` (NoteView.swift:659 인근) | 다크모드 전환 시 오버레이 색상 갱신 (`backgroundColor` 재설정) |

**검증:**
- 카드가 있는 페이지 진입 시 frozen 영역에 옅은 회색 오버레이 표시
- 카드 추가 시 오버레이 영역이 새 카드 하단까지 확장
- Revert 시 오버레이 축소
- 다크모드에서 오버레이가 너무 진하거나 옅지 않은지 시각 검증
- 잉크/카드 텍스트가 오버레이 위에서 그대로 읽히는지 확인

### Track F: Toast UI
**의존:** 없음 (Track C와 병렬 가능)
**작업량:** 작음

| ID | 파일 | 내용 |
|---|---|---|
| F-1 | `NoteView.swift:19` 인근 @State 블록 | `@State private var toastMessage: String?` |
| F-2 | `NoteView.swift:64-79` loading indicator 인접 | toast view (Capsule + ultraThinMaterial + auto-dismiss after 2s) |
| F-3 | `NoteView.swift` | `func showToast(_:)` 헬퍼 — Task로 2초 후 nil로 |

### Track E: 정리 + 검증
**의존:** 모두 완료
**작업량:** 작음

| ID | 파일 | 내용 |
|---|---|---|
| E-1 | `NoteView.swift` | dead code 제거, 로그 정리 (`[fe][note] frozen update from=...` 등 디버그 로그 정돈) |
| E-2 | `ios-app/ScatchLMTests/` | revert + 입력 차단 시나리오 수동 테스트 체크리스트 작성 (자동화는 PencilKit 의존성으로 어려움) |
| E-3 | `CLAUDE.md` | 새 데이터 모델 (`stroke_range_*`) 한 줄 추가 |
| E-4 | manual QA | §5 각 트랙의 "검증" 항목 + edge case (회전, PDF 토글로 view rebuild) |

---

## 6. 확인 완료 사항 (코드 검증)

| # | 확인 항목 | 검증 결과 |
|---|---|---|
| 1 | `FeedbackRecord`의 현재 필드 구조 | `Note.swift:65-105` — id, noteId, pageId?, content, positionX/Y, bboxX/Y/W/H, createdAt. stroke 관련 필드 없음 |
| 2 | DB 마이그레이션 최신 버전 | `DatabaseService.swift:78` — `v3_note_pages`가 마지막. v4가 다음 |
| 3 | `requestFeedback`의 incremental crop 여부 | `NoteView.swift:497-499, 507-517` — `dropFirst(lastFeedbackStrokeCount)`로 이미 구현됨. `newDrawing.image(from: bounds)`로 cropped 이미지 생성 |
| 4 | `lastFeedbackStrokeCount` 영속화 여부 | `NoteView.swift:22` — `@State`로만 존재. DB 저장 X. 페이지 전환 시 리셋(340, 451, 482) |
| 5 | 카드 식별을 위한 unique key | 현재 카드 UIView는 `tag == 9999`만 부여(NoteView.swift:737). id 식별 불가 → D-3에서 `accessibilityIdentifier`로 부여 필요 |
| 6 | `deleteFeedback` 메서드 존재 여부 | `DatabaseService.swift:183-198` — `saveFeedback` / `feedbacks(noteId:)` / `feedbacks(pageId:)` 만 있음. delete 없음 → A-4 신규 |
| 7 | Toast/Alert 인프라 | 토스트 컴포넌트 없음 (loading indicator만 있음, NoteView.swift:65-79). Alert는 SwiftUI 기본 `.alert()` 사용 가능 |
| 8 | PencilKit stroke ID | `PKStroke`는 struct, 안정 ID 없음 → 인덱스 기반 추적으로 진행 (§4.2) |
| 9 | `canvasViewDrawingDidChange`의 호출 빈도 | `NoteView.swift:921` — stroke 추가/삭제/수정 시 매번 호출. saveTimer로 2초 debounce된 save가 있음(NoteView.swift:947-949) |

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| U-1 | PKDrawing 재할당(`canvasView.drawing = PKDrawing(strokes:)`)이 UI에 깜빡임을 유발하는지 | C-1 구현 후 시뮬레이터 실측. 깜빡이면 stroke의 path를 빈 path로 교체 등 대안 검토 |
| U-2 | revert 후 그 영역의 stroke를 *자동 삭제*할 것인가, 보존할 것인가 | 본 spec은 **보존** — 사용자 의도일 수 있음. 별도 "stroke까지 삭제" 옵션은 Phase 2 |
| U-3 | 오버레이 alpha 값(0.07 light / 0.10 dark)이 실제 기기에서 적절한지 | G-1 구현 후 시뮬레이터 + 실기기에서 시각 검증. 잉크 가독성 vs frozen 인지 가능성 균형 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| **R-1** PKDrawing 재할당이 매 stroke마다 발생하면 성능 저하 / 깜빡임 | 사용자 체감 lag | C-1에서 valid 케이스(차단 발생 안 함)는 PKDrawing 재할당 스킵. invalid stroke가 있을 때만 재할당. invalid는 드물어야 함 (사용자가 의도적으로 frozen 영역에 그릴 때만) |
| **R-2** 기존 DB row의 stroke_range가 (0, 0)이라 마이그레이션 직후 기존 카드는 frozen으로 작동하지 않음 | 기존 노트에 한해 입력 차단/오버레이 미작동. 사용자가 그 페이지에서 새 피드백 호출 후부터 정상 작동 | **수용 결정 (사용자 합의)**. 기존 데이터 무시. 별도 backfill/마이그레이션 안내 없음 — 새 노트부터 깨끗하게 동작 |
| **R-3** undo로 frozen 안쪽 stroke를 사용자가 삭제 → 인덱스 어긋남 | 다음 피드백 호출 시 잘못된 stroke 범위 전송 | Phase 1: undo 제스처를 frozen 범위 외에서만 허용 (`PKCanvasView.undoManager?.canUndo`만으로는 구분 불가 → 별도 검토). 또는 매 호출 직전에 strokes.count vs frozen index 정합성 검사 후 mismatch면 frozen 재계산 |
| **R-4** view rebuild로 Coordinator가 새로 만들어지면 `frozenBottom` 초기값이 0 → 입력 차단이 잠시 비활성 | 회전/PDF 토글 직후 stroke가 frozen 영역에 들어갈 수 있음 | `renderAllCards`(B-2)가 새 Coordinator의 첫 호출에서 항상 재계산 보장. `previousStrokeCount`도 함께 초기화 |
| **R-5** Revert로 frozen 범위가 줄었지만, 그 사이에 그려진 stroke가 frozenEndIndex 뒤로 밀려 신규 카드의 strokeRangeStart에 포함 | 사용자가 revert 후 그 영역에 그린 새 필기까지 다음 피드백에 묶임 | 의도된 동작으로 본다 — revert는 "이 영역을 다시 자유로 만든다"는 의미이고, 그 다음 피드백은 자유 영역의 모든 새 stroke를 분석함 |
| **R-6** Toast 메시지가 너무 자주 떠서 거슬림 | UX 저하 | 토스트는 직전 2초 이내 같은 메시지면 무시 (debounce) |

---

## 8. Decisions (사용자 확정 2026-05-25)

- ✅ **Revert는 alert 확인 후** 처리 (D-5)
- ✅ **Frozen 영역 오버레이 깐다** — 옅게(잉크 가독성 유지). Track G로 추가 (§4.7)
- ✅ **기존 DB row backfill 안 함** — A-2 단순화, R-2 수용
- 페이지 전환 시 frozenBottom/frozenEndIndex 갱신은 `loadPage`(NoteView.swift:331 인근) → `renderAllCards` → B-2에서 보장
