#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 — **스텝 2: host>contentView>canvas + frame 확장.**
///
/// 스텝1(raw 네이티브 + contentSize-only 확장)은 **떨림 없음** 확인됨 → 확장 자체는 무죄.
/// 이번엔 우리 실제 구조의 한 겹만 추가: PKCanvasView를 스크롤 주체에서 강등(isScrollEnabled=false)
/// 하고 host(UIScrollView)가 스크롤을 담당. canvas는 contentView 안의 **full-height 정적 subview**라
/// 매 stroke `canvas.frame`(=bounds)을 통째로 키운다(= 우리 setContentHeight).
///
/// 격리 대상: **펜 접촉 중 PKCanvasView의 bounds를 리사이즈**하는 것. (centerContent·indicator·
/// @State 재렌더·zoom-to-fit은 일부러 다 뺐다 — frame 확장 하나만 본다.)
///
/// 판정:
/// - **떨림** → frame(bounds) 확장이 범인 확정. 펜 접촉 중 bounds 리사이즈 회피가 해법.
/// - **안 떨림** → bounds 확장도 무죄 → 범인은 나머지 부작용(centerContent/@State/indicator). 다음 스텝.
struct DebugCanvasView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HostFrameGrowCanvas()
                .ignoresSafeArea()
            Button("닫기") { dismiss() }
                .padding(10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
    }
}

private struct HostFrameGrowCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> UIScrollView {
        let coord = context.coordinator
        let w = UIScreen.main.bounds.width
        let initialH: CGFloat = 1500

        let host = UIScrollView()
        host.delegate = coord
        host.alwaysBounceVertical = true
        host.contentInsetAdjustmentBehavior = .never
        host.backgroundColor = .systemGray5

        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: initialH))
        contentView.backgroundColor = .systemBackground
        host.addSubview(contentView)
        host.contentSize = contentView.bounds.size

        let canvas = PKCanvasView(frame: contentView.bounds)
        canvas.drawingPolicy = .pencilOnly   // 펜=그리기, 손가락=host 스크롤
        canvas.isScrollEnabled = false        // 강등: 스크롤은 host 담당
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = coord
        contentView.addSubview(canvas)

        coord.host = host
        coord.contentView = contentView
        coord.canvas = canvas

        let tp = PKToolPicker()
        tp.setVisible(true, forFirstResponder: canvas)
        tp.addObserver(canvas)
        canvas.becomeFirstResponder()
        coord.toolPicker = tp
        return host
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coord { Coord() }

    final class Coord: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        var toolPicker: PKToolPicker?
        weak var host: UIScrollView?
        weak var contentView: UIView?
        weak var canvas: PKCanvasView?

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let viewport = host?.bounds.height ?? 0
            let bottom = canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }
            ensureContentHeight(bottom + viewport * 2)
        }

        // 실제 NoteView.setContentHeight 포팅 (zoom=1 가정, center 재계산 포함, canvas.frame 확장).
        func ensureContentHeight(_ h: CGFloat) {
            guard let contentView else { return }
            if contentView.bounds.height < h { setContentHeight(h) }
        }

        func setContentHeight(_ h: CGFloat) {
            guard let host, let contentView else { return }
            let w = contentView.bounds.width
            let origin = contentView.frame.origin
            contentView.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            contentView.center = CGPoint(x: origin.x + w / 2, y: origin.y + h / 2)
            canvas?.frame = contentView.bounds          // ← 펜 접촉 중 PKCanvasView bounds 리사이즈
            host.contentSize = CGSize(width: w, height: h)
        }
    }
}
#endif
