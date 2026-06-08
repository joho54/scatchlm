#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 하니스 (DEBUG 전용).
///
/// raw PencilKit(L0)에서 우리 캔버스 레이어를 한 겹씩 올리며(L1…L5) 캔버스를 크게 키워
/// **떨림이 처음 나타나는 레벨 = 범인**을 찾는다. 떨림은 "캔버스가 충분히 커지면 무조건"
/// 재현되므로(로그 추측보다 확실), 각 레벨에서 위→아래로 그려 내려가며 눈으로 판정한다.
///
/// 레벨은 상단 세그먼트로 런타임 전환(`.id(level)`로 캔버스 재구성) — 재빌드 불필요.
///
/// | L | 구성 | 격리하는 것 |
/// |---|---|---|
/// | 0 | raw `PKCanvasView`, 네이티브 스크롤, 큰 고정 contentSize | PencilKit 자체가 큰 캔버스에서 떠는가 |
/// | 1 | host>contentView>canvas, 정적(grow 없음, 크게 시작) | 우리 줌 계층 자체가 떠는가 |
/// | 2 | +펜 접촉 중 `setContentHeight` auto-grow(매 stroke) | mid-stroke reframe(유력 후보) |
/// | 3 | +indicator subview reframe(매 stroke) | 인디케이터 갱신 |
/// | 4 | +@State 재진입(매 stroke → updateUIView: centerContent/fit) | SwiftUI 재렌더 캐스케이드 |
/// | 5 | +hostDidLayout centerContent(layoutSubviews) | 레이아웃 재진입 |
struct DebugCanvasView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var level = 0
    @StateObject private var ticker = DebugStrokeTicker()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("닫기") { dismiss() }
                Spacer()
                Text("strokes \(ticker.strokeCount)").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 8)

            Text(Self.title(level))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 4)

            Picker("level", selection: $level) {
                ForEach(0..<6) { Text("L\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.bottom, 6)

            Divider()

            DebugCanvasRepresentable(level: level, ticker: ticker)
                .id(level)   // 레벨 바뀌면 캔버스 통째 재구성
        }
        .onChange(of: level) { ticker.strokeCount = 0 }
    }

    static func title(_ l: Int) -> String {
        switch l {
        case 0: return "L0 raw PKCanvasView (네이티브 스크롤, 큰 고정 contentSize)"
        case 1: return "L1 host>content>canvas — 정적, grow 없음(크게 시작)"
        case 2: return "L2 +펜 접촉 중 setContentHeight auto-grow (mid-stroke reframe)"
        case 3: return "L3 +indicator subview reframe / stroke"
        case 4: return "L4 +@State 재진입(updateUIView: center/fit) / stroke"
        default: return "L5 +hostDidLayout centerContent (layoutSubviews)"
        }
    }
}

/// L4 @State 재진입을 일으키기 위한 관찰 대상 — stroke마다 strokeCount를 올려 SwiftUI 재렌더 유발.
final class DebugStrokeTicker: ObservableObject {
    @Published var strokeCount: Int = 0
}

/// layoutSubviews 훅(L5) — 실제 HostScrollView와 동일하게 레이아웃 패스를 잡아 centerContent를 재진입.
private final class DebugHostScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

private struct DebugCanvasRepresentable: UIViewRepresentable {
    let level: Int
    @ObservedObject var ticker: DebugStrokeTicker

    func makeCoordinator() -> Coord { Coord(level: level, ticker: ticker) }

    func makeUIView(context: Context) -> UIView {
        let logical = Config.logicalCanvasWidth
        let coord = context.coordinator

        // L0 — raw PencilKit. PKCanvasView 자신이 스크롤 주체(네이티브). 큰 고정 contentSize.
        if level == 0 {
            let canvas = PKCanvasView()
            canvas.drawingPolicy = .anyInput
            canvas.alwaysBounceVertical = true
            canvas.backgroundColor = .white
            canvas.contentSize = CGSize(width: logical, height: 6000)
            coord.canvas = canvas
            coord.attachToolPicker(canvas)
            return canvas
        }

        // L1+ — host > contentView(viewForZooming) > canvas(그리기 전용)
        let host = DebugHostScrollView()
        host.delegate = coord
        host.alwaysBounceVertical = true
        host.contentInsetAdjustmentBehavior = .never
        host.minimumZoomScale = 1
        host.maximumZoomScale = 3
        host.backgroundColor = UIColor.systemGray5
        // L1은 정적(grow 없음)이라 처음부터 크게. L2+는 실제처럼 짧게 시작해 grow가 키운다.
        let initialH: CGFloat = level >= 2 ? logical * 2 : 6000
        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: logical, height: initialH))
        contentView.backgroundColor = .white
        host.addSubview(contentView)
        host.contentSize = contentView.bounds.size

        let canvas = PKCanvasView(frame: contentView.bounds)
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = coord
        contentView.addSubview(canvas)

        coord.host = host
        coord.contentView = contentView
        coord.canvas = canvas
        coord.attachToolPicker(canvas)

        // L5 — 레이아웃 패스마다 centerContent 재진입(실제 hostDidLayout 흉내)
        if level >= 5 {
            host.onLayout = { [weak coord] in coord?.centerContent() }
        }
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // L4 — ticker.strokeCount 변경이 부모 재렌더 → 여기 재진입. 실제 updateUIView가 매 stroke
        // 도는 부작용(applyPanelLayout→fitAndCenter→centerContent + ensureMinimum)을 흉내낸다.
        guard level >= 4 else { return }
        context.coordinator.onUpdateUIView()
    }

    // MARK: - Coordinator

    final class Coord: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        let level: Int
        let ticker: DebugStrokeTicker
        weak var host: UIScrollView?
        weak var contentView: UIView?
        weak var canvas: PKCanvasView?
        private var toolPicker: PKToolPicker?

        init(level: Int, ticker: DebugStrokeTicker) {
            self.level = level
            self.ticker = ticker
        }

        func attachToolPicker(_ canvas: PKCanvasView) {
            let tp = PKToolPicker()
            tp.setVisible(true, forFirstResponder: canvas)
            tp.addObserver(canvas)
            canvas.becomeFirstResponder()
            toolPicker = tp
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // L0/L1 — per-stroke 부작용 전혀 없음(정적). PencilKit/host만 관찰.
            guard level >= 2 else {
                bumpTicker(canvasView)
                return
            }

            // L2 — 실제 setContentHeight와 동일: 펜 접촉 중에도 매 콜백 contentView/canvas/contentSize
            // 를 키운다(= mid-stroke reframe, 유력 후보).
            let viewport = host.map { $0.bounds.height / max($0.zoomScale, 0.01) } ?? 0
            let drawingBottom = canvasView.drawing.strokes.isEmpty
                ? 0
                : canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }
            ensureContentHeight(drawingBottom + viewport * 2)

            // L3 — indicator subview를 매 stroke reframe(실제 updateNextPositionIndicator 흉내).
            if level >= 3 { updateIndicator(bottom: drawingBottom) }

            bumpTicker(canvasView)   // L4용 @State 재진입 트리거
        }

        private func bumpTicker(_ canvasView: PKCanvasView) {
            let n = canvasView.drawing.strokes.count
            DispatchQueue.main.async { [weak self] in self?.ticker.strokeCount = n }
        }

        // MARK: 실제 NoteView 로직 포팅

        func ensureContentHeight(_ h: CGFloat) {
            guard let contentView else { return }
            if contentView.bounds.height < h { setContentHeight(h) }
        }

        func setContentHeight(_ h: CGFloat) {
            guard let host, let contentView else { return }
            let s = host.zoomScale
            let w = contentView.bounds.width
            let origin = contentView.frame.origin
            contentView.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            contentView.center = CGPoint(x: origin.x + (w * s) / 2, y: origin.y + (h * s) / 2)
            canvas?.frame = contentView.bounds
            host.contentSize = CGSize(width: w * s, height: h * s)
        }

        func centerContent() {
            guard let host, let contentView else { return }
            let scaledW = contentView.bounds.width * host.zoomScale
            let insetX = max(0, (host.bounds.width - scaledW) / 2)
            let newInset = UIEdgeInsets(top: 0, left: insetX, bottom: 0, right: insetX)
            if host.contentInset != newInset { host.contentInset = newInset }
        }

        private weak var indicator: UIView?
        private func updateIndicator(bottom: CGFloat) {
            guard let contentView else { return }
            let ind: UIView
            if let existing = indicator {
                ind = existing
            } else {
                let v = UIView()
                v.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
                v.isUserInteractionEnabled = false
                contentView.addSubview(v)
                indicator = v
                ind = v
            }
            ind.frame = CGRect(x: 16, y: bottom + 24, width: contentView.bounds.width - 32, height: 2)
            contentView.bringSubviewToFront(ind)
        }

        func onUpdateUIView() {
            // L4 — 실제 updateUIView가 매 stroke 도는 부작용: fit 재계산 + 중앙정렬 + 최소높이.
            guard let host else { return }
            let logical = Config.logicalCanvasWidth
            let fit = min(1, host.bounds.width / logical)
            host.minimumZoomScale = fit
            centerContent()
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }
    }
}
#endif
