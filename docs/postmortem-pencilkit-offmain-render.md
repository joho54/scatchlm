# 포스트모템: 노트 필기 프로세스 전역 먹통 (off-main `PKDrawing.image()`)

- **날짜**: 2026-06-06
- **수정 커밋**: `3fc162a` (main)
- **영향 파일**: `ios-app/ScatchLM/Views/HomeView.swift` (`NoteCardView.loadThumbnail`)
- **심각도**: 높음 — 핵심 기능(Apple Pencil 필기)이 간헐적으로 완전 불능
- **상태**: 해결(실기기 반복 확인). 단 내부 메커니즘 일부는 추론(아래 §정직한 경계)

---

## 1. 한 줄 요약

홈 화면 노트 카드의 **썸네일 렌더(`PKDrawing.image()`)를 백그라운드 스레드(`Task.detached`)에서 호출**한 것이, PencilKit의 프로세스 전역 공유 렌더 상태를 손상시켜 **같은 프로세스의 노트 캔버스 필기를 프로세스 전역으로 먹통**으로 만들었다. DB I/O만 백그라운드에 두고 렌더 호출을 메인 스레드로 옮겨 해결.

## 2. 증상

- iPad 실기기에서 노트 캔버스에 펜으로 그어도 **획이 안 그려짐**.
- **간헐적**: 같은 빌드·같은 코드인데 될 때도 있고 안 될 때도 있음. "안 되는 상태"에 들어가면 대부분의 획이 거부되고 가끔 하나만 통과.
- **재부팅하면 잠깐 풀렸다가 다시 먹통**. 앱 재실행으로는 안 풀림.
- 시뮬레이터에서는 재현 안 됨. 같은 기기에서 **Apple 메모/Freeform/별도 테스트앱은 정상**.
- (부차적) 일부 빌드에서 입력계 전체 wedge(버튼도 안 먹힘) — 이는 별개 원인이었음(§6).

## 3. 영향

- 핵심 학습 루프(손글씨 → AI 피드백)의 입력 단계가 막힘.
- Debug 빌드에서 관측됨. 실유저(Release/TestFlight) 영향 범위는 별도 확인 필요 — 같은 코드 경로(홈 썸네일)는 Release에도 존재하므로 잠재적으로 동일.

## 4. 근본 원인

`HomeView`의 노트 카드는 첫 페이지 그림을 썸네일로 렌더한다. 수정 전:

```swift
let img: UIImage? = await Task.detached(priority: .utility) {   // 백그라운드
    ...
    return drawing.image(from: rect, scale: scale)              // PencilKit 렌더를 off-main에서
}.value
```

`PKDrawing.image()`는 메인 스레드 전용 렌더 API다. PencilKit은 프로세스 전역 공유 렌더 컨텍스트(Metal 계열)를 쓰며, 내부적으로 "단일 스레드(메인)에서만 호출된다"는 가정으로 락 없이 구현돼 있다. 이 가정을 백그라운드 호출이 깨면서 공유 가변 상태가 손상됐다.

**"손상"의 구체적 후보** (PencilKit 내부 비공개라 부류로만):
- 공유 가변 상태(refcount/캐시/프리리스트)에 대한 **데이터 레이스** → use-after-free·갱신 유실.
- 자료구조 **불변식 깨짐**(절반 수정된 상태를 다른 스레드가 읽음).
- GPU command queue/context의 **스레드 친화성(thread affinity) 위반** → 렌더 상태머신 꼬임. (이건 락으로도 못 막고 올바른 스레드로 hop만이 답.)

손상이 **프로세스 전역 싱글톤(공유 렌더러) 또는 시스템 렌더/handwriting 데몬과의 per-app 연결**에 눌러앉아, 앱 재실행에도 지속되고 재부팅에서만 풀린 것으로 보인다.

## 5. 왜 찾기 어려웠나

모든 증상이 이 원인과 정합적이라 오히려 함정이 많았다:
- **프로세스 전역**이라 캔버스 설정과 무관 → "캔버스 코드"를 아무리 봐도 안 나옴.
- **간헐적**(렌더 타이밍 레이스)이라 단일 테스트 신뢰 불가.
- **손상 지점 ≠ 증상 지점**: 원인은 "홈 썸네일 렌더", 증상은 "노트 캔버스 필기" — 다른 화면, 다른 시점.
- **Main Thread Checker가 못 잡음**: `PKDrawing.image()`는 런타임 체커 커버리지 밖. 조용히 손상.
- 콘솔 시스템 로그에 `targetSearchFailed`/`rejecting stroke` 등 PencilKit 내부 비공개 심볼만 보여 외부 문서로 해석 불가.

## 6. 조사 과정 (이분법 통제실험)

관측 가능한 모든 touchesBegan-시점 변수(스칼라·뷰계층·hit-test·제스처체인·tool·픽셀)가 됨/안됨에서 **동일**함을 먼저 확인 → 수동 관측 한계 도달. 이후 **하나씩 배제**:

| 실험 | 결과 | 결론 |
|---|---|---|
| 캔버스 hit-test/뷰계층 | clean | 오버레이/덮임 아님 |
| 제스처 chain (pasteLongPress/require/editMenu/activate) | 실패 | 무죄 |
| PKToolPicker + becomeFirstResponder | 실패 | 무죄 |
| vanilla PKCanvasView (host/zoom/tiled 제거) | 실패 | 캔버스 설정 무죄 |
| 텍스트 필드 존재(handwriting 의심) | 정상 | 무죄 |
| Sentry off | 실패 | 무죄 |
| PDF 뷰어 차단 | 실패 | 무죄 |
| **별도 최소앱(InkTest)** | **정상** | **기기/OS 무죄 → 우리 앱 프로세스 한정 확정** |
| 앱 루트 = 맨 캔버스 | 정상 | 앱 init/프레임워크 무죄 |
| 서비스(auth/realtime/sync)만 켜고 맨 캔버스 | 정상 | 서비스 무죄 |
| NoteView body = 맨 캔버스 (navigationDestination push) | 실패 | **NoteView body 무죄, push 컨텍스트 의심** |
| 최소 NavigationStack 루트 캔버스 | 정상 | NavigationStack 자체 무죄 |
| 최소 NavigationStack push 캔버스 | 정상 | push 메커니즘 무죄 |
| HomeView toolbar/searchable 제거 | 실패 | 무죄 |
| **→ 남은 차이 = notesGrid 썸네일** | — | `loadThumbnail`의 off-main `PKDrawing.image()` 발견 |
| **썸네일 렌더 메인으로 이동** | **정상** | **원인 확정** |

패턴: **썸네일 grid가 있는 화면은 전부 실패 / 없는 화면(프로브·별도앱)은 전부 정상.**

조사 중 **자체 유발한 confound**도 있었음: 진단용으로 넣은 픽셀 프로브가 `drawHierarchy(afterScreenUpdates: true)`를 메인에서 동기 호출 → 메인 스레드 hang(버튼 먹통=상태2). 이건 제거로 해결, 본 버그(상태1)와 분리.

## 7. 수정

```swift
// DB I/O만 백그라운드, PKDrawing.image() 렌더는 메인 스레드(View 메서드 = @MainActor)
let data: Data? = await Task.detached(priority: .utility) {
    guard let pages = try? DatabaseService.shared.pages(noteId: noteId),
          let first = pages.first else { return nil }
    return first.drawingData
}.value
guard let data, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else {
    self.thumbnail = nil; return
}
...
self.thumbnail = drawing.image(from: rect, scale: scale)   // 메인 스레드
```

락을 거는 게 아니라 **올바른 스레드로 hop**하는 게 정답 — 데이터 레이스와 스레드 친화성 위반을 한 번에 해소.

## 8. 교훈

1. **"main thread only" API는 내부 무동기화 + 스레드 친화성을 호출 규약으로 떠넘긴 계약이다.** UIKit·PencilKit·Core Animation·`UIView`/`CALayer` 대부분이 해당. 백그라운드에서 계산·I/O는 하되, 그 결과로 이들 API를 건드릴 땐 반드시 `@MainActor`/`MainActor.run`으로 복귀.
2. **`PKDrawing.image()`는 Main Thread Checker로 안 잡힌다 → 조용히 프로세스 전역 손상.** fail-fast가 안 되는 API라 특히 위험.
3. **Swift 6 `@MainActor`(strict concurrency)가 진짜 방어선.** 이 버그는 컴파일 타임에 막을 수 있는 종류였다. 문서-계약을 코드-계약으로.
4. **손상 지점 ≠ 증상 지점인 버그는 통제실험(이분법)으로 역추적.** "별도 최소앱"이 앱-vs-기기를 가른 결정적 한 수였다.
5. **진단 계측 자체가 confound가 될 수 있다**(메인 동기 `drawHierarchy`). 무거운 계측은 메인 hang/오염을 의심하라.

## 9. 후속 액션 (TODO)

- [ ] 코드베이스 전역에서 `Task.detached`/`global()` 안의 UIKit·PencilKit·Core Graphics/Animation 렌더 호출 grep 점검 (동일 패턴 재발 방지).
- [ ] Release/실유저에 동일 증상 흔적 있는지 prod 로그 확인.
- [ ] (장기) strict concurrency(`@MainActor`) 도입 검토 — 같은 부류를 컴파일 타임에 차단.

## 정직한 경계 (CLAUDE.md 원칙)

- **확정된 사실**: off-main 렌더 → 먹통, 메인 렌더 → 정상(실기기 반복 확인). grid 유무와 증상이 1:1. 별도 앱 정상 → 우리 앱 프로세스 한정.
- **추론(미확정)**: "손상"의 정확한 내부 메커니즘(데이터 레이스 vs 스레드 친화성 vs 데몬 연결)은 PencilKit 비공개라 단정 불가. 정밀 규명이 필요하면 Thread Sanitizer로 레이스 주소·콜스택을 확보하는 것이 다음 수단.
