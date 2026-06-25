import SwiftUI

/// DMN 휴식을 마치고 페이지로 돌아오는 순간의 복귀 연출 스타일.
/// 가치는 휴식 중이 아니라 *복귀의 화질*에서 온다 — 그 한순간을 여러 느낌으로 설계해 비교한다.
///
/// 전부 라이브 페이지에 직접 거는 SwiftUI 네이티브 효과(blur/scale/brightness/saturation)다.
/// (스냅샷+Metal 굴절은 레터박스·오버레이 경계가 생겨 폐기 — 라이브 직접 적용이 가장 매끄럽다.)
enum ReturnFloodStyle: String, CaseIterable, Identifiable {
    case blur  = "흐림"        // 뿌연 시야가 맑아짐
    case zoom  = "줌인"        // 살짝 확대된 상이 제자리로 내려앉음 — "들어맞는" 느낌
    case bloom = "빛 번짐"     // 밝게 떴다가 정상 노출로 — 빛이 쏟아져 들어옴
    case color = "색 차오름"   // 탈색됐다가 색이 살아남 — 생기가 돌아옴
    var id: String { rawValue }
}

/// `progress` 1(변형 최대) → 0(맑음)을 애니메이트하며 페이지 전체에 연출을 입힌다.
/// Animatable이라 progress가 프레임마다 갱신 → 효과가 매끄럽게 풀린다.
/// progress가 0이면 어떤 효과도 걸지 않는다(상시 필터/성능 비용 회피).
struct ReturnFlood: ViewModifier, Animatable {
    var progress: CGFloat
    var style: ReturnFloodStyle

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // guard로 효과 트리를 껐다 켜면(구조 변화) 끝나는 순간 safe-area가 재계산돼 상단이 툭 내려온다.
        // 효과를 항상 적용하고 p=0이면 전부 identity(blur 0·scale 1·opacity 1…)라 비용 0 + 구조 불변.
        let p = max(0, min(1, progress))

        switch style {
        case .blur:
            return AnyView(content
                .blur(radius: p * 24)
                .opacity(1 - 0.55 * p))
        case .zoom:
            return AnyView(content
                .scaleEffect(1 + 0.09 * p, anchor: .center)
                .blur(radius: p * 6)
                .opacity(1 - 0.35 * p))
        case .bloom:
            return AnyView(content
                .brightness(0.3 * p)
                .blur(radius: p * 9))
        case .color:
            return AnyView(content
                .saturation(1 - 0.85 * p)
                .brightness(0.08 * p)
                .blur(radius: p * 5))
        }
    }
}

extension View {
    func returnFlood(progress: CGFloat, style: ReturnFloodStyle) -> some View {
        modifier(ReturnFlood(progress: progress, style: style))
    }
}

#if DEBUG
extension View {
    /// 디버그 칩 라벨 룩.
    func debugChip() -> some View {
        self
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
    }

    /// 디버그 칩 버튼 룩(.plain으로 틴트 제거 후 칩 룩).
    func debugChipButton() -> some View {
        self.buttonStyle(.plain).debugChip()
    }
}
#endif
