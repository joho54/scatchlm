# 캔버스 필기 진동(jitter) 조사

> **Status:** ✅ **해결**(2026-06-08). 진짜 원인은 **큰 PKCanvasView bounds** — windowed 캔버스로 픽스(`c5b2981`), 실기기 확인.
> **Date:** 2026-06-08
> **관련 메모리:** PencilKit off-main 렌더 손상(`3fc162a`)과는 **별개 버그**

---

## 결론 (최종, 소거법으로 확정 — §0의 텔레메트리 가설을 정정)

**진동의 진짜 원인: `PKCanvasView`가 큰 frame(bounds)을 가지면 펜 입력 시 떨린다.** 기존 코드가
`setContentHeight`에서 `canvas.frame = contentView.bounds`로 캔버스를 전체 높이(수천 pt)까지 키워,
그만큼 커진 시점("18줄 후")부터 떨렸다.

소거법(`DebugCanvasView`, 설정>디버그)으로 변수 하나씩 격리해 확정:
- 스텝1 raw 네이티브(canvas bounds=뷰포트, contentSize만 확장) → **안 떪**
- 스텝2 host>content>canvas + frame 확장 → **떪**
- 스텝3 스텝2 + defer(펜 접촉 중 확장 보류) → **여전히 떪** (확장 타이밍 무죄)
- 스텝4 host 구조 + 확장 0회, canvas bounds=6000 고정 → **떪** (확장 행위 무죄, 시작부터)
- 스텝5 스텝4와 동일하되 canvas bounds=뷰포트 → **안 떪** ← **단일 변수 = canvas bounds 크기 확정**
- 스텝6 windowed 캔버스(뷰포트 고정 + 스크롤 추적) → **안 떪**
- 스텝7 windowed + 줌 → **안 떪, ink 정확** → 포팅

**해법(`c5b2981`):** windowed 캔버스. `canvas.frame`은 뷰포트 크기로 고정하고 `updateCanvasWindow`가
보이는 슬라이스로만 배치(줌 s 반영). `setContentHeight`는 `contentView`/`host.contentSize`/
`canvas.contentSize`만 확장. 카드·종이는 contentView라 무영향, 좌표계 불변.

> ⚠️ 아래 §0~§6은 **초기(틀린) 가설 "NoteView 재생성 루프"의 조사 기록**이다. 그 루프(autosave→sync→
> HomeView reload→navigationDestination 재평가→NoteView @State 소실)는 실재했고 `6ce20ef`로 차단했으나,
> **진동의 주원인은 아니었다**(루프 차단 후에도 떨림 잔존 → 소거법으로 큰 bounds가 진짜 원인임을 확정).
> 기록 보존용으로 남긴다.

---

---

## 0. 결론 (2026-06-08 실기기 재현으로 확정)

진동의 정체는 **NoteView 전체가 필기 도중 teardown→재생성**되는 것이다. contentOffset
teleport·contentH 1668 리셋은 모두 이 재생성의 증상이었다.

**인과 사슬 (전부 우리 코드 — OS/프레임워크 탓 아님):**
```
필기 → autosave 2s 디바운스(NoteView.swift:2034) → saveDrawing → db.savePageDrawing
  → db.onWrite 훅(SyncService.swift:62) → scheduleDebouncedSync 1.5s
  → performSync → lastSyncedAt = Date()  (SyncService.swift:165)
  → HomeView.onChange(of: sync.lastSyncedAt) → loadNotes()  (HomeView.swift:173)
  → notes @State 재할당 → NavigationStack 루트(HomeView) 재렌더
  → .navigationDestination 클로저 재평가 → 푸시된 NoteView 재생성 = @State 전소실
  → canvasView = 빈 NoteCanvasView() → makeUIView(strokes=0, initialH=1668)
  → contentH 1668·offset 0 리셋 → 화면 점프(진동) → initialDrawingData로 그림 재로드 → 복귀
```

**확정 증거 (app_logs, 11:51–11:52):**
- `makeUIView`가 필기 도중 반복 발화, **매번 `strokes=0`**(= @State `canvasView` 기본값
  `NoteCanvasView()`로 리셋 = NoteView 새 인스턴스). 직후 `geom`이 `boundsH=0, offsetY=0,
  contentH=1668` 리셋을 보이고 이어 재성장.
- **모든 `makeUIView` 직전에 `loadNotes`(tag=home)가 선행**. `loadNotes`는 `lastSyncedAt`
  변경으로만 발화하고 그건 autosave 발 debounced sync의 결과 — 타임라인 교차검증으로 사슬 확정.
- `zoom=1.0000` 전 구간 불변(초기 "줌인" 가설은 §2.1대로 반증된 채 유지).

**픽스:** `HomeView.swift` — **노트 열람 중(`path` 비어있지 않음)엔 sync 발 리스트 재로드를
보류**하고 리스트 복귀 시 1회 반영(`pendingHomeReload`). NavigationStack 루트 재렌더 자체를
없애 destination 재평가→NoteView 재생성 사슬을 끊는다.

> ⚠️ **실기기 재검증 전까지 "해결"로 보고하지 않는다.** 시뮬레이터 빌드 성공·코드상 사슬 차단은
> 동작 확인이 아니다. `make reinstall-dev` 후 18줄+ 필기로 진동 재현이 사라지고 `makeUIView`가
> 필기 도중 더는 안 찍히는지 app_logs로 확인해야 종결.

---

## 1. 증상 (사용자 보고)

- 캔버스 생성 초반에는 정상.
- 평범한 크기로 **약 18줄** 정도 필기 후부터, 필기할 때마다 캔버스가 흔들림.
- **증상 시작 후 복구 안 됨** (영구 지속).
- 펜이 닿는 순간 좌표계가 변한 상태로 고정 — **대체로 줌인된 것처럼 보이고**, 오프셋이 들어간 채 필기됨.
- **펜을 떼면 정상 복귀.**
- 피드백 카드 존재 여부와 무관.

---

## 2. 텔레메트리 증거 (2026-06-06, iPad, viewport 681pt)

> ⚠️ 아래 데이터를 만든 계측(`geom jump`/`offset jump`/`contentOffset` override)은 **커밋되지 않은
> 일회성 로컬 빌드**의 산물이었다(`git log -S "geom jump"` = 0). 현재 워킹트리엔 없으며,
> `dc9e65c`로 **다시 투입**했다(§4). 아래는 그 06-06 빌드가 `app_logs`에 남긴 기록.

### 2.1 줌은 변하지 않는다 — "줌인"은 오인

`geom` 로그 전 구간 `zoom = 1.0000` **불변**. 사용자가 "줌인됐다"고 느낀 것은 실제 scale 변화가
아니라 **scroll offset의 순간이동(teleport)을 오인**한 것.

→ 초기 1순위 가설이었던 "`fitAndCenter`의 zoomScale 변경"은 **데이터로 반증됨.**

### 2.2 contentOffset.y가 필기 중 수백 pt씩 튄다

```
02:40:54 offsetY=0
02:40:58 offsetY=770    ← +770 점프
02:41:01 offsetY=612    ← -158
02:41:04 offsetY=887    ← +275
02:41:06 offsetY=0      ← 리셋 (boundsH=0 동반)
02:41:16 offsetY=1603   ← +1603 점프
02:41:17 offsetY=2054   ← +451, 이후 고정
```

이 frame-to-frame offset 점프 = 화면에 보이는 진동.

### 2.3 `setH`(setContentHeight)가 거의 매 스트로크 콜백마다 발화

한 초 안에 `setH` 여러 번: `3564 → 3578 → 3660`(02:41:17), 다음 초 `3779`(02:41:18). 즉
**펜이 닿아 있는 동안 `contentView.bounds`/`center`/`canvas.frame`/`host.contentSize`가 매
`canvasViewDrawingDidChange` 콜백마다 mutate**된다. (`setH`의 `originY`는 0.0 고정 → center 재계산
드리프트는 이 케이스에선 진동원 아님.)

### 2.4 contentH가 중간에 초기값 1668로 리셋된다

`contentH 3142 → 1668`(02:41:06·:10·:13), 매번 `boundsH=0` 동반. `1668 = logical(834)×2` =
**갓 만든 contentView 초기 높이**(`NoteView.swift` makeUIView `contentView.frame = …, height: logical*2`).
→ 필기 도중 contentView/캔버스가 **재생성/리셋**되는 thrashing 의심. "복구 안 됨"과 연결 가능성.

### 2.5 contentOffset을 UIKit 내부가 set

`offset jump` 스택:
```
$s8ScatchLM14HostScrollViewC13contentOffsetSo7CGPointVvsTo < ScatchLMApp.$main
dy=17, from=-17, to=0
```
→ `HostScrollView.contentOffset` setter가 호출되는데, 스택이 **심볼 미해석**이라 호출자 불명.
UIKit 내부(자동스크롤/clamp)인지 우리 코드인지 구분 불가 — **이게 핵심 미규명 지점.**

---

## 3. 현재 가설 (확정 아님)

| 가설 | 상태 | 비고 |
|---|---|---|
| zoomScale 변경(fitAndCenter) | ❌ **반증** | zoom=1.0 불변 |
| contentOffset.y teleport가 진동의 정체 | 🟡 유력 | 누가 set하는지 미규명(§2.5) |
| `setH`가 매 콜백 발화 → 활성 스트로크 중 geometry mutate | 🟡 유력 | §2.3 확인됨. 진동 기여 추정 |
| contentView 1668 리셋 thrashing | 🟡 의심 | §2.4. "복구 불가"의 후보 |

"18줄" 임계는 `drawingBottom`이 `현재 contentHeight − 2×viewport`를 넘어 `ensureContentHeight`가
매 콜백 발화로 전환되는 지점으로 추정되나 **미확정**.

---

## 4. 투입한 진단 계측 (커밋 `dc9e65c`, `NoteView.swift`)

전부 `appLogDebug` → **Debug 빌드(`make reinstall-dev`)에서만** 백엔드 전송.

1. **`HostScrollView.contentOffset` override** — `isDrawingActive`(펜 다운 중)일 때만, `|dy|>2`인
   offset 변경의 `Thread.callStackSymbols`(상위 8프레임)를 `canvas / "offset set"`으로 기록.
   → **목적: contentOffset을 누가 set하는지(UIKit 자동스크롤/clamp vs 우리 코드) 확정.**
2. **`canvasViewDidBeginUsingTool` / `canvasViewDidEndUsingTool`** — 펜 다운/업으로
   `isDrawingActive` 토글. begin 시 baseline(`offsetY`/`contentH`/`strokes`)을 `"tool begin"`으로 기록.
   → 평상시 스크롤·팬 노이즈를 배제하고 증상 창에서만 호출자 캡처.
3. **`makeUIView` 재호출 로그** — `"makeUIView"`(strokes 수 포함). 필기 도중 찍히면 contentView
   재생성(=contentH 1668 리셋, §2.4) 확정.

---

## 5. 다음 단계 (실기기 재현)

1. `cd ios-app && make reinstall-dev` (Debug 빌드 — appLogDebug 전송 필수)
2. 노트에서 18줄+ 필기 → 진동 재현
3. 로그 조회:
   ```sql
   SELECT ts, message, data FROM app_logs
   WHERE ts > now() - interval '2 hours' AND tag='canvas'
     AND message IN ('offset set','tool begin','makeUIView')
   ORDER BY ts;
   ```
4. **판정 기준:**
   - `offset set`의 `stack` 첫 프레임 → 호출자. `ScatchLM…`이면 우리 코드 경로(예: `scrollCardIntoView`),
     `_UIScrollView…`/`PK…`면 UIKit 자동스크롤/clamp.
   - `makeUIView`가 **필기 도중** 찍히면 → SwiftUI 캔버스 재생성이 근본 원인(§2.4 확정).

호출자 한 줄만 잡히면 fix 방향 결정 가능 (예: UIKit 자동스크롤이면 host 대신 캔버스 scroll 위임 차단,
contentSize clamp면 `setContentHeight`를 스트로크 종료로 디퍼, 재생성이면 SwiftUI identity 안정화).

> 원인 확정 후 디버그 전용 계측은 정리(또는 `appLogDebug` 유지) 할 것.

---

## 6. 미규명 명시

CLAUDE.md 원칙대로 — 후보를 배제·좁혔을 뿐 **근거(로그/재현)로 호출자를 지목하지 못했다.**
현재는 "원인 미규명, 계측만 투입" 상태이며, 실기기 재현으로 §5-4 판정이 나오기 전까지
어떤 가설도 확정으로 보고하지 않는다.
