import Foundation
import UIKit
import Supabase
import AuthenticationServices
import CryptoKit

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
            appLog("auth", "session restore", ["restored": session != nil ? "true" : "false"])
        } catch {
            session = nil
            appLog("auth", "session restore: none")
        }
        applyDBUserScope()
        isLoading = false

        // Listen for auth state changes
        Task {
            for await (event, session) in client.auth.authStateChanges {
                appLog("auth", "authStateChange", ["event": "\(event)", "hasSession": session != nil ? "true" : "false"])
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
        appLog("auth", "google oauth start")
        try await client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: URL(string: "com.joho54.scatchlm://login-callback"),
            // prompt=select_account: Google이 캐시된 계정으로 바로 통과시키지 않고
            // 항상 계정 선택창을 띄우게 강제 (다른 계정/가입 테스트 가능)
            queryParams: [(name: "prompt", value: "select_account")]
        )
    }

    func signOut() async throws {
        appLog("auth", "signOut start")
        try await client.auth.signOut()
        session = nil
        // 로컬 데이터는 보존하되(다음 로그인 시 user_id 필터로 자동 격리, §4.5),
        // 현재 스코프는 즉시 해제해 미로그인 상태에서 타 유저 데이터가 노출되지 않게 한다.
        applyDBUserScope()
        appLog("auth", "signOut done")
    }

    // MARK: - Sign in with Apple (D-2, Guideline 4.8 대응)

    private var appleCoordinator: AppleSignInCoordinator?

    /// 네이티브 Sign in with Apple → Supabase signInWithIdToken(.apple).
    /// nonce를 sha256으로 묶어 리플레이를 방지한다.
    func signInWithApple() async throws {
        appLog("auth", "apple sign-in start")
        let rawNonce = Self.randomNonce()
        let hashedNonce = Self.sha256(rawNonce)

        let coordinator = AppleSignInCoordinator()
        appleCoordinator = coordinator
        defer { appleCoordinator = nil }

        do {
            let credential = try await coordinator.requestCredential(nonce: hashedNonce)
            guard let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                throw NSError(domain: "AppleSignIn", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple identity token missing"])
            }
            try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
            )
            appLog("auth", "apple sign-in success")
        } catch {
            appLogError("auth", "apple sign-in failed", ["error": "\(error)"])
            throw error
        }
    }

    // MARK: - 계정 삭제 (L1 / D-1)

    enum DeleteAccountResult { case fullyDeleted, dataDeletedAuthRemains }

    /// DELETE /api/account 호출 → 200/502면 로컬 purge + signOut. 401·기타는 throw.
    /// 502(데이터 삭제됨·auth 잔존)도 로컬 purge + 로그아웃까지 진행(데이터는 이미 삭제됨).
    @discardableResult
    func deleteAccount() async throws -> DeleteAccountResult {
        guard let uid = syncUserId else {
            throw NSError(domain: "AuthService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "로그인이 필요해요."])
        }
        appLog("auth", "account deletion start", ["user": uid])
        let (status, data) = try await APIClient.shared.deleteRaw("/account")

        guard status == 200 || status == 502 else {
            appLogError("auth", "account deletion server error", ["status": "\(status)"])
            throw APIError.serverError(status, String(data: data, encoding: .utf8) ?? "")
        }

        // 데이터는 서버에서 이미 삭제됨 → 로컬 하드 purge + 로그아웃.
        try? DatabaseService.shared.purgeAllData(userId: uid)
        try await signOut()
        appLog("auth", "account deletion done", ["status": "\(status)"])
        return status == 200 ? .fullyDeleted : .dataDeletedAuthRemains
    }

    // MARK: - Nonce helpers

    private static func randomNonce(length: Int = 32) -> String {
        let chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._"
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < chars.count {
                result.append(chars[chars.index(chars.startIndex, offsetBy: Int(random))])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}

/// 네이티브 Apple 로그인 콜백을 async/await으로 감싸는 코디네이터.
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func requestCredential(nonce: String) async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonce
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation?.resume(returning: credential)
        } else {
            continuation?.resume(throwing: NSError(
                domain: "AppleSignIn", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"]))
        }
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}
