import UIKit

/// 디바이스 idiom 분기 헬퍼 (iphone-companion-app-spec §4.1·B-1).
///
/// ScatchLM은 Universal 단일 타겟(iPhone+iPad)이다. iPhone은 **읽기 전용 컴패니언**으로,
/// 편집 진입점(필기·신규 피드백·업로드)을 노출하지 않는다. 이 분기의 SSOT를 한 곳에 둔다.
///
/// 뷰 내부의 세부 레이아웃 분기는 `@Environment(\.horizontalSizeClass)`(compact/regular)를
/// 보조로 쓰되, "iPhone이냐"라는 제품 결정은 항상 `Platform.isPhone`을 기준으로 한다 —
/// iPad 멀티태스킹 Slide Over에서도 sizeClass는 compact가 될 수 있어 idiom이 더 안정적이다.
enum Platform {
    /// 현재 기기가 iPhone인지. iPad/Mac Catalyst는 false.
    static var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
}
