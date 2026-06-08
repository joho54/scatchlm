#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 — **스텝 6: windowed 캔버스(해법 검증).**
///
/// 범인 확정: PKCanvasView가 큰 frame(bounds)을 가지면 떨림(스텝4 떪, 스텝5 안 떪 — 변수는 bounds 크기뿐).
///
/// 스텝6은 해법 후보 검증: host 계층(카드·줌용)은 그대로 두되, **캔버스를 뷰포트 크기로 고정**하고
/// host 스크롤을 따라 frame.origin + contentOffset을 옮겨 "보이는 슬라이스"만 렌더하는 windowed 방식.
/// 캔버스 bounds 크기는 항상 뷰포트라 떨림 조건(큰 bounds)을 회피. ink는 content 좌표 그대로.
///
/// 판정:
/// - **안 떨림(깊은 위치에서도)** → windowed 해법 검증 완료 → 실제 NoteView에 포팅.
/// - **떨림** → windowed로도 부족 → 네이티브 복귀 검토.
struct DebugCanvasView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HostWindowedCanvas()
                .ignoresSafeArea()
            Button("닫기") { dismiss() }
                .padding(10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
    }
}

private struct HostWindowedCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> UIScrollView {
        let coord = context.coordinator
        let w = UIScreen.main.bounds.width
        let fixedH: CGFloat = 6000
        let viewportH = UIScreen.main.bounds.height

        let host = UIScrollView()
        host.delegate = coord
        host.alwaysBounceVertical = true
        host.contentInsetAdjustmentBehavior = .never
        host.backgroundColor = .systemGray5

        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: fixedH))
        contentView.backgroundColor = .systemBackground
        host.addSubview(contentView)
        host.contentSize = contentView.bounds.size

        // windowed: 캔버스는 뷰포트 크기로 고정(bounds 작게 = 떨림 회피). 큰 contentSize로 슬라이스 오프셋.
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: w, height: viewportH))
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentSize = CGSize(width: w, height: fixedH)   // 전체 높이만큼 슬라이스 가능
        contentView.addSubview(canvas)

        coord.host = host
        coord.contentView = contentView
        coord.canvas = canvas
        coord.viewportH = viewportH

        coord.toolPicker = {
            let tp = PKToolPicker()
            tp.setVisible(true, forFirstResponder: canvas)
            tp.addObserver(canvas)
            canvas.becomeFirstResponder()
            return tp
        }()
        return host
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coord { Coord() }

    final class Coord: NSObject, UIScrollViewDelegate {
        var toolPicker: PKToolPicker?
        weak var host: UIScrollView?
        weak var contentView: UIView?
        weak var canvas: PKCanvasView?
        var viewportH: CGFloat = 0

        // host 스크롤마다 캔버스 윈도우를 보이는 영역으로 이동 + 그 슬라이스를 렌더.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let canvas, let w = contentView?.bounds.width else { return }
            let y = max(0, scrollView.contentOffset.y)
            canvas.frame = CGRect(x: 0, y: y, width: w, height: viewportH)  // 뷰포트 위치로 이동(크기 불변)
            canvas.contentOffset = CGPoint(x: 0, y: y)                       // 같은 슬라이스를 렌더
        }
    }
}
#endif
