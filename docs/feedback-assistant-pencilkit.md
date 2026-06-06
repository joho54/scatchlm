# Feedback Assistant 제출용 초안 (영문)

> feedbackassistant.apple.com → "Developer Technologies & SDKs" → Frameworks → PencilKit 으로 제출.
> 최소 재현 프로젝트(zip)와 TSan 로그를 첨부하면 채택 확률이 크게 오른다.

---

**Title:**
`PKDrawing.image(from:scale:)` is not thread-safe and silently corrupts process-wide PencilKit render state when called off the main thread (not caught by Main Thread Checker)

**Area / Framework:** PencilKit

**Type:** Incorrect/Unexpected Behavior

---

**Summary**

Calling `PKDrawing.image(from:scale:)` from a background thread (e.g. inside `Task.detached` or a `DispatchQueue.global()` block) corrupts PencilKit's process-wide rendering state. The corruption is not confined to the call site: a *different* `PKCanvasView` elsewhere in the same process subsequently stops accepting strokes entirely (drawing gesture begins, then PencilKit rejects the stroke internally — system log shows `updateStrokeAcceptanceState rejecting stroke. targetSearchFailed: Y`).

Critically, this violation is **not flagged by the Main Thread Checker**, so it fails silently. The corruption is intermittent (a race between the background render and main-thread canvas rendering), process-wide, and persists across app relaunch (only a device reboot clears it). The damage site (a thumbnail render on screen A) is completely decoupled from the symptom site (drawing input on screen B), which makes this extremely hard to diagnose.

**Steps to Reproduce**

1. Create an app with a `PKCanvasView` used for Apple Pencil drawing on one screen (e.g. pushed via `NavigationStack`).
2. On the root/list screen, render many note thumbnails by calling `drawing.image(from:scale:)` **off the main thread**, e.g.:
   ```swift
   let img = await Task.detached(priority: .utility) {
       let drawing = try PKDrawing(data: data)
       return drawing.image(from: rect, scale: scale)   // off-main render
   }.value
   ```
   (Multiple cards each spawn their own background render task → several concurrent off-main renders.)
3. Run on a physical iPad. Navigate into the canvas screen and draw with Apple Pencil while/after the background thumbnail renders occur.

**Expected Result**

Either:
- `PKDrawing.image(from:scale:)` is safe to call off the main thread, OR
- It traps / asserts immediately (fail-fast, like other main-thread-only APIs surfaced by the Main Thread Checker), OR
- The main-thread requirement is explicitly documented and the method is annotated (`@MainActor`).

In all cases, an off-main call must NOT silently corrupt unrelated `PKCanvasView` instances in the same process.

**Actual Result**

After the off-main `drawing.image()` renders, an unrelated `PKCanvasView` intermittently stops accepting strokes process-wide. `touchesBegan` fires with a pencil touch, the drawing gesture reaches `.began`, but no stroke is committed (`canvasViewDrawingDidChange` never fires; stroke count stays flat). System log on the wedged process shows:
```
Began drawing
finishedElementFindingWithElement: 0x0
updateStrokeAcceptanceState rejecting stroke. targetSearchFailed: Y
Gesture touch cancel called. Cancelling gesture.
```
The condition persists across app relaunch and is only cleared by a device reboot. A separate minimal app using `PKCanvasView` draws fine on the same device at the same time (confirming it is process-scoped, not device/OS-wide). Main Thread Checker does not report any violation.

**Diagnosis (how we isolated it)**

We ruled out, via controlled experiments, every other factor: canvas configuration (host scroll view, zoom, tiled layer), our gesture recognizers, `PKToolPicker`/first-responder, text fields/Scribble, a third-party crash reporter, and PDFKit. A minimal standalone `PKCanvasView` app worked on the same device while ours failed, proving the issue is scoped to our process. Bisecting the view stack, the failure correlated 1:1 with the presence of a thumbnail grid that called `PKDrawing.image()` off the main thread. Moving that single render call to the main thread fixed it completely.

**Requests**

1. Add a fail-fast check (`dispatchPrecondition(condition: .onQueue(.main))` or equivalent) to `PKDrawing.image(from:scale:)` so off-main misuse traps at the call site.
2. Extend Main Thread Checker coverage to PencilKit render entry points.
3. Document the main-thread requirement (and ideally annotate `@MainActor`) for `PKDrawing.image(...)` and related render APIs.

**Configuration**

- Device: iPad (physical), iPadOS 26.x
- Xcode: (작성 시 버전 기입)
- Reproducibility: Intermittent (timing race); reliably enters the wedged state under repeated concurrent off-main renders.

**Attachments**

- Minimal reproducer project (zip).
- Thread Sanitizer log capturing the race (if available — strongly recommended).
- Console excerpt showing `targetSearchFailed` on the wedged process.
