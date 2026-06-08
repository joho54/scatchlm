#if DEBUG
import SwiftUI
import PencilKit

/// 떨림 소거법 — **baseline(빈 캔버스)**.
///
/// 아무 컴포넌트 합성도 없는 raw `PKCanvasView` 하나. 우리 host 계층·auto-grow·indicator·
/// 피드백 카드·@State 재렌더 전부 없음. 화면을 감싸는 SwiftUI 상태도 없다(이 View엔 @State 0개 —
/// stroke마다 재렌더되는 경로 자체가 없음). 닫기 버튼은 캔버스와 분리된 오버레이.
///
/// 여기서 캔버스를 크게 키우며(위→아래로 그려 내려가며) 떨림이 나는지 본다.
/// - **안 떨림** → 떨림은 우리가 얹은 레이어 중 하나. 다음 단계에서 한 겹씩 추가.
/// - **떨림** → PencilKit 자체(혹은 큰 contentSize) 문제 → 문제 재정의.
struct DebugCanvasView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RawCanvas()
                .ignoresSafeArea()
            Button("닫기") { dismiss() }
                .padding(10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .padding(.trailing, 16)
        }
    }
}

/// raw PKCanvasView 하나. 네이티브 스크롤, 큰 고정 contentSize. 델리게이트·핸들러 없음.
private struct RawCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.alwaysBounceVertical = true
        canvas.backgroundColor = .systemBackground
        canvas.contentSize = CGSize(width: UIScreen.main.bounds.width, height: 6000)

        let tp = PKToolPicker()
        tp.setVisible(true, forFirstResponder: canvas)
        tp.addObserver(canvas)
        canvas.becomeFirstResponder()
        context.coordinator.toolPicker = tp
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var toolPicker: PKToolPicker? }
}
#endif
