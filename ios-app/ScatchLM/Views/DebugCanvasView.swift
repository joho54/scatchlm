#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 — **스텝 7: windowed 캔버스 + 줌(포팅 전 최종 검증).**
///
/// 스텝6에서 windowed 캔버스(뷰포트 고정 + 스크롤 추적)가 떨림 없음 확인.
/// 스텝7은 실제 앱의 줌(zoom-to-fit + 핀치)을 추가해 좌표 합성을 검증한다.
///
/// 좌표: host가 contentView를 scale s로 줌하면 보이는 content 슬라이스 =
///   top = contentOffset.y / s, height = hostBounds.height / s.
/// 캔버스 윈도우를 이 슬라이스에 맞춘다(frame/contentOffset에 s 반영). 캔버스 화면 표시 크기는
/// 항상 host 뷰포트 = 정확히 보이는 영역을 채운다.
///
/// 검증 포인트:
/// - 줌 인/아웃 후 깊은 위치에서 그려도 **안 떨림** (특히 줌아웃 시 윈도우가 커지는데 임계 아래인지).
/// - 각 줌 배율에서 펜 **ink가 제 위치**에 찍히는지(좌표 합성 정확).
/// 둘 다 OK면 NoteView 포팅.
struct DebugCanvasView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HostWindowedZoomCanvas()
                .ignoresSafeArea()
            Button("닫기") { dismiss() }
                .padding(10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
    }
}

private struct HostWindowedZoomCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> UIScrollView {
        let coord = context.coordinator
        let w = UIScreen.main.bounds.width
        let fixedH: CGFloat = 6000

        let host = UIScrollView()
        host.delegate = coord
        host.alwaysBounceVertical = true
        host.bouncesZoom = true
        host.contentInsetAdjustmentBehavior = .never
        host.minimumZoomScale = 0.4   // 줌아웃 시 윈도우가 커지는 케이스 테스트
        host.maximumZoomScale = 3.0
        host.backgroundColor = .systemGray5

        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: fixedH))
        contentView.backgroundColor = .systemBackground
        host.addSubview(contentView)
        host.contentSize = contentView.bounds.size

        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: w, height: UIScreen.main.bounds.height))
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentSize = CGSize(width: w, height: fixedH)
        contentView.addSubview(canvas)

        coord.host = host
        coord.contentView = contentView
        coord.canvas = canvas
        DispatchQueue.main.async { coord.updateWindow() }   // 초기 1회

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

        // 줌(s) 반영: 보이는 content 슬라이스에 캔버스 윈도우를 맞춘다.
        // top = offset.y/s, height = hostBounds.height/s (content 좌표). frame/contentOffset 둘 다 content 좌표.
        func updateWindow() {
            guard let host, let canvas, let w = contentView?.bounds.width else { return }
            let s = max(host.zoomScale, 0.01)
            let topY = max(0, host.contentOffset.y / s)
            let visibleH = host.bounds.height / s
            canvas.frame = CGRect(x: 0, y: topY, width: w, height: visibleH)
            canvas.contentOffset = CGPoint(x: 0, y: topY)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateWindow() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { updateWindow() }
    }
}
#endif
