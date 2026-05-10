import Foundation

enum Config {
    // MARK: - Backend API
    static var apiHost: String {
        // 개발 시 맥의 IP를 자동 감지하거나 하드코딩
        // 프로덕션에서는 서버 URL로 교체
        #if DEBUG
        return "192.168.0.62"
        #else
        return "api.scatchlm.com"
        #endif
    }

    static var apiBaseURL: String {
        "http://\(apiHost):8000/api"
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
}
