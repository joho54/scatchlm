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

    /// 네트워크 호출용 유효 access token. 캐시 프로퍼티 `accessToken`(session?.accessToken)은
    /// JWT가 만료돼도 그대로 반환돼 서버 401("Token expired")을 유발한다(예: sync push). 반면
    /// supabase-swift의 `client.auth.session` getter는 만료 시 refresh token으로 자동 갱신한다.
    /// 네트워크 헤더는 이 경로를 써서 stale 토큰 첨부를 막는다. 갱신 실패(네트워크/refresh 만료)
    /// 시엔 캐시 토큰이라도 반환(미인증이면 nil) — 호출부가 401을 만나면 평소대로 처리.
    func validAccessToken() async -> String? {
        do {
            let refreshed = try await client.auth.session
            if refreshed.accessToken != session?.accessToken {
                await MainActor.run { self.session = refreshed }
            }
            return refreshed.accessToken
        } catch {
            return session?.accessToken
        }
    }

    /// 로컬 DB sync 스코프용 canonical user_id (소문자 UUID, JWT sub와 일치).
    /// Supabase `UUID.uuidString`은 대문자라 서버 측 lowercase sub와 어긋나므로 소문자화한다.
    var syncUserId: String? { session?.user.id.uuidString.lowercased() }

    /// 현재 인증 provider — FE 로그 텔레메트리용 (spec §3.2-a). "apple"|"google"|"email" 등.
    /// 출처: `app_metadata.provider`(Supabase가 채움) 우선, 없으면 가장 최근 identity의 provider.
    /// 미인증 시 nil → LogService가 [prov:] 토큰을 생략한다(단일 프로퍼티, 호출부 무수정).
    var authProvider: String? {
        guard let user = session?.user else { return nil }
        if let provider = user.appMetadata["provider"]?.value as? String { return provider }
        return user.identities?.last?.provider
    }

    /// 세션 변화 시 DatabaseService에 현재 user_id를 주입하고 sync를 구동한다 (§4.5 / D-1).
    /// - 로그인/세션 복원(이전과 다른 uid): currentUserId 주입 → 레거시 claim + 최초 sync(onLogin).
    /// - 로그아웃: sync 중단·커서 클리어(onLogout) 후 스코프 해제. 로컬 데이터는 보존(§4.5).
    private func applyDBUserScope() {
        let previous = DatabaseService.shared.currentUserId
        let next = syncUserId
        DatabaseService.shared.currentUserId = next
        // Sentry 영향 유저 범위 — 식별자만(이메일·이름 금지, spec §3.2). 로그아웃 시 클리어.
        Observability.setUser(next)
        if let next {
            if previous != next {
                SyncService.shared.onLogin(userId: next)
            }
        } else if let previous {
            SyncService.shared.onLogout(userId: previous)
        }
    }

    /// "앱 삭제 = 로그아웃" 보장용 플래그. UserDefaults는 앱 삭제 시 지워지지만
    /// Keychain의 Supabase 세션은 살아남으므로, 첫 실행이면 잔존 세션을 로컬 purge한다.
    private static let freshInstallKey = "auth.didInstall"

    func initialize() async {
        // 첫 실행(플래그 부재) → 재설치/신규설치. Keychain에 남은 세션을 로컬에서만 제거(서버 호출 없음).
        if !UserDefaults.standard.bool(forKey: Self.freshInstallKey) {
            try? await client.auth.signOut(scope: .local)
            UserDefaults.standard.set(true, forKey: Self.freshInstallKey)
            appLog("auth", "fresh install: purged residual keychain session")
        }
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
        try await uxTrack("auth.email.signup") {
            try await client.auth.signUp(email: email, password: password)
        }
    }

    func signIn(email: String, password: String) async throws {
        try await uxTrack("auth.email.signin") {
            try await client.auth.signIn(email: email, password: password)
        }
    }

    // MARK: - 비밀번호 재설정 (OTP, 인앱)

    /// 1단계: 재설정 OTP(6자리) 이메일 발송. Supabase "Reset Password" 템플릿에 {{ .Token }} 노출 필요.
    /// 이메일 존재 여부를 노출하지 않도록 Supabase는 성공/실패와 무관하게 동일 응답을 준다(열거 방지).
    func requestPasswordReset(email: String) async throws {
        try await uxTrack("auth.password.reset") {
            try await client.auth.resetPasswordForEmail(email)
        }
    }

    /// 2단계: OTP 검증(복구 세션 확립) → 새 비밀번호로 갱신. 성공 시 로그인 상태가 된다.
    func completePasswordReset(email: String, token: String, newPassword: String) async throws {
        try await uxTrack("auth.password.verify") {
            try await client.auth.verifyOTP(email: email, token: token, type: .recovery)
            try await client.auth.update(user: UserAttributes(password: newPassword))
        }
    }

    /// Google OAuth 로그인. supabase-swift가 ASWebAuthenticationSession을 앱 내부 시트로 띄우고
    /// redirectTo의 scheme으로 콜백을 가로챈다. authStateChanges 리스너가 새 세션을 반영함.
    func signInWithGoogle() async throws {
        try await uxTrack("auth.google") {
            try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: URL(string: "com.joho54.scatchlm://login-callback"),
                // prompt=select_account: Google이 캐시된 계정으로 바로 통과시키지 않고
                // 항상 계정 선택창을 띄우게 강제 (다른 계정/가입 테스트 가능)
                queryParams: [(name: "prompt", value: "select_account")]
            )
        }
    }

    /// 검증된 JWT의 app_metadata.tier (없으면 "normal"). IAP 구매 후 refreshSession으로 갱신됨.
    var tier: String {
        guard let md = session?.user.appMetadata,
              let value = md["tier"]?.value as? String,
              value == "pro" || value == "normal" else {
            return "normal"
        }
        return value
    }

    /// 강제 세션 갱신 → 새 access token(갱신된 app_metadata.tier 반영) 수령 (§4.2 / B-2).
    /// IAP `/verify` 성공 직후 호출해 tier=pro JWT를 즉시 받는다(eventually-consistent flip 단축).
    @discardableResult
    func refreshSession() async throws -> Session {
        appLog("auth", "refreshSession start")
        let refreshed = try await client.auth.refreshSession()
        await MainActor.run {
            self.session = refreshed
            self.applyDBUserScope()
        }
        appLog("auth", "refreshSession done", ["tier": tier])
        return refreshed
    }

    func signOut() async throws {
        try await uxTrack("auth.signout") {
            try await client.auth.signOut()
            session = nil
            // 로컬 데이터는 보존하되(다음 로그인 시 user_id 필터로 자동 격리, §4.5),
            // 현재 스코프는 즉시 해제해 미로그인 상태에서 타 유저 데이터가 노출되지 않게 한다.
            applyDBUserScope()
        }
    }

    // MARK: - Sign in with Apple (D-2, Guideline 4.8 대응)

    private var appleCoordinator: AppleSignInCoordinator?

    /// 네이티브 Sign in with Apple → Supabase signInWithIdToken(.apple).
    /// nonce를 sha256으로 묶어 리플레이를 방지한다.
    func signInWithApple() async throws {
        try await uxTrack("auth.apple") {
            let rawNonce = Self.randomNonce()
            let hashedNonce = Self.sha256(rawNonce)

            let coordinator = AppleSignInCoordinator()
            appleCoordinator = coordinator
            defer { appleCoordinator = nil }

            let credential = try await coordinator.requestCredential(nonce: hashedNonce)
            guard let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                throw NSError(domain: "AppleSignIn", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple identity token missing"])
            }
            try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
            )
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
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "로그인이 필요해요.")])
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
