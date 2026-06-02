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
