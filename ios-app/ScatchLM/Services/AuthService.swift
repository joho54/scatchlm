import Foundation
import Supabase

@Observable
final class AuthService {
    static let shared = AuthService()

    var session: Session?
    var isLoading = true

    private let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: Config.supabaseURL)!,
            supabaseKey: Config.supabaseAnonKey
        )
    }

    var isAuthenticated: Bool { session != nil }
    var userId: String? { session?.user.id.uuidString }
    var accessToken: String? { session?.accessToken }

    /// 로컬 DB sync 스코프용 canonical user_id (소문자 UUID, JWT sub와 일치).
    /// Supabase `UUID.uuidString`은 대문자라 서버 측 lowercase sub와 어긋나므로 소문자화한다.
    var syncUserId: String? { session?.user.id.uuidString.lowercased() }

    /// 세션 변화 시 DatabaseService에 현재 user_id를 주입하고 sync를 구동한다 (§4.5 / D-1).
    /// - 로그인/세션 복원(이전과 다른 uid): currentUserId 주입 → 레거시 claim + 최초 sync(onLogin).
    /// - 로그아웃: sync 중단·커서 클리어(onLogout) 후 스코프 해제. 로컬 데이터는 보존(§4.5).
    private func applyDBUserScope() {
        let previous = DatabaseService.shared.currentUserId
        let next = syncUserId
        DatabaseService.shared.currentUserId = next
        if let next {
            if previous != next {
                SyncService.shared.onLogin(userId: next)
            }
        } else if let previous {
            SyncService.shared.onLogout(userId: previous)
        }
    }

    func initialize() async {
        do {
            session = try await client.auth.session
        } catch {
            session = nil
        }
        applyDBUserScope()
        isLoading = false

        // Listen for auth state changes
        Task {
            for await (event, session) in client.auth.authStateChanges {
                await MainActor.run {
                    self.session = session
                    self.applyDBUserScope()
                }
            }
        }
    }

    func signUp(email: String, password: String) async throws {
        try await client.auth.signUp(email: email, password: password)
    }

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    /// Google OAuth 로그인. supabase-swift가 ASWebAuthenticationSession을 앱 내부 시트로 띄우고
    /// redirectTo의 scheme으로 콜백을 가로챈다. authStateChanges 리스너가 새 세션을 반영함.
    func signInWithGoogle() async throws {
        try await client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: URL(string: "com.joho54.scatchlm://login-callback"),
            // prompt=select_account: Google이 캐시된 계정으로 바로 통과시키지 않고
            // 항상 계정 선택창을 띄우게 강제 (다른 계정/가입 테스트 가능)
            queryParams: [(name: "prompt", value: "select_account")]
        )
    }

    func signOut() async throws {
        try await client.auth.signOut()
        session = nil
        // 로컬 데이터는 보존하되(다음 로그인 시 user_id 필터로 자동 격리, §4.5),
        // 현재 스코프는 즉시 해제해 미로그인 상태에서 타 유저 데이터가 노출되지 않게 한다.
        applyDBUserScope()
    }
}
