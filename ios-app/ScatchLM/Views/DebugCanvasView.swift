#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 — **스텝 3: 스텝2 구조 + defer 픽스 검증.**
///
/// 스텝1(raw + contentSize-only 확장) = 떨림 없음. 스텝2(host>content>canvas + frame 확장) = **떨림 재현.**
/// → 범인 확정: 펜 접촉 중 `setContentHeight`로 PKCanvasView bounds를 리사이즈하는 것.
///
/// 스텝3은 같은 구조에 **defer만 추가**: 펜 접촉 중(isDrawingActive)엔 확장을 보류하고 펜업
/// (canvasViewDidEndUsingTool)에 1회 flush. 진행 중 스트로크는 펜다운 시점 2-viewport 버퍼 안이라
/// 보류해도 안 잘린다. 떨림이 사라지면 실제 앱(NoteView)에 이 픽스를 되살린다.
///
/// 판정:
/// - **안 떨림** → defer 픽스 검증 완료 → ba60936 재적용.
/// - **여전히 떨림** → defer로 부족 → mid-stroke 외 다른 mutate 경로 잔존.
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

        // defer 픽스: 펜 접촉 중엔 확장 보류, 펜업에 flush.
        private var isDrawingActive = false
        private var pendingHeight: CGFloat?

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isDrawingActive = true
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isDrawingActive = false
            if let h = pendingHeight { pendingHeight = nil; setContentHeight(h) }
        }

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
            // defer: 펜 접촉 중엔 목표 높이만 적립하고 mutate 안 함 → 펜업에 flush.
            if isDrawingActive {
                pendingHeight = max(pendingHeight ?? 0, h)
                return
            }
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
