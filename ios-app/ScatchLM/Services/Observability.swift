import Foundation
import Sentry

/// Sentry(크래시·에러 리포팅) 통합 진입점 (Track B-2·B-3).
///
/// 설계:
/// - `start()`는 앱 init에서 1회 호출. `Config.sentryDSN`이 비어 있으면 SDK 미시작(완전 no-op).
/// - PII(손글씨·교재·채팅·이메일·토큰)는 `beforeSend`에서 스크럽(spec §3.3·§7).
/// - `tracePropagationTargets`를 우리 백엔드 호스트로 한정 → 외부(Anthropic 등) 누출 방지(spec §3.1).
/// - DSN이 없을 때도 모든 호출이 안전한 no-op이 되도록 SDK API만 사용.
enum Observability {
    /// SentrySDK 시작. DSN 빈 값이면 미시작.
    static func start() {
        let dsn = Config.sentryDSN
        guard !dsn.isEmpty else {
            #if DEBUG
            print("[sentry] disabled (empty DSN)")
            #endif
            return
        }

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"

        SentrySDK.start { options in
            options.dsn = dsn
            options.enableCrashHandler = true       // 시그널/메모리 크래시
            options.enableAppHangTracking = true    // ANR
            options.sendDefaultPii = false
            // 성능 트레이싱은 낮게 — error 이벤트 trace_id 전파는 sample rate와 무관(spec §3.1).
            options.tracesSampleRate = 0.05

            #if DEBUG
            options.environment = "dev"
            #else
            options.environment = "prod"
            #endif

            // release 포맷 동결(spec §3.2): <package>@<version>+<build>
            options.releaseName = "\(Config.bundleID)@\(version)+\(build)"
            options.dist = build

            // 우리 백엔드 요청에만 sentry-trace/baggage 주입(spec §3.1).
            options.tracePropagationTargets = Config.tracePropagationHosts

            options.beforeSend = { event in scrub(event) }
        }
        #if DEBUG
        print("[sentry] started env=dev release=\(Config.bundleID)@\(version)+\(build)")
        #endif
    }

    /// 현재 트레이스 ID(32-hex). 없으면 빈 문자열 — FE 로그에 동봉(spec §4.3).
    static func currentTraceId() -> String {
        SentrySDK.span?.traceId.sentryIdString ?? ""
    }

    /// 영향 유저 식별자만 설정(이메일·이름 금지, spec §3.2). nil이면 클리어.
    static func setUser(_ id: String?) {
        guard let id, !id.isEmpty else {
            SentrySDK.setUser(nil)
            return
        }
        let user = User()
        user.userId = id
        SentrySDK.setUser(user)
    }

    /// 서버 5xx를 에러 이벤트로 캡처(요청 자체의 trace_id는 SDK가 자동 부착, spec §B-3).
    /// 취소·오프라인 등 정상 흐름은 호출부에서 제외.
    static func captureServerError(status: Int, method: String, path: String, requestId: String?) {
        SentrySDK.capture(error: ObservedError.serverError(status: status, path: path)) { scope in
            scope.setTag(value: "\(status)", key: "http.status")
            scope.setTag(value: "\(method) \(path)", key: "http.endpoint")
            if let requestId { scope.setTag(value: requestId, key: "request_id") }
        }
    }

    /// 이벤트 PII 스크럽(spec §3.3). request body/쿠키 제거 + 민감 헤더 마스킹.
    private static func scrub(_ event: Event) -> Event? {
        if let request = event.request {
            // SentryRequest엔 body 필드 자체가 없음(bodySize/headers/cookies/url만) → 본문 누출 경로 없음.
            request.cookies = nil
            if var headers = request.headers {
                for key in headers.keys where Self.sensitiveHeaders.contains(key.lowercased()) {
                    headers[key] = "[scrubbed]"
                }
                request.headers = headers
            }
        }
        return event
    }

    private static let sensitiveHeaders: Set<String> = ["authorization", "cookie", "set-cookie"]
}

/// Sentry 캡처용 경량 에러 타입.
enum ObservedError: Error {
    case serverError(status: Int, path: String)
}
