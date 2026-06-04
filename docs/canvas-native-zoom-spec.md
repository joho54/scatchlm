# 캔버스 네이티브 줌 (PencilKit 오버레이 + 자체 스크롤뷰) Spec

> **Status:** Z-2~Z-5 구현 완료(커밋 `b53ed17`·`1f73f0b`·`a2243a6`, main). Z-1 PoC·Z-6 회귀의 **실기기 검증 대기** — §9 체크리스트 참조. (이 환경엔 iPad 미연결이라 자동/시뮬레이터로 가능한 부분은 모두 검증: 컴파일·무크래시 런치·줌 수식/좌표불변 단위 테스트 20/20 통과.)
> **Date:** 2026-06-04
> **Author:** (auto-generated)
> **Scope:** iOS only (`ios-app`). 백엔드/API 변경 없음.
> **선행 문서:** `docs/landscape-canvas-autofit-spec.md` (Option A = 고정 논리폭 + 레터박스, 구현 완료). 본 스펙은 그 문서의 **Option C(줌-투-핏 페이지)** 를 "제대로" 구현하는 후속 작업이다.

---

## 0. 한 줄 요약

가로 모드에서 PDF를 넓게 두면 캔버스 패널이 페이지 폭(논리폭)보다 좁아진다. Option A는 이를 **divider clamp(가로 PDF ~25–30% 상한)** 로 회피했고, SwiftUI `scaleEffect`로 캔버스를 통째로 축소하려던 시도는 **PencilKit stroke 레이어와 카드 subview가 변환을 따로 타서** 좌표가 깨졌다(리버트됨, `d7b3f19`). 근본 해법은 **"줌되는 콘텐츠 뷰 하나"에 stroke·카드·오버레이를 전부 자식으로 넣고, 줌/스크롤을 자체 `UIScrollView`가 네이티브로 담당**하게 하는 GoodNotes식 구조다. PencilKit을 "스크롤 주체"에서 "투명한 그리기 오버레이"로 강등시키는 **아키텍처 전환**이며, 좌표·렌더·저장/캡처 경로가 전부 새 구조를 타는지 검증해야 한다.

---

## 1. Background

### 1.1 현재 상태 (Option A 구현 완료 기준)

캔버스는 `PencilKitCanvasView`(UIViewRepresentable, `NoteView.swift:858`~)이고, **`PKCanvasView` 자신이 스크롤 주체**다:
- `canvasView.isScrollEnabled = true`, `alwaysBounceVertical = false` (`NoteView.swift:954-955`) — 세로 스크롤 고정폭 "무한 종이".
- `contentSize.width`는 항상 `bounds.width`를 추종(Option A의 Track P), `bounds.width`는 SwiftUI `frame(width: 논리폭)`으로 논리폭에 고정.
- 가로에서 패널이 논리폭보다 넓으면 회색 레터박스로 종이를 중앙 배치.
- 피드백 카드(tag 9999)·frozen 오버레이(tag 9997)·next-position indicator(tag 9998)는 전부 **`canvasView`에 직접 `addSubview`** 된다 (`:1139, :1301, :1354`).

**Option A의 한계 (본 작업의 동기):**
- 가로 PDF 폭이 `1 - 논리폭/화면폭`(≈25–30%)으로 제한됨 — 캔버스가 논리폭 미만이 되지 않게 divider를 clamp하기 때문.
- 캔버스가 논리폭 미만이 되면(=clamp를 풀면) stroke가 잘려 안 보이거나(가로 스크롤 없음), 카드 폭이 줄어 리플로우/리렌더 churn 발생.
- `scaleEffect`로 줌을 흉내내면 깨짐 → §1.2.

### 1.2 `scaleEffect`가 깨진 이유 (확인됨)

SwiftUI `scaleEffect`는 **바깥에서** `PencilKitCanvasView`의 호스트 레이어에 affine 변환을 건다. PencilKit은 자신이 변환됐다는 걸 모르고 stroke를 자기 `bounds` 기준으로 렌더하며, 우리가 `canvasView`에 형제로 붙인 카드 subview는 별도 레이어라 변환 합성이 stroke와 어긋난다 → **카드·stroke 정렬 붕괴**(시뮬레이터에서 재현·리버트, `d7b3f19`).

### 1.3 목표 구조 — PencilKit "오버레이 + 자체 스크롤뷰"

`UIScrollView`는 줌 시 델리게이트 `viewForZooming(in:)`이 반환하는 **단 하나의 뷰**에만 변환을 적용하고, 줌/팬/좌표 매핑·stroke 재래스터화를 **내부에서** 처리한다(= 네이티브 줌, 펜 입력·선명도 정상). 따라서 stroke·카드를 **그 한 뷰의 자식**으로 모으면 같이 줌되어 어긋나지 않는다.

```
HostScrollView (UIScrollView, 신규·우리 소유)   ← 줌/팬/세로스크롤 주체
 ├─ delegate.viewForZooming(in:) → contentView
 └─ contentView (UIView, 줌 대상; frame = (논리폭, 동적 높이))
     ├─ PKCanvasView (그리기 전용; isScrollEnabled=false; frame = contentView.bounds)
     ├─ frozen overlay (tag 9997)
     ├─ feedback cards (tag 9999)
     └─ next-position indicator (tag 9998)
```

- **PencilKit 강등:** `PKCanvasView.isScrollEnabled = false` → 스크롤/줌은 HostScrollView가 담당, 캔버스는 그리기만.
- **줌-투-핏:** 회전·divider로 패널 폭이 바뀌면 `host.zoomScale = min(1, 패널폭/논리폭)`로 폭 맞춤. 패널이 논리폭보다 넓으면 zoomScale=1 + 중앙 인셋(레터박스). 좁으면 zoomScale<1로 페이지 전체가 작게 보임(잘림·리플로우 없음).
- **보너스:** 핀치 줌(`minimumZoomScale`/`maximumZoomScale`)을 거의 공짜로 얻음.

### 1.4 Out of Scope

| 항목 | 이유 |
|---|---|
| 백엔드/API 변경 | 좌표·렌더·줌·분할 비율 전부 클라이언트. 피드백 좌표는 로컬 GRDB만 |
| 손글씨 reflow | 기술적으로 불가 (네이티브 줌은 reflow가 아니라 스케일) |
| PDF 패널 내부 줌 | 별개 컴포넌트(`pdfPanel`) |
| 영속 좌표 마이그레이션 | **불필요** — 논리폭·stroke·카드 좌표계 자체는 안 바뀜(줌은 표시만). §6-7 참조 |
| Android/RN | 해당 없음 (레거시) |

### 1.5 기존 코드 정리 대상

| 대상 | 위치 | 처리 |
|---|---|---|
| Option A 레터박스 `frame(width:)` 중앙배치 | `canvasPanel` (`NoteView.swift:253`~) | HostScrollView 중앙 인셋으로 대체 |
| 가로 divider clamp 상한(`1 - logical/total`) | Option A 구현분 (현 코드엔 `clampFraction`만 남고 상한 로직은 리버트로 제거됨 — 확인 필요) | `[0.2, 0.7]`로 단순화 (줌이 좁은 폭 흡수) |
| `currentWidth(_:)`의 `bounds.width` 의존 | Coordinator (`:1123` 등) | contentView 폭 = 논리폭 상수로 고정 |

---

## 2. 현재 vs 목표 좌표·렌더·스크롤 흐름

```
[현재 — Option A]
PKCanvasView (스크롤 주체)
 ├─ contentSize/contentOffset 직접 운용 (updateUIView, canvasViewDrawingDidChange, renderCard, appendFeedbackCard)
 ├─ drawing: 절대좌표 stroke
 ├─ subview tag 9997/9998/9999  ← canvasView에 직접 addSubview
 └─ SwiftUI frame(width:논리폭) + 레터박스로 폭 고정

[목표 — 네이티브 줌]
HostScrollView (스크롤/줌 주체)  ← contentSize/contentOffset/zoomScale 운용
 └─ contentView (viewForZooming, 폭=논리폭 고정, 높이=동적)
     ├─ PKCanvasView (isScrollEnabled=false; drawing만)
     └─ subview tag 9997/9998/9999  ← contentView에 addSubview (줌 동반)
```

**좌표계 불변식:** stroke·카드는 **contentView(=논리폭) 좌표**에 그려진다. 줌은 HostScrollView가 표시 단계에서만 적용 → 저장값(`positionY`/`bboxY`/`dataRepresentation`)·논리폭 모두 불변 → **마이그레이션 불필요.**

---

## 3. Backend API Inventory & Contracts

**해당 없음.** iOS 클라이언트 렌더·좌표·줌 로직에 한정. 신규/변경 API 계약 없음. (Step 0.5 API 동결 N/A — track 경계를 넘는 BE↔FE 데이터 흐름이 없다.)

---

## 4. 구현 설계

### 4.1 컴포넌트 구조

`PencilKitCanvasView`(UIViewRepresentable)의 루트를 `PKCanvasView`에서 **`HostScrollView`(UIScrollView)** 로 교체한다.

- `makeUIView` → `HostScrollView` 생성:
  - `host.delegate = coordinator` (UIScrollViewDelegate: `viewForZooming`, `scrollViewDidZoom`).
  - `host.minimumZoomScale`/`maximumZoomScale` 설정 (예: min=동적 fit, max=1.0 또는 3.0 핀치 허용).
  - `host.addSubview(contentView)`; `contentView.addSubview(canvasView)`.
  - `canvasView.isScrollEnabled = false`; 기존 tool/delegate/툴피커 셋업 유지.
- `contentView.frame = (논리폭, 동적 높이)`; `canvasView.frame = contentView.bounds`.
- `host.contentSize = contentView.frame.size` (줌 시 UIScrollView가 자동 보정).

### 4.2 폭 SSOT

`Config.logicalCanvasWidth`(=기기 세로폭, 선행 스펙)는 그대로 SSOT. 단 소비처(`currentWidth`, `cardWidth`, `appendFeedbackCard`의 `canvasView.bounds.width - 32`)를 **`bounds.width` → 논리폭 상수**로 바꾼다. contentView 폭이 항상 논리폭이므로 의미는 동일하나, 줌 중 `bounds`가 흔들려도 안전.

### 4.3 줌-투-핏 (회전·divider 연동)

패널 폭(SwiftUI 레이아웃에서 결정) → coordinator에 전달 → `scrollViewDidZoom`/명시 호출로:
- `fit = min(1, 패널폭 / 논리폭)`; `host.minimumZoomScale = fit`; 패널 변경 시 `host.zoomScale = fit`(폭 맞춤).
- 패널 ≥ 논리폭: `zoomScale = 1`, `contentInset`으로 가로 중앙 정렬(레터박스).
- 패널 < 논리폭: `zoomScale = fit (<1)`, 페이지 전체가 축소되어 보임.
- divider 드래그 중 매 프레임 zoomScale 갱신은 저렴(네이티브) — 카드 재렌더 불필요(줌은 표시만). Option A의 R-3 디바운스 우려 해소.

### 4.4 스크롤/contentSize/오토스크롤 이관

현재 `canvasView`에 거는 스크롤 관련 호출을 **HostScrollView + contentView 높이**로 이관:
- contentSize 확장 → contentView.frame.height 확장 + `host.contentSize` 동기화.
- contentOffset 클램프/오토스크롤 → `host.contentOffset`.

### 4.5 캡처·저장 (영향 없음, 검증만)

- 피드백 캡처는 `newDrawing.image(from: bounds, scale: 1.0)`로 **PKDrawing 좌표계에서 직접** 렌더(`NoteView.swift:833`) — 화면 스냅샷이 아니므로 줌/스크롤 무관. **불변.**
- 저장/로드는 `drawing.dataRepresentation()`/`PKDrawing(data:)` 절대좌표(`:639, :659, :965`) — 줌 무관. **불변.**

---

## 5. 구현 단계 (Tracks)

> ⚠️ 거의 전부 `NoteView.swift`(특히 `PencilKitCanvasView` + `Coordinator`) 단일 파일 수정이라 **파일 레벨 병렬 불가**. 직렬에 가깝고, 분리는 논리적 단위다. (선택) coordinator/카드 렌더를 별 파일로 추출하면 일부 병렬 여지가 생기나 본 작업 자체가 그 구조를 재작성하므로 추출 이득이 적다.

**의존성 그래프:**
```
Track Z-1 (PoC: 오버레이+줌 가능성) ── 모든 후속의 명시적 블로커
        │
        ▼
Track Z-2 (Host/content 골격 + 캔버스 강등)
        │
        ├─► Track Z-3 (오버레이·카드 contentView 이관)
        ├─► Track Z-4 (스크롤/contentSize/오토스크롤 이관)
        │        (Z-3·Z-4는 논리적으로 분리되나 같은 파일 → 순차 권장)
        ▼
Track Z-5 (줌-투-핏 + divider clamp 완화 + 핀치)
        │
        ▼
Track Z-6 (회귀 검증: 캡처·저장·frozen·툴피커·KaTeX 선명도)
```

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | Z-1 → Z-2 → Z-3 → Z-4 → Z-5 → Z-6 순차 |
| 2명 | A: Z-1 PoC 단독 선행 → 이후 Z-2~Z-5 주도 / B: Z-6 회귀 테스트 케이스·기존 동작 캡처를 병행 준비, Z-3 일부 보조(merge 조율) |
| 3명+ | 추가 인원은 §6.x 미확인(KaTeX 줌 선명도 PoC, 툴피커 first-responder, 제스처 충돌) 검증에 투입. 구현은 단일 파일이라 추가 분할 이득 적음 |

### Track Z-1: PoC — 오버레이 구조 + 네이티브 줌 가능성 검증
**의존:** 없음 (모든 후속의 블로커)
**작업량:** 중간. 가장 복잡: PencilKit을 비스크롤 오버레이로 둔 채 펜·툴피커·줌+세로스크롤 동시 동작 확인
**산출:** 격리된 최소 화면(또는 브랜치)에서 아래가 동작함을 실기기로 확인.

| ID | 내용 |
|---|---|
| Z-1a | `UIScrollView` > `contentView`(논리폭) > `PKCanvasView(isScrollEnabled=false)` 구조에서 **펜으로 그리기 + 그린 위치가 contentView 좌표에 정확히** 들어가는지 |
| Z-1b | `viewForZooming`로 `host.zoomScale` 변경 시 stroke가 **선명하게** 줌되고 펜 입력이 줌 배율로 정확히 매핑되는지 |
| Z-1c | 줌(<1)된 상태에서 **세로 스크롤(팬)** 이 동시에 되는지 (무한 종이 유지) |
| Z-1d | `PKToolPicker`가 비스크롤·중첩 캔버스에서 first-responder/표시 정상인지 |

### Track Z-2: Host/content 골격 + 캔버스 강등
**의존:** Z-1 통과
**내부 순서:** Z-2a → Z-2b
**작업량:** 큼. 가장 복잡: `makeUIView` 반환 타입 전환(`PKCanvasView` → `UIScrollView`)에 따른 `@Binding var canvasView` 접근 경로 정리

| ID | 파일 | 내용 |
|---|---|---|
| Z-2a | `NoteView.swift:858-992` (`PencilKitCanvasView`) | `makeUIView`가 HostScrollView 생성·`contentView`·`canvasView` 중첩 구성, `isScrollEnabled=false`, delegate 연결. `@Binding canvasView`는 유지하되 호스트/콘텐츠 참조를 coordinator가 보관 |
| Z-2b | `NoteView.swift:994` (`updateUIView`) | 다크모드/툴/contentSize 로직을 호스트·contentView 기준으로 재배선 |

### Track Z-3: 오버레이·카드 contentView 이관
**의존:** Z-2
**작업량:** 중간. 가장 복잡: `canvasView.subviews` 순회·`addSubview`·`bringSubviewToFront`의 부모를 contentView로 일괄 전환하면서 기존 tag 조회 로직 유지

| ID | 파일 | 내용 |
|---|---|---|
| Z-3a | `:1133-1146`(frozen), `:1281-1369`(card/indicator) | `canvasView.addSubview`/`subviews.filter`/`sendSubviewToBack`/`bringSubviewToFront`의 대상을 **contentView**로 변경 |
| Z-3b | `currentWidth(_:)` `:1118`~ 등 | 폭 소스를 `bounds.width` → 논리폭 상수로 (4.2) |
| Z-3c | `appendFeedbackCard:545` | `canvasView.bounds.width - 32` → `논리폭 - 32` |

### Track Z-4: 스크롤/contentSize/오토스크롤 이관
**의존:** Z-2 (Z-3와 같은 파일 → 순차 권장)
**작업량:** 중간. 가장 복잡: 세 군데 흩어진 contentSize 확장 + 오토스크롤을 호스트로 모으며 contentView 높이와 동기화

| ID | 파일 | 내용 |
|---|---|---|
| Z-4a | `updateUIView:1008-1017`, `resetContentSize:697-700` | contentSize.width(논리폭) + height 운용을 호스트/contentView로 |
| Z-4b | `canvasViewDrawingDidChange:1399-1430` | contentOffset 상향 클램프·auto-expand를 호스트/contentView 높이로 |
| Z-4c | `renderCard:1304-1305`, `appendFeedbackCard:608-619` | 카드 확장·오토스크롤(`setContentOffset`)을 호스트로 |

### Track Z-5: 줌-투-핏 + divider 완화 + 핀치
**의존:** Z-2~Z-4
**작업량:** 중간. 가장 복잡: 패널 폭 변화를 SwiftUI→coordinator로 전달해 zoomScale/contentInset를 결정론적으로 갱신

| ID | 파일 | 내용 |
|---|---|---|
| Z-5a | `PencilKitCanvasView` + `Coordinator` | 패널 폭 입력(바인딩/파라미터) → `fit=min(1,패널/논리폭)`, `minimumZoomScale=fit`, 회전·divider 시 `zoomScale=fit` |
| Z-5b | `Coordinator.scrollViewDidZoom`/centering | 패널 ≥ 논리폭이면 zoom=1 + 가로 중앙 `contentInset`(레터박스) |
| Z-5c | `NoteView.swift` divider (`clampFraction`) | 가로/세로 clamp `[0.2,0.7]`로 단순화 (줌이 좁은 폭 흡수) |
| Z-5d | (선택) | `maximumZoomScale`로 핀치 줌 허용 |

### Track Z-6: 회귀 검증
**의존:** Z-2~Z-5
**작업량:** 중간. 가장 복잡: 줌 상태별 KaTeX 카드 선명도·툴피커·제스처 충돌의 실기기 확인

| ID | 내용 |
|---|---|
| Z-6a | 피드백 캡처 이미지가 줌과 무관하게 PKDrawing 원본 해상도로 나가는지(`:833`) |
| Z-6b | 저장/로드 좌표 불변(`:639,659,965`), 회전·줌 반복 후 stroke/카드 정렬 유지 |
| Z-6c | frozen 영역 입력 차단·next-indicator가 contentView 좌표에서 정상 |
| Z-6d | KaTeX(WKWebView) 카드가 zoom<1 및 핀치 zoom>1에서 허용 가능한 선명도인지 |
| Z-6e | 툴피커 first-responder, undo/redo, 다크모드 |

---

## 6. 확인 완료 사항 (코드 검증)

1. **PKCanvasView가 현재 스크롤 주체** — `isScrollEnabled=true`, `alwaysBounceVertical=false` (`NoteView.swift:954-955`).
2. **카드·오버레이·indicator는 canvasView에 직접 addSubview** — frozen `:1139-1140`, card `:1301`, indicator `:1354`, `bringSubviewToFront :1369`. → 네이티브 줌 시 stroke와 어긋나는 직접 원인이며, Z-3에서 contentView로 이관해야 함.
3. **contentSize/contentOffset를 canvasView에서 직접 운용** — `updateUIView:1008-1017`, `resetContentSize:697-700`, `canvasViewDrawingDidChange:1399-1430`, `renderCard:1304-1305`, `appendFeedbackCard:608-619, 616`. → Z-4 이관 대상.
4. **카드 폭은 `canvasView.bounds.width` 기준** — `appendFeedbackCard:545`(`bounds.width-32`), `renderCard`는 `currentWidth(_:)`(`:1123`) 경유. → 논리폭 상수로 전환(Z-3b/c).
5. **피드백 캡처는 PKDrawing 좌표 직접 렌더** — `newDrawing.image(from:bounds,scale:1.0)` (`NoteView.swift:833`), 화면 스냅샷 아님 → 줌/스크롤 무관, **불변**.
6. **저장/로드는 절대좌표 dataRepresentation** — `saveDrawing:639`, 로드 `:659/:965` → 줌 무관, **불변**.
7. **카드 Y(`positionY`)·next 위치는 stroke 절대좌표 기반** — `appendFeedbackCard:555,557`, `nextCardLineY:1061`, `calculateNextCardY`(stroke renderBounds) → contentView(논리폭) 좌표에 그대로 살아있음. **마이그레이션 불필요**.
8. **카드 좌표는 서버로 안 감** — `FeedbackRecord`(로컬 GRDB)만 (선행 스펙 §6-8 재확인).
9. **`scaleEffect` 통짜 줌은 깨짐** — 시뮬레이터 재현·리버트(`d7b3f19`). 카드 subview가 stroke 레이어와 변환을 따로 탐(§1.2).

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | `PKCanvasView(isScrollEnabled=false)`를 줌되는 contentView의 자식으로 둘 때 펜 입력이 contentView 좌표로 정확히 들어가는지 | Z-1 PoC (실기기) |
| 2 | 호스트 `zoomScale<1`에서 stroke 재래스터화(선명도) + 입력 매핑 | Z-1 PoC |
| 3 | 호스트 줌과 세로 무한 스크롤(팬) 동시 운용 | Z-1 PoC |
| 4 | KaTeX `WKWebView` 카드가 zoom<1 / 핀치 zoom>1에서 허용 선명도인지 (레이어 래스터화 블러) | Z-6d, 별도 PoC 가능 |
| 5 | `PKToolPicker` first-responder가 중첩·비스크롤 캔버스에서 정상인지 | Z-1d |
| 6 | HostScrollView 팬/줌 제스처 vs PencilKit 손가락 입력(`drawingPolicy=.default`) 충돌 | Z-1/실기기 |
| 7 | 레터박스(패널≥논리폭) 중앙 정렬을 `contentInset` vs `zoomScale` 어느 쪽으로 | Z-5b |
| 8 | 시뮬레이터의 줌/펜 동작 차이 (실기기 필수) | 실기기 검증 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 단일 파일 대규모 재작성(스크롤 주체 전환) | 회귀 표면 큼, 병렬 불가 | Z-1 PoC를 명시적 블로커로; Z-6 회귀 체크리스트 선작성; 작은 PR로 쪼개되 한 번에 동작 보장 |
| PencilKit 비스크롤 오버레이가 펜/툴피커에서 미동작 | 접근 전체 무효화 | Z-1에서 가장 먼저 검증, 실패 시 대안(2: 사설 zooming view 탐색)·또는 Option A 유지로 폴백 |
| KaTeX WKWebView 줌 시 블러 | 카드 가독성 저하 | zoom<1(축소)은 덜 티남; 필요 시 줌 종료 시 1x 재렌더 또는 카드만 역스케일 |
| 줌·스크롤 제스처 vs 손가락 그리기 충돌 | 그리기/스크롤 오작동 | `drawingPolicy`·제스처 우선순위 조정, Z-1에서 확인 |
| 회전 중 저장 타이밍 | 좌표 유실 | `saveDrawing` 디바운스와 줌/레이아웃 변경 순서 검증 |
| 시뮬레이터-실기기 줌/펜 차이 | 검증 누락 | 실기기 회전·divider·핀치 검증 필수 |
| 좌표 마이그레이션 착오 | 기존 노트 깨짐 | 논리폭·stroke·카드 좌표계 불변 → 마이그레이션 없음(§6-7). 변경 PR에서 기존 노트 1개로 회귀 확인 |

---

## 8. 폴백

Z-1 PoC가 실패하면(PencilKit 오버레이/줌 미동작), 본 작업을 중단하고 **Option A(현재 구현, 가로 PDF ~25–30% 상한)를 정식 동작으로 유지**한다. 큰 PDF가 필요한 사용자는 **세로 모드(상하 분할, PDF 70%·캔버스 풀폭)** 를 쓰는 것으로 제품 가이드. (선행 스펙 §4 Option A의 수용된 trade-off.)

---

## 9. 실기기 검증 체크리스트 (남은 작업 — 하드웨어 필요)

> 자동/시뮬레이터로 검증 불가한 시각·런타임 항목만 남았다. iPad에서 노트(가능하면 교재 PDF 연결 + 기존 카드 있는 노트)를 열고 아래를 확인할 것. 실패 항목은 그대로 회신하면 수정한다. PencilKit 오버레이/줌 자체가 동작하지 않으면 §8 폴백(Option A 유지).

**Z-1 — 코어 베팅(블로커):**
- [ ] Z-1a 펜으로 그린 위치가 종이(contentView) 좌표에 정확히 들어가는가 (오프셋/어긋남 없음)
- [ ] Z-1b host `zoomScale<1`(가로에서 캔버스 좁힘)에서 stroke가 **선명하게** 줌되고, 펜 입력이 줌 배율로 정확히 매핑되는가
- [ ] Z-1c 줌(<1)된 상태에서 **세로 스크롤(팬)** 이 동시에 되는가 (무한 종이 유지)
- [ ] Z-1d `PKToolPicker`가 중첩·비스크롤 캔버스에서 first-responder/표시 정상인가 (펜 버튼 토글 포함)

**Z-6 — 회귀:**
- [ ] Z-6a 피드백 캡처 이미지가 줌과 무관하게 PKDrawing 원본 해상도로 나가는가
- [ ] Z-6b 저장→앱 재실행→로드 후 stroke/카드 정렬 유지, 회전·divider·핀치 반복 후에도 유지
- [ ] Z-6c frozen 영역 입력 차단·next-indicator(점선)가 줌/스크롤 후에도 올바른 위치
- [ ] Z-6d KaTeX(WKWebView) 카드가 zoom<1 및 핀치 zoom>1에서 허용 가능한 선명도인가 (블러 시 §7 완화책)
- [ ] Z-6e 손가락 그리기(.default) vs host 팬/핀치 제스처 충돌 없는가, undo/redo·다크모드 정상

검증 완료 시 위 Status를 "구현·검증 완료"로 갱신.
