import Foundation
import UIKit

enum Config {
    // MARK: - Canvas Layout (Option A: 고정 논리폭 + 레터박스)
    /// 펜 캔버스의 논리 페이지 폭(SSOT). orientation/divider 비율과 무관하게 고정되어,
    /// stroke·피드백 카드 좌표가 회전/분할 리사이즈에도 단일 좌표계에 머문다.
    /// 기기 세로폭(짧은 변)으로 고정 — 세로 모드는 오늘과 동일(여백/클리핑 없음), 가로 모드에서만
    /// 종이가 이 폭으로 가운데 정렬되고 양옆이 레터박스. (Option A는 ②strokes 절대좌표 제약상 이 폭보다
    /// 넓게 쓴 가로 필기는 잘리지만, 대부분의 필기가 일어나는 세로 폭을 보존하는 게 충격이 가장 작다.)
    /// 가용 폭이 이 값보다 좁아지는 극단 분할에선 canvasPanel이 가용 폭으로 자연 축소.
    static var logicalCanvasWidth: CGFloat {
        min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
    }

    // MARK: - Backend API
    /// 개발 시 사용할 호스트. UserDefaults `devApiHost`로 덮어쓸 수 있음 (예: 같은 Wi-Fi의 Mac IP).
    static var devApiHost: String {
        UserDefaults.standard.string(forKey: "devApiHost") ?? "127.0.0.1"
    }

    static var apiBaseURL: String {
        #if DEBUG
        // 기본은 운영 — 실기기 Debug 빌드에서도 그냥 닿고, #if DEBUG 디버그 로그(canvas 등)가
        // 운영 로그로 흐른다. 로컬 백엔드로 작업할 땐 UserDefaults `devApiHost`를 LAN IP로 세팅.
        if let host = UserDefaults.standard.string(forKey: "devApiHost") {
            return "http://\(host):18000/api"
        }
        return "https://scatchlm.duckdns.org/api"
        #else
        return "https://scatchlm.duckdns.org/api"
        #endif
    }

    // MARK: - Supabase
    static let supabaseURL = "https://iuuhjgnlxzakdrsuobuh.supabase.co"
    static let supabaseAnonKey = "sb_publishable_tpIT1v44gNDeooIndTnfeQ__cUr3EGo"

    // MARK: - App
    static let bundleID = "com.joho54.scatchlm"

    // MARK: - IAP (StoreKit 2 구독)
    /// Pro 월간 자동갱신 구독 product id (App Store Connect 등록값과 일치해야 함).
    static let proMonthlyProductID = "com.joho54.scatchlm.pro.monthly"

    /// v1은 무료 단독 출시 — 구독(IAP) UI를 숨긴다(작동 안 하는 결제 UI = 리젝 사유, ASC 상품 미등록).
    /// App Store Connect에 구독 상품 등록 후 true로 전환(fast-follow).
    static let subscriptionEnabled = true

    // MARK: - Sentry (에러/크래시 리포팅, O7)
    /// DSN 우선순위: UserDefaults `sentryDSN`(dev 임시) → Info.plist `SENTRY_DSN`(빌드설정 주입) → 빈 값.
    /// 빈 값이면 SentrySDK.start를 호출하지 않아 SDK 완전 비활성(spec §4.2·B-2). DSN은 커밋 금지.
    static var sentryDSN: String {
        if let dev = UserDefaults.standard.string(forKey: "sentryDSN"), !dev.isEmpty {
            return dev
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String {
            return plist.trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// 백엔드 트레이스 전파 대상 호스트(spec §3.1). 외부(Anthropic 등)엔 헤더 미주입.
    static var tracePropagationHosts: [String] {
        ["scatchlm.duckdns.org", devApiHost]
    }

    // MARK: - 약관/정책 (G-1 호스팅, Caddy 정적)
    static let privacyPolicyURL = "https://scatchlm.duckdns.org/privacy"
    static let termsOfServiceURL = "https://scatchlm.duckdns.org/terms"

    // MARK: - User Preferences
    static var responseLanguage: String {
        get { UserDefaults.standard.string(forKey: "responseLanguage") ?? "Korean" }
        set { UserDefaults.standard.set(newValue, forKey: "responseLanguage") }
    }

    /// 수식(LaTeX) 렌더링 모드.
    /// - auto(자동): 콘텐츠에 수식이 감지되면 KaTeX(HTML), 아니면 네이티브 마크다운
    /// - on(수식 보기): 항상 KaTeX
    /// - off(수식 안 보기): 항상 네이티브 (수식 미렌더)
    enum MathRenderMode: String, CaseIterable {
        case auto, on, off

        var label: String {
            switch self {
            case .auto: return String(localized: "자동")
            case .on: return String(localized: "수식 보기")
            case .off: return String(localized: "수식 안 보기")
            }
        }
    }

    static var mathRenderMode: MathRenderMode {
        get { MathRenderMode(rawValue: UserDefaults.standard.string(forKey: "mathRenderMode") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mathRenderMode") }
    }
}
