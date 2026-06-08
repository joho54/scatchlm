#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 — **스텝 1: raw 네이티브 캔버스 + contentSize-only 확장.**
///
/// 이 버그는 캔버스가 확장될 때만 발현된다(확장 없으면 재현 불가). 그래서 baseline은
/// "확장하는 가장 단순한 캔버스"다:
/// - raw `PKCanvasView`, **네이티브 스크롤**(isScrollEnabled=true).
/// - 우리 host 계층·contentView·center 재계산·indicator·@State 재렌더 **전부 없음**.
/// - 유일한 확장: `canvasViewDrawingDidChange`에서 **`contentSize.height`만** 키운다.
///   (우리 실제 코드처럼 `canvas.frame`/bounds를 키우지 않는다 — bounds는 뷰포트 그대로.)
///
/// 판정:
/// - **안 떨림** → 네이티브 contentSize 확장은 안전. 범인은 우리 frame 확장(host 계층). 다음 스텝에서 추가.
/// - **떨림** → 확장(contentSize) 자체가 PencilKit를 흔든다 → 문제 재정의.
struct DebugCanvasView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NativeGrowCanvas()
                .ignoresSafeArea()
            Button("닫기") { dismiss() }
                .padding(10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
    }
}

/// raw PKCanvasView. 네이티브 스크롤. 유일한 부착물 = contentSize만 키우는 delegate.
private struct NativeGrowCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        // 펜=그리기, 손가락=스크롤로 분리(.anyInput이면 손가락도 그리기로 먹혀 스크롤 불가).
        // 펜이 없으면 그릴 수 없으니, 펜 없는 환경에선 .anyInput으로 바꿀 것.
        canvas.drawingPolicy = .pencilOnly
        canvas.alwaysBounceVertical = true
        canvas.backgroundColor = .systemBackground
        canvas.contentSize = CGSize(width: UIScreen.main.bounds.width, height: 1500)
        canvas.delegate = context.coordinator

        let tp = PKToolPicker()
        tp.setVisible(true, forFirstResponder: canvas)
        tp.addObserver(canvas)
        canvas.becomeFirstResponder()
        context.coordinator.toolPicker = tp
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coord { Coord() }

    final class Coord: NSObject, PKCanvasViewDelegate {
        var toolPicker: PKToolPicker?

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // 유일한 확장: contentSize.height만 키운다. bounds(뷰포트)·frame은 안 건드림.
            let bottom = canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }
            let target = bottom + canvasView.bounds.height   // 1 뷰포트 버퍼
            if canvasView.contentSize.height < target {
                canvasView.contentSize.height = target
            }
        }
    }
}
#endif
