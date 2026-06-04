# 가로 모드 캔버스 Auto-Fit + PDF 분할 리사이즈 Spec

> **Status:** ✅ Implemented — **Option A 채택**(고정 논리폭 + 레터박스). Track P + Track A + Track R(R-1/R-2/R-3) 구현 완료.
> **Date:** 2026-06-04
> **Author:** (auto-generated)
> **Scope:** iOS only (`ios-app`). 백엔드/API 변경 없음.

### 구현 요약 (2026-06-04)
- **논리폭(SSOT):** `Config.logicalCanvasWidth` = 기기 세로폭(짧은 변). 세로 모드는 오늘과 동일(여백/클리핑 없음), 가로 모드에서만 종이가 이 폭으로 가운데 정렬되고 양옆 레터박스. (820 상한은 13" 세로에서 기존 필기 클리핑 위험이 있어 폐기.)
- **Track P:** `contentSize.width`가 항상 `bounds.width`를 추종(버그 ① 해소). frozen/카드/indicator 폭을 `Coordinator.currentWidth(_:)` 단일 함수로 통일(P-2).
- **Track A:** `canvasPanel`이 `PencilKitCanvasView`를 논리폭으로 `frame` 후 `systemGray5` 레터박스 위에 중앙 배치. 캔버스 `bounds.width`가 논리폭에 고정 → stroke/카드 좌표 재계산 0.
- **Track R:** `pdfFraction`(@State, 세션 휘발) + 드래그 핸들. 가로=폭, 세로=높이. clamp 가로/세로 공통 `[0.2,0.7]`.
- **zoom-to-fit 보강(가로 PDF 확장 제약 해소):** 초기엔 가로 clamp 상한을 `1 - logical/total`로 둬 캔버스가 논리폭 미만이 안 되게 했으나, 그 결과 가로 PDF 최대 폭이 ~25–30%로 너무 제한적이었다. 이를 풀어 PDF를 70%까지 허용하되, 캔버스 패널이 논리폭보다 좁아지는 구간에선 `canvasPanel`이 **캔버스 레이어 전체를 `scaleEffect(panelW/logical, anchor:.topLeading)`로 축소**한다. 좌표계는 논리폭 그대로(클리핑·카드 리플로우 없음), 표시만 축소 — 사실상 Option C(zoom-to-fit)를 "좁아질 때만" 부분 적용. stroke·카드·오버레이가 한 레이어로 같이 축소돼 정렬 유지. 세로 뷰포트는 `panelH/scale`로 키워 축소 후 정확히 패널 높이를 채움. **펜 입력의 `scaleEffect` 매핑은 실기기 검증 권장**(시뮬레이터 빌드까지 검증 완료).

이 스펙은 연관된 두 묶음을 다룬다:
- **묶음 1 (논의 필요):** 가로 모드 캔버스 auto-fit — §1~§7 본문.
- **묶음 2 (기능 추가):** 분할 divider 드래그 리사이즈 — 가로=PDF 폭 조정, 세로=PDF 높이 조정. §4.5 / Track R. **묶음 1과 같은 근본(캔버스 폭/높이 변경 핸들러 부재)을 공유**하므로 함께 명세한다.

---

## 0. 한 줄 요약

펜 캔버스는 **세로 스크롤·고정폭 "무한 종이"** 모델인데, 캔버스 폭(`bounds.width`)에 묶인 3가지(① `contentSize.width`, ② 이미 그려진 PKDrawing stroke, ③ 피드백 카드 폭·Y좌표)가 **캔버스 폭 변경 시(회전 OR divider 드래그) 함께 갱신되지 않아** 캔버스가 가용 폭에 안 맞고 기존 필기·카드가 어긋난다. 이걸 "어떻게 맞출 것인가"가 핵심 설계 결정이며, 단순 스케일링은 기존 필기·카드 크기 때문에 부작용이 크다. 추가로, PDF/캔버스 분할 비율이 **고정 40:60**이라 사용자가 조절할 수 없어 드래그 리사이즈를 더한다 — 이 리사이즈도 캔버스 폭/높이를 바꾸므로 위 폭-변경 처리를 그대로 탄다.

---

## 1. Background

### 1.1 현재 동작 (확인된 코드 기준)

캔버스는 `PencilKitCanvasView`(UIViewRepresentable, `NoteView.swift:858-1373`)로, **세로로만 스크롤되는 고정폭 종이**다:

- `contentSize.width = bounds.width`, `contentSize.height = bounds.height * 5`에서 시작해 필기량에 따라 **아래로만 확장**(`NoteView.swift:1354-1361`).
- 가로 스크롤 없음: `alwaysBounceVertical = false`, 폭은 항상 화면 폭에 고정 (`NoteView.swift:881-883`).

**Orientation 처리는 "레이아웃 분할"에만 존재**한다 (`NoteView.swift:46-72`):
- 가로 + PDF 열림 → `HStack` 좌우 분할 (PDF 40% : 캔버스 60%)
- 세로 + PDF 열림 → `VStack` 상하 분할 (PDF 40% : 캔버스 60%)
- PDF 닫힘 → 캔버스 전체 폭

즉 회전하면 캔버스의 `bounds.width`가 바뀐다 (예: 세로 전체폭 ~820pt → 가로+PDF 60% ~820pt → 가로 전체폭 ~1180pt). 그러나 **폭 변화에 대응하는 재계산이 없다.**

### 1.2 문제의 근본 — 폭에 묶인 3가지가 회전 시 따로 논다

| # | 대상 | 폭/좌표 의존 방식 | 회전 시 갱신되나? | 결과 |
|---|---|---|---|---|
| ① | `contentSize.width` | `bounds.width`로 1회 세팅 | **안 됨.** 가드가 `contentSize.width == 0`일 때만 발동 (`NoteView.swift:935-940`). 높이 가드(941-946)는 width를 현재 bounds로 덮어쓰지만 `height <= bounds.height`일 때만. | 가로로 넓어져도 content 폭이 세로폭에 머묾 → 가용 폭 미사용 |
| ② | PKDrawing strokes | **절대좌표.** `dataRepresentation()`로 저장, reflow 없음 (`NoteView.swift:889-894`, `564-593`) | **안 됨 (불가).** 손글씨는 reflow 불가 | 세로에서 쓴 필기가 가로 캔버스에서 좌측 폭 밴드에 그대로 — 우측 공백/어긋남 |
| ③ | 피드백 카드 | 폭 = `effectiveWidth - 32` (현재 폭 추종, `NoteView.swift:1104`), **Y = 저장된 절대 `positionY`/`bboxY`** (`renderCard` frame `y: fb.positionY`) | 폭은 갱신됨, **Y는 stroke 절대좌표 기준 고정** | 카드 폭만 늘고 Y는 옛 stroke 위치 기준 → 필기와 카드 정렬 깨짐 |

추가로 frozen 오버레이 폭은 `max(lastKnownWidth, contentSize.width)`로 카드와 또 다른 기준을 쓴다 (`NoteView.swift:1042-1067`) — 폭의 SSOT(단일 진실)가 없다.

### 1.3 핵심 설계 질문 (논의 대상)

> **회전 시 기존 필기·카드를 새 캔버스 폭에 "맞춘다"는 게 무엇을 의미하는가?**
> 손글씨 stroke는 텍스트처럼 reflow가 불가능하다. 따라서 "auto-fit"은 아래 중 하나를 골라야 한다 — 이건 product 결정이며 §4에서 옵션을 비교한다.

### 1.4 분할 divider 리사이즈 (묶음 2 — 기능 추가)

현재 PDF/캔버스 분할 비율은 **고정 40:60**이다 (`NoteView.swift:59, 66`):
- 가로: `pdfPanel.frame(width: geo.size.width * 0.4)` — PDF 폭 고정
- 세로: `pdfPanel.frame(height: geo.size.height * 0.4)` — PDF 높이 고정
- 둘 사이는 그냥 `Divider()`(드래그 불가, `:60, 67`)

**요구:** divider를 드래그해
- **가로 모드:** PDF viewer **폭** 조정 (좌우 분할 비율 변경)
- **세로 모드:** PDF viewer **높이** 조정 (상하 분할 비율 변경)

이때 캔버스의 `bounds.width`(가로) 또는 `bounds.height`(세로)가 바뀌므로 §1.2의 ①③ 처리(폭 변경 시 contentSize·카드 재계산)를 **그대로 재사용**해야 한다 — divider 드래그는 "작은 회전"과 같다. 따라서 묶음 1의 폭-변경 핸들러가 divider 리사이즈의 전제다.

### 1.5 Out of Scope

| 항목 | 이유 |
|---|---|
| 백엔드/API 변경 | 캔버스 좌표·렌더·분할 비율은 전부 클라이언트. 피드백 카드 좌표·분할 비율은 로컬에만 존재 |
| PDF 패널 내부 줌/레이아웃 | 별개 컴포넌트(`pdfPanel`). 본 스펙은 캔버스 폭/필기/카드 + 분할 비율만 |
| 가로 스크롤(좌우 무한 캔버스) 도입 | 현재 모델은 세로 스크롤 단일축. 양축 변경은 별도 대공사 |
| 손글씨 reflow(줄바꿈 재배치) | 기술적으로 불가 |
| PDF 닫힘 상태의 divider | 분할이 없으므로 리사이즈 대상 아님 |

---

## 2. 현재 좌표·렌더 흐름

```
PKCanvasView (세로 스크롤)
 ├─ contentSize: (bounds.width, bounds.height*5+)   ← 폭은 1회 세팅 후 방치
 ├─ drawing: PKDrawing (절대좌표 stroke)            ← 저장/로드만, 회전 무시
 ├─ subview tag=9997  frozen overlay  (w=max(lastKnownWidth, contentSize.width))
 ├─ subview tag=9999  feedback card   (w=lastKnownWidth-32, y=fb.positionY)
 └─ subview tag=9998  next-position indicator (계산: max(strokeMaxY, lastCardBottom))

회전 (portrait → landscape):
  SwiftUI: isLandscape 토글 → HStack/VStack 재구성 → 캔버스 bounds.width 변경
  PKCanvasView.updateUIView 호출
    → contentSize.width 재계산 없음 (가드 미발동)      [버그 ①]
    → drawing 그대로 (절대좌표 유지)                    [본질 ②]
    → renderAllCards: 폭만 새로, Y는 저장값 그대로      [불일치 ③]
```

피드백 카드 좌표의 출처:
- `positionY`, `bboxY`, `bboxHeight`, `strokeRangeStart/End`는 `FeedbackRecord`(GRDB)에 영속 (`Note.swift`).
- 다음 카드 Y는 `calculateNextCardY` = `max(stroke renderBounds.maxY, lastRenderedBottom) + 24` (`NoteView.swift:1312-1328`). **stroke 절대좌표에 직접 의존.**

→ 즉 카드 Y는 stroke 좌표계에 박혀 있어, stroke를 건드리지 않는 한 카드만 독립적으로 "맞출" 수 없다.

---

## 3. Backend API Inventory

**해당 없음.** 본 작업은 iOS 클라이언트 렌더·좌표 로직에 한정되며 신규/변경 API 계약이 없다. (피드백 카드 좌표는 서버로 가지 않고 로컬 DB에만 존재함을 §6에서 확인.)

---

## 4. 설계 옵션 비교 (결정 필요)

"auto-fit"의 의미를 정하는 4개 옵션. ②(stroke reflow 불가)가 모든 옵션의 제약이다.

### Option A — 고정 논리폭 + 레터박스 (orientation 독립) ⭐ 추천(저위험)

캔버스 콘텐츠 폭을 **orientation과 무관한 단일 논리폭**(예: 세로 전체폭 ~820pt)으로 고정. 가로에서 남는 공간은 회색 여백으로 두고 종이를 가운데 정렬.

- **장점:** stroke·카드·frozen 전부 **단일 좌표계** → 회전 시 reflow/스케일 0. 결정론적, 버그 표면적 최소. ③ 카드 Y 불일치 자동 해소(폭이 안 변하므로).
- **단점:** 가로의 넓은 폭을 "쓰지" 않음(좌우 여백). 사용자가 기대한 "가로에서 더 넓게"가 아닐 수 있음.
- **구현 핵심:** `contentSize.width`를 상수 `LOGICAL_CANVAS_WIDTH`로 고정, stroke 입력/카드/오버레이 폭 전부 이 상수 기준. 캔버스 뷰를 `frame(width:)`로 중앙 배치 또는 PKCanvasView 내부 content를 가운데 인셋.

### Option B — 폭 스케일-투-핏 (회전 시 비례 확대/축소)

회전으로 폭이 `w0→w1`로 바뀌면 `r = w1/w0`를 PKDrawing에 affine transform으로 적용하고, 카드 `positionY`/`bboxY`/`bboxHeight`·`contentSize.height`도 `r`배.

- **장점:** 가로 폭을 실제로 활용. 콘텐츠가 항상 폭을 채움.
- **단점:**
  - **손글씨 크기가 바뀐다** — 가로로 가면 글씨가 커지고 세로 복귀 시 작아짐. 반복 회전 시 floating-point 누적 드리프트(원복 안 됨).
  - 카드 텍스트/KaTeX **높이는 폭에 선형 비례하지 않음**(줄바꿈 재계산 필요) → `bboxHeight*r`이 실제 렌더 높이와 어긋나 frozen 영역·다음 카드 Y가 틀어짐.
  - 영속 좌표(`positionY` 등) 마이그레이션 필요 — 어떤 폭 기준으로 저장됐는지 추적해야(현재 그 메타데이터 없음, §6.x).
- **결론:** "넓게 쓰고 싶다"는 요구엔 맞지만 부작용·복잡도 최대. 카드 높이 재계산을 별도로 처리해야 함.

### Option C — 고정 비율 "페이지" + 줌-투-핏 (GoodNotes식)

페이지를 고정 크기 문서로 보고, 회전 시 폭에 맞춰 **줌(스케일)으로 fit**, 팬 허용. 콘텐츠는 줌만 되고 좌표는 불변.

- **장점:** 실제 노트앱 UX. stroke 좌표 불변(②와 충돌 없음), 카드 좌표도 불변. "auto-fit"의 직관적 의미("화면에 꽉 차게 보여줌")에 가장 부합.
- **단점:** 현재 "세로 무한 스크롤" 모델을 "고정 페이지 + 줌/팬"으로 바꾸는 **모델 전환**. `isScrollEnabled`/`contentSize` 운용, frozen 차단 로직, next-card indicator, PDF split 동작과의 상호작용 재설계. 가장 큰 작업.
- **비고:** 무한 세로 스크롤 + 줌은 PencilKit 기본 scrollView 줌(`minimumZoomScale` 등)으로 일부 가능하나, "폭 fit 줌"과 "세로 스크롤" 동시 운용은 검증 필요(§6.x).

### Option D — 최소 수정: contentSize.width만 bounds 추종 (필기는 제자리)

①만 고친다. `contentSize.width`를 항상 현재 `bounds.width`로 갱신해 가로에서 입력 가능 영역을 넓힘. 기존 stroke·카드는 **제자리에 둠**(맞추지 않음). "가로는 더 넓은 작업공간일 뿐, 기존 내용 reflow 안 함"으로 규정.

- **장점:** 가장 작은 변경. ① 버그 해소. 신규 필기는 넓은 폭 활용.
- **단점:** 기존 필기·카드는 좌측에 몰린 채 — 사용자 기대("이미 쓴 것도 맞춰짐")와 어긋남. 카드 폭은 늘지만(③) Y는 옛 stroke 기준이라 부분 불일치 잔존.
- **위치:** A로 가기 전 임시 핫픽스 또는 "가로=확장 작업공간" 제품 방향이면 종착지.

### 옵션 결정 매트릭스

| 기준 | A 고정폭 | B 스케일 | C 줌-페이지 | D 최소 |
|---|---|---|---|---|
| 기존 필기 "맞춤" | N/A(안 변함, 일관) | △(크기변동) | ✅(줌으로 보임) | ❌(제자리) |
| 가로 폭 활용 | ❌ | ✅ | ✅ | ✅(신규만) |
| 카드 크기/정렬 안정성 | ✅ | ❌(높이 재계산) | ✅ | △ |
| 영속 좌표 마이그레이션 | 불필요 | **필요** | 불필요 | 불필요 |
| 작업량 | 작음 | 큼 | 큼 | 작음 |
| 회귀 위험 | 낮음 | 높음 | 중~높 | 낮음 |

> **결정 요청:** §0의 "auto-fit이 무엇이어야 하나"에 대한 product 의도가 (a) "가로에서도 일관되게 보이기만 하면 됨" → **A**, (b) "가로의 넓은 폭을 실제로 채우고 기존 내용도 키워서 보여줘" → **C 권장**(B는 부작용으로 비권장), (c) "일단 가로에서 깨지지 않게 + 신규 필기는 넓게" → **D**(임시). 이 결정 전엔 Track 구현 착수 불가.

### 4.5 분할 divider 리사이즈 설계 (묶음 2)

고정 40% 비율을 `@State` 비율값으로 바꾸고 드래그 가능한 핸들을 끼운다. **새 API·영속 모델 없음** (비율은 메모리 또는 선택적으로 `UserDefaults`).

**레이아웃 변경** (`NoteView.swift:56-72`):
- `@State private var pdfFraction: CGFloat = 0.4`
- 가로: `pdfPanel.frame(width: geo.size.width * pdfFraction)`, 사이에 드래그 핸들 뷰
- 세로: `pdfPanel.frame(height: geo.size.height * pdfFraction)`, 가로 핸들
- 드래그 핸들: `DragGesture`로 `pdfFraction`을 `[0.2, 0.7]` 등 clamp 범위 내 갱신. 가로는 `value.translation.width / geo.size.width`, 세로는 `.height / geo.size.height`를 델타로.

**캔버스 폭/높이 변경 연동 (핵심):**
- 가로에서 드래그 → 캔버스 폭 변경 → 묶음 1의 폭-변경 핸들러(선택 옵션 A/C/D) 발동. **divider는 폭-변경 처리의 추가 트리거일 뿐**, 별도 좌표 로직 없음.
- 세로에서 드래그 → 캔버스 **높이**만 변경 → contentSize.height는 이미 아래로 확장형(`:1354-1361`)이라 폭 좌표계 영향 없음. stroke/카드 X좌표 불변 → §1.2 ①③ 영향 거의 없음(세로 리사이즈가 가로 리사이즈보다 안전).

**성능 주의:** 드래그 중 매 프레임 `updateUIView`→카드 재렌더(특히 KaTeX WKWebView reload)는 비싸다. `renderAllCards`에 멱등성 가드가 있으나(`:1078-1085`) 폭이 매 프레임 바뀌면 시그니처가 매번 달라져 reload 폭발. **드래그 중에는 비율만 갱신하고 캔버스 폭-변경 재계산은 드래그 종료(`onEnded`) 시 1회**로 디바운스할 것 (§7 Risk).

**결정 포인트(소):** 비율을 영속할지(`UserDefaults`, 노트별 vs 전역) — 기본은 세션 메모리(영속 안 함)로 두고 추후 확장.

---

## 5. 구현 단계 (Tracks)

> ⚠️ 모든 Track이 `NoteView.swift` 단일 파일을 수정하므로 **파일 레벨 병렬이 불가**하다. 인원을 늘려도 직렬에 가깝다. 분리는 "논리적 단위"이며 실제로는 한 사람이 순차 진행하거나, 파일 분할(coordinator를 별 파일로 추출) 선행이 필요하다.

**의존성 그래프:**
```
                 ┌─ Track R-1 (세로 높이 divider) ── 독립, 즉시 가능
시작 ── Track P ─┤
 (폭 SSOT)       └─ [묶음1 옵션 결정] ─ Track A | C | D | B ─┬─ Track R-2 (가로 폭 divider)
                                                            └─ Track R-3 (드래그 디바운스)
```
- Track P(폭 SSOT 정리)는 옵션과 무관하게 선행 가능 — 모든 옵션의 기반.
- 묶음1 옵션(A/C/D/B)은 §4 product 결정 전 착수 불가.
- Track R-1(세로)은 폭 좌표계와 무관 → **유일하게 진짜 독립·병렬 가능**한 단위.
- Track R-2(가로)는 묶음1 옵션 완료 후.

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | P → (옵션결정) → 묶음1 옵션 → R-2/R-3 → R-1. 순차 |
| 2명 | A: Track P + 묶음1 옵션 / B: Track R-1(세로, 독립). 단 같은 파일이라 merge 조율 필요 |
| 3명+ | 추가 인원은 §6.x 미확인 검증(실기기 bounds 측정, C-1 PoC)에 투입. 구현 자체는 단일 파일이라 추가 분할 이득 적음 |

### 공통 선행 (모든 옵션) — Track P: 폭 SSOT 정리

**의존:** 없음 (옵션 결정과 독립적으로 가치 있음 — 리팩토링)
**작업량:** 작음

| ID | 파일 | 내용 |
|---|---|---|
| P-1 | `NoteView.swift:935-946` | `contentSize` 폭/높이 재계산 가드 정리 — 폭의 단일 진실 함수 `effectiveCanvasWidth` 도입 |
| P-2 | `NoteView.swift:1042-1104` | frozen 오버레이·카드·indicator가 쓰는 폭 기준을 `effectiveCanvasWidth`로 통일 (현재 `lastKnownWidth` vs `contentSize.width` 혼용 제거) |

### 옵션 A 선택 시 — Track A

**의존:** 옵션 결정
**작업량:** 작음. 가장 복잡한 부분: PKCanvasView를 논리폭으로 중앙 배치하면서 세로 스크롤 유지

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `Utilities/Config.swift` 또는 신규 상수 | `LOGICAL_CANVAS_WIDTH` 정의 (세로 전체폭 기준값 결정 — §6.x) |
| A-2 | `NoteView.swift:935-946` | `contentSize.width = LOGICAL_CANVAS_WIDTH` 고정 |
| A-3 | `NoteView.swift:199-227` (`canvasPanel`) | 캔버스를 논리폭으로 중앙 배치(가로에서 좌우 여백) |
| A-4 | `NoteView.swift:1042-1104` | 카드/오버레이/indicator 폭을 상수 기준으로 |

### 옵션 C 선택 시 — Track C (대공사, 직렬)

**의존:** 옵션 결정. 내부 순서 C-1 → C-2 → C-3 (탐색 PoC 선행 필수)
**작업량:** 큼. 가장 복잡: 세로 무한 스크롤과 폭-fit 줌의 동시 운용 검증

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | (PoC) | PKCanvasView 내장 scrollView로 `minimumZoomScale`/세로 스크롤 동시 가능 여부 검증 (§6.x) |
| C-2 | `NoteView.swift` 캔버스 전반 | 고정 페이지폭 + 회전 시 zoom-to-fit, 팬 운용 |
| C-3 | `NoteView.swift:1330-1361` 등 | frozen 차단·next-card indicator·auto-expand를 줌 좌표계에 맞춰 재검토 |

### 옵션 D 선택 시 — Track D

**의존:** 옵션 결정
**작업량:** 작음

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `NoteView.swift:935-946` | `contentSize.width`를 항상 현재 `bounds.width`로 갱신 |
| D-2 | `NoteView.swift:1042-1104` | 카드/오버레이 폭이 새 폭에 일관 반영되는지 확인 |

### 묶음 2 — Track R: 분할 divider 리사이즈

**의존:** 가로 폭 조정의 좌표 처리는 Track P + 선택된 묶음1 옵션(A/C/D) 완료에 의존(드래그가 폭-변경 핸들러를 호출하므로). **세로 높이 조정은 폭 좌표계와 무관 → 묶음1과 독립으로 먼저 가능.**
**내부 순서:** R-1(세로, 독립) ∥ R-2(가로, 묶음1 의존) → R-3(공통 디바운스)
**작업량:** 중간. 가장 복잡: 드래그 중 카드 재렌더 디바운스

| ID | 파일 | 내용 | 의존 |
|---|---|---|---|
| R-1 | `NoteView.swift:63-69` (세로 VStack) | `pdfFraction` @State + 가로 드래그 핸들로 높이 조정. clamp `[0.2,0.7]` | 독립 |
| R-2 | `NoteView.swift:56-62` (가로 HStack) | 세로 드래그 핸들로 폭 조정. 캔버스 폭 변경 → 묶음1 폭-변경 핸들러 트리거 | Track P + 묶음1 옵션 |
| R-3 | `NoteView.swift` 드래그 핸들 | `onEnded`에서만 캔버스 폭-변경 재계산 1회 호출(디바운스), 드래그 중엔 비율만 | R-1,R-2 |

### 옵션 B 선택 시 — Track B (비권장, 직렬)

**의존:** 옵션 결정. 내부 순서 B-1 → B-2 → B-3
**작업량:** 큼. 가장 복잡: 카드 높이 폭-비선형 재계산 + 영속 좌표 마이그레이션

| ID | 파일 | 내용 |
|---|---|---|
| B-0 | `Models/Note.swift` + GRDB 마이그레이션 | 카드 좌표가 어느 폭 기준인지 `authoredWidth` 컬럼 추가 (마이그레이션) |
| B-1 | `NoteView.swift` updateUIView | 폭 변화 감지 시 `r=w1/w0` 산출, PKDrawing affine transform 적용 |
| B-2 | `NoteView.swift:1098-1237` | 카드 텍스트/KaTeX **높이 재계산**(폭 변경 → 줄바꿈) 후 Y 재배치 |
| B-3 | `NoteView.swift:1021-1031` | frozen·next-card Y를 재계산된 좌표로 갱신 |

---

## 6. 확인 완료 사항 (코드 검증)

1. **캔버스는 세로 스크롤 고정폭 모델** — `isScrollEnabled=true`, `alwaysBounceVertical=false`, `contentSize=(bounds.width, bounds.height*5)` (`NoteView.swift:881-883, 935-946`).
2. **`contentSize.width`는 회전 시 갱신 안 됨** — 폭 세팅 가드가 `contentSize.width == 0`에서만 발동(`NoteView.swift:935`). 이것이 ① 버그의 직접 원인.
3. **stroke는 절대좌표·reflow 없음** — `PKDrawing.dataRepresentation()` 저장/`PKDrawing(data:)` 로드, 폭 메타데이터 없음 (`NoteView.swift:889-894, 564-593`).
4. **카드 폭은 현재폭 추종, Y는 저장 절대값** — `cardWidth = effectiveWidth - 32`(`:1104`), `card.frame y: fb.positionY`(renderCard).
5. **카드 Y는 stroke 절대좌표에 의존** — `calculateNextCardY` = `max(stroke renderBounds.maxY, lastRenderedBottom)+24` (`NoteView.swift:1312-1328`).
6. **폭 기준이 분산됨** — frozen은 `max(lastKnownWidth, contentSize.width)`(`:1046`), 카드는 `lastKnownWidth`(`:1101`). SSOT 없음.
7. **orientation은 split 레이아웃 분기에만 사용** — `isLandscape`(`NoteView.swift:46-48`)는 HStack/VStack 선택용(`:56-72`)일 뿐 캔버스 폭 재계산 트리거 없음.
8. **카드 좌표는 서버로 안 감** — `positionY`/`bboxY`/`strokeRange*`는 `FeedbackRecord`(로컬 GRDB)에만. 좌표 변경은 클라 단독 결정 가능.
9. **분할 비율은 고정 40:60, 영속 안 됨** — 가로 `width: geo.size.width * 0.4`(`:59`), 세로 `height: geo.size.height * 0.4`(`:66`), 사이는 드래그 불가 `Divider()`(`:60, 67`). 비율 상태값/제스처 없음 → divider 리사이즈는 순수 추가 기능(제거할 기존 로직 없음).
10. **카드 재렌더 멱등 가드 존재** — `renderAllCards`는 `effectiveWidth`+피드백 시그니처로 스킵 판단(`:1078-1085`). 단 폭이 바뀌면 시그니처가 달라져 스킵 안 됨 → 드래그 중 폭 연속 변경 시 매 프레임 재렌더 위험.

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | iPad 모델별 실제 `bounds.width` 값 (세로 전체 / 가로+PDF 60% / 가로 전체) | 실기기에서 `appLogDebug "canvas" bounds` 로그 수집 (이미 로깅 중, `:896-915`) |
| 2 | Option A의 `LOGICAL_CANVAS_WIDTH` 적정값 (세로폭? 더 좁게?) | 1번 측정 후 결정 |
| 3 | Option C: PencilKit scrollView에서 zoom + 세로 무한 스크롤 동시 운용 가능성 | C-1 PoC |
| 4 | Option B: 기존 카드 `positionY`가 저장될 때의 폭(authoredWidth 부재) 추적 가능 여부 | 마이그레이션 시 기존 레코드는 기본폭 가정 처리 — 데이터 영향 검토 |
| 5 | 회전이 SwiftUI 재구성 외에 `updateUIView`를 확실히 트리거하는지(같은 PKCanvasView 인스턴스 재사용 여부) | 회전 시 `updateUIView` 로그 확인 |
| 6 | divider 비율 영속 범위 (세션 휘발 vs `UserDefaults`, 노트별 vs 전역) | product 결정 — 기본 세션 휘발 |
| 7 | 가로 divider 드래그 시 `bounds.width` 변경이 `updateUIView`/contentSize 경로를 트리거하는지 (`.frame` 변경이 PKCanvasView까지 전파되는지) | 드래그 후 `canvas bounds` 로그 확인 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 설계 옵션 미결정 상태로 구현 착수 | 큰 재작업 | §4 결정을 §5 착수의 명시적 블로커로 둠 |
| Option B 반복 회전 시 stroke 좌표 드리프트 | 손글씨 누적 왜곡 | authoredWidth 기준 절대 재계산(상대 누적 금지) — 권장하지 않음 |
| Option B/C에서 카드 높이 폭-비선형 | frozen 영역·다음 카드 Y 어긋남 | 폭 변경마다 카드 높이 재측정(`sizeThatFits`) 후 Y 재배치 |
| 단일 파일(`NoteView.swift`) 집중 | 병렬 불가, merge 충돌 | coordinator/카드 렌더를 별 파일로 추출 선행(선택) |
| 회전 중 저장 타이밍 | 좌표 유실/덮어쓰기 | 회전 핸들링과 `saveDrawing`(2초 debounce, `:1367`) 순서 검증 |
| 시뮬레이터에서 orientation·펜 동작 차이 | 검증 누락 | 실기기 회전 검증 필수(시뮬레이터는 보조) |
| **divider 드래그 중 매 프레임 카드 재렌더(KaTeX WKWebView reload)** | 드래그 끊김/발열 | 드래그 중 비율만 갱신, 폭-변경 재계산은 `onEnded` 1회(R-3) |
| divider 극단 비율로 캔버스/PDF가 너무 좁아짐 | 사용 불가 | clamp `[0.2, 0.7]` 등 범위 제한 |
| 가로 divider가 묶음1 옵션 미선택 시 좌표 어긋남 | 카드/필기 깨짐 | R-2를 묶음1 옵션 완료의 명시적 블로커로(세로 R-1은 독립 진행 가능) |
