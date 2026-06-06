# PencilKit이 조용히 죽인 필기 기능 — `PKDrawing.image()`를 백그라운드에서 부르면 생기는 일

> iPad 학습 앱에서 "펜으로 그어도 획이 안 그려지는" 간헐적 버그를 며칠에 걸쳐 추적한 기록.
> 결론부터: **홈 화면 썸네일 렌더가 PencilKit의 프로세스 전역 상태를 손상시켜, 전혀 다른 화면의 필기를 먹통으로 만들고 있었다.**

## 증상

- iPad 실기기에서 노트 캔버스(`PKCanvasView`)에 Apple Pencil로 그어도 **획이 안 생김.**
- **간헐적.** 같은 빌드, 같은 코드인데 될 때도 있고 안 될 때도 있다. "안 되는 상태"에 빠지면 거의 모든 획이 거부되고 어쩌다 하나만 통과.
- **재부팅하면 잠깐 멀쩡 → 다시 먹통.** 앱 재실행으론 안 풀린다.
- 시뮬레이터는 멀쩡. 같은 기기에서 **Apple 메모·Freeform·별도 테스트 앱은 정상.**

디버깅하기 가장 싫은 조합이다: 간헐적 + 프로세스 전역 + 재부팅까지 지속 + 다른 앱은 정상.

## 막다른 길들

처음엔 당연히 캔버스를 의심했다. 그런데 `touchesBegan` 시점에 찍을 수 있는 **모든 변수가 "될 때"와 "안 될 때"가 동일**했다:

- 터치 타입(pencil), first responder(true), drawing gesture enabled(true), drawing policy, thermal state, hit-test 결과(캔버스 자기 자신), 제스처 recognizer 체인, 활성 tool(펜)… 전부 같음.

시스템 콘솔에는 PencilKit 내부 로그만 보였다:

```
Began drawing
finishedElementFindingWithElement: 0x0
updateStrokeAcceptanceState rejecting stroke. targetSearchFailed: Y
Gesture touch cancel called. Cancelling gesture.
```

PencilKit이 그리기를 시작했다가 **스스로 스트로크를 거부**하고 있었다. 그런데 이 심볼들은 비공개라 웹·포럼 어디에도 설명이 없다. (실제로 검색에서 아무것도 못 찾았다.)

관측 가능한 모든 게 동일하다 = 수동 관찰의 한계. 여기서부터 **이분법 통제실험**으로 전환했다.

## 이분법으로 좁히기

하나씩 끄고 켜며 배제했다:

| 의심 | 결과 |
|---|---|
| 우리가 단 제스처(longpress/editMenu 등) | 제거해도 실패 → 무죄 |
| `PKToolPicker` + `becomeFirstResponder` | 제거해도 실패 → 무죄 |
| vanilla `PKCanvasView` (host scrollview/zoom 제거) | 실패 → 캔버스 설정 무죄 |
| 텍스트 필드 존재(Scribble 손글씨 의심) | 정상 → 무죄 |
| 크래시 리포터(Sentry) | 끄도 실패 → 무죄 |
| PDF 뷰어 | 차단해도 실패 → 무죄 |
| **별도 최소 앱(PKCanvasView 하나)** | **정상** |

마지막 줄이 전환점이었다. **별도 앱의 vanilla 캔버스는 같은 기기에서 멀쩡한데, 우리 앱 안의 vanilla 캔버스는 실패한다.** → 기기/OS 문제가 아니다. **우리 앱 프로세스 안에서 무언가가 PencilKit 전체를 망가뜨리고 있다.**

계속 좁혔다:

- 앱 루트를 맨 캔버스로 교체 → **정상** (앱 init/프레임워크 무죄)
- 서비스(인증/실시간/동기화)만 켜고 맨 캔버스 → **정상** (서비스 무죄)
- `NavigationStack`에 push된 캔버스 → **실패**
- 그런데 최소 `NavigationStack` push 캔버스 → **정상** (push 메커니즘 무죄)
- 차이는 단 하나, **홈 화면(`NavigationStack`의 루트)에 살아있는 노트 grid.**

패턴이 선명해졌다: **썸네일 grid가 있는 화면은 전부 실패 / 없는 화면은 전부 정상.**

## 범인

홈 화면 노트 카드의 썸네일 생성 코드였다:

```swift
let img: UIImage? = await Task.detached(priority: .utility) {   // ← 백그라운드 스레드
    ...
    return drawing.image(from: rect, scale: scale)             // ← PencilKit 렌더를 off-main에서
}.value
```

`PKDrawing.image(from:scale:)`는 **메인 스레드 전용 렌더 API**다. 그런데 `Task.detached`로 백그라운드에서 호출하고 있었다. 게다가 카드마다 `.task`가 붙어 있어서, 카드가 N개면 **N개의 백그라운드 스레드가 동시에** PencilKit 렌더러를 두드린다.

동시에 메인 스레드에서는 노트 캔버스가 펜 입력을 받아 같은 PencilKit 공유 렌더러를 쓰고 있었다.

```
메인:        노트 캔버스 렌더 ─┐
백그라운드1: 썸네일 렌더 ──────┼─→ PencilKit 프로세스 전역 공유 렌더 상태 (락 없음)
백그라운드2: 썸네일 렌더 ──────┘
```

PencilKit은 "메인 단일 스레드에서만 호출된다"는 가정으로 **락 없이** 구현돼 있다. 그 가정을 백그라운드 호출이 깨뜨리면서 공유 상태(렌더 컨텍스트/캐시/GPU command queue)가 손상됐고, 그 손상이 **프로세스 전역**이라 전혀 다른 화면의 노트 캔버스 필기까지 죽인 것이다.

- **프로세스 전역** → 어떤 캔버스든 무관(vanilla도 실패). 별도 앱은 별도 프로세스라 안전.
- **간헐적** → 썸네일 렌더와 캔버스 렌더가 시간상 겹칠 때만 레이스.
- **재부팅까지 지속** → 손상된 상태가 프로세스 전역 싱글톤 또는 시스템 렌더 데몬과의 연결에 눌러앉음.

## 수정

락을 거는 게 아니라 **올바른 스레드로 hop**하는 게 정답이다. DB I/O만 백그라운드에 두고, 렌더 호출은 메인에서:

```swift
let data: Data? = await Task.detached(priority: .utility) {
    guard let pages = try? DatabaseService.shared.pages(noteId: noteId),
          let first = pages.first else { return nil }
    return first.drawingData        // I/O만 백그라운드
}.value
guard let data, let drawing = try? PKDrawing(data: data),
      !drawing.strokes.isEmpty else { self.thumbnail = nil; return }
// PKDrawing.image()는 메인에서 (View 메서드 = @MainActor)
self.thumbnail = drawing.image(from: rect, scale: scale)
```

메인으로 고정하면 캔버스든 썸네일이든 순차 실행 → "동시에 만지는 일" 자체가 사라져 레이스가 원천 소멸한다.

## 교훈

1. **"main thread only" API는 내부에 동기화가 없다는 계약이다.** 락 대신 "한 스레드만 들어온다"는 규칙으로 상호배제를 달성한다(매 프레임 hot path라 락이 더 비싸서 의도된 설계). UIKit·PencilKit·Core Animation 대부분이 이렇다. 백그라운드에서 계산·I/O는 자유지만, 그 결과로 이들 API를 건드리는 순간 `@MainActor`/`MainActor.run`으로 복귀해야 한다.

2. **`PKDrawing.image()`는 Main Thread Checker로도 안 잡힌다.** Apple 런타임 체커의 사각지대라 위반해도 크래시 없이 조용히 손상된다. 이게 디버깅을 지옥으로 만든다 — 손상 지점("홈 썸네일")과 증상 지점("노트 필기")이 다른 화면, 다른 시점이라.

3. **fail-fast가 없으면 우리가 깐다.** 그 헬퍼 앞에 한 줄:
   ```swift
   dispatchPrecondition(condition: .onQueue(.main))
   ```
   위반 시 그 콜스택에서 즉시 죽는다. 며칠 → 5분.

4. **장기적 방어선은 Swift 6 `@MainActor`(strict concurrency).** 이 버그는 컴파일 타임에 막을 수 있는 종류였다. 문서-계약을 코드-계약으로 끌어올리는 것.

5. **손상 지점 ≠ 증상 지점인 버그는 통제실험으로 역추적한다.** "별도 최소 앱"이 앱-vs-기기를 가른 결정적 한 수였다.

## 정직한 경계

"off-main 렌더 → 손상, main 렌더 → 정상"은 실기기에서 반복 확인했다. 다만 손상의 **정확한 내부 메커니즘**(데이터 레이스 vs GPU 컨텍스트 스레드 친화성 vs 시스템 데몬 연결)은 PencilKit이 비공개라 단정할 수 없다. 정밀 규명이 필요하면 Thread Sanitizer로 레이스 주소·콜스택을 잡는 것이 다음 수단이다.

---

*검색해도 PencilKit thread-safety 자료가 거의 없어서 남긴다. 같은 함정 밟는 사람이 5분 만에 끝내길.*
