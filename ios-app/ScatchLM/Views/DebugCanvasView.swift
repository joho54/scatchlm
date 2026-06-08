#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 — **스텝 4: host 구조 + 확장 0회(완전 정적).**
///
/// 스텝1(raw 네이티브 + contentSize 확장) = 떨림 없음.
/// 스텝2(host>content>canvas + frame 확장) = 떨림.
/// 스텝3(스텝2 + defer, 펜 접촉 중 확장 보류) = **여전히 떨림(똑같음).**
/// → 펜 접촉 중 지오메트리 변경이 없는데도 떨린다 = 범인은 확장 타이밍이 아니라 **구조 자체.**
///
/// 스텝4: 확장을 통째로 제거. host>contentView>canvas를 처음부터 6000으로 고정, setContentHeight 0회.
/// 깊이 내려가 그려도 떨리는지 본다. 가설: PencilKit가 강등(isScrollEnabled=false)된 큰 캔버스에서
/// 그릴 때 host를 자동 스크롤 → 깊은 위치에서 떨림(확장 무관).
///
/// 판정:
/// - **떨림** → demote+host 구조 자체가 범인 확정. 해법은 스텝1식 네이티브 스크롤 복귀(아키텍처).
/// - **안 떨림** → 구조는 무죄, 확장(펜업 flush 포함)이 트리거 → 다시 좁힌다.
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

        let canvas = PKCanvasView(frame: contentView.bounds)
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
