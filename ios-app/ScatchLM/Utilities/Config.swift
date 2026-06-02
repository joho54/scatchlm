import Foundation

enum Config {
    // MARK: - Backend API
    /// 개발 시 사용할 호스트. UserDefaults `devApiHost`로 덮어쓸 수 있음 (예: 같은 Wi-Fi의 Mac IP).
    static var devApiHost: String {
        UserDefaults.standard.string(forKey: "devApiHost") ?? "127.0.0.1"
    }

    static var apiBaseURL: String {
        #if DEBUG
        return "http://\(devApiHost):18000/api"
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
            case .auto: return "자동"
            case .on: return "수식 보기"
            case .off: return "수식 안 보기"
            }
        }
    }

    static var mathRenderMode: MathRenderMode {
        get { MathRenderMode(rawValue: UserDefaults.standard.string(forKey: "mathRenderMode") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mathRenderMode") }
    }
}
