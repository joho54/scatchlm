#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 — **스텝 5: 큰 contentView + 작은(뷰포트) 캔버스 bounds.**
///
/// 스텝1(네이티브, canvas bounds=뷰포트, contentSize만 큼) = 떨림 없음.
/// 스텝4(demote, canvas bounds=6000 고정) = **확장 0회인데도 떨림(시작부터).**
/// → 트리거는 확장 행위가 아니라 **PKCanvasView가 큰 bounds를 가진 것** 자체로 좁혀짐.
///
/// 스텝5: 스텝4와 전부 동일(host>contentView(6000)>canvas, demote)인데 **canvas.frame만 뷰포트 크기**.
/// 위쪽(캔버스가 덮는 영역)에서 그려본다. canvas bounds 크기 하나만 변수.
///
/// 판정:
/// - **안 떨림** → 큰 canvas bounds가 범인 확정. 해법: 캔버스 bounds를 뷰포트로 유지(타일/윈도잉) 또는 네이티브.
/// - **떨림** → bounds 크기 무관, demote/nesting 자체가 범인 → 네이티브 복귀.
struct DebugCanvasView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HostStaticCanvas()
                .ignoresSafeArea()
            Button("닫기") { dismiss() }
                .padding(10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
    }
}

private struct HostStaticCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> UIScrollView {
        let coord = context.coordinator
        let w = UIScreen.main.bounds.width
        let fixedH: CGFloat = 6000   // 처음부터 크게 고정. 확장(setContentHeight) 전혀 없음.

        let host = UIScrollView()
        host.alwaysBounceVertical = true
        host.contentInsetAdjustmentBehavior = .never
        host.backgroundColor = .systemGray5

        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: fixedH))
        contentView.backgroundColor = .systemBackground
        host.addSubview(contentView)
        host.contentSize = contentView.bounds.size

        // 스텝5: 캔버스 frame을 contentView(6000)가 아니라 뷰포트 크기로 작게. 위쪽만 덮는다.
        let viewportH = UIScreen.main.bounds.height
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: w, height: viewportH))
        canvas.drawingPolicy = .pencilOnly   // 펜=그리기, 손가락=host 스크롤
        canvas.isScrollEnabled = false        // 강등: 스크롤은 host 담당
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        contentView.addSubview(canvas)

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

    // 델리게이트·핸들러 0개. 순수 구조만(host>contentView>canvas, 전부 정적).
    final class Coord: NSObject {
        var toolPicker: PKToolPicker?
    }
}
#endif
