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

    func initialize() async {
        do {
            session = try await client.auth.session
        } catch {
            session = nil
        }
        isLoading = false

        // Listen for auth state changes
        Task {
            for await (event, session) in client.auth.authStateChanges {
                await MainActor.run {
                    self.session = session
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
            redirectTo: URL(string: "com.joho54.scatchlm://login-callback")
        )
    }

    func signOut() async throws {
        try await client.auth.signOut()
        session = nil
    }
}
