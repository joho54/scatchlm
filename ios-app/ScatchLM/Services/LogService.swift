import Foundation
import UIKit

/// 신뢰성 있는 FE 로그 전송 (O6/O9).
///
/// 설계:
/// - 단일 serial queue로 enqueue·flush·재시도를 직렬화(락 불필요, 경쟁 없음).
/// - 전송 **성공 후** dequeue. 실패 시 버퍼 유지 + 지수 backoff 재시도.
/// - 디스크 버퍼(앱 재시작/크래시에도 유실 최소화) + background/terminate flush.
/// - context(OS·앱버전·빌드·디바이스·로케일·session_id) 동봉, Authorization 헤더 첨부.
/// - 릴리스에서는 console print 억제 + 미인증 시 전송 보류(샘플링 여지).
final class LogService {
    static let shared = LogService()

    private struct Entry: Codable {
        let level: String
        let tag: String
        let message: String
        let data: [String: String]
        let ts: String
        var requestId: String?
    }

    private let queue = DispatchQueue(label: "com.joho54.scatchlm.logservice")
    private var buffer: [Entry] = []
    private let maxBuffer = 500          // 디스크 폭주 방지 상한
    private let flushThreshold = 50
    private let baseURL = Config.apiBaseURL

    private var flushTimer: Timer?
    private var sending = false
    private var backoffStep = 0
    private let maxBackoffStep = 6       // 2^6 = 64s 상한

    private let sessionId = UUID().uuidString
    private lazy var bufferURL: URL = {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("logbuffer.json")
    }()

    private init() {
        loadFromDisk()
        startFlushTimer()
        registerLifecycle()
    }

    // MARK: - Public API (동기 fire-and-forget)

    func info(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
        enqueue(level: "info", tag: tag, message: message, data: data)
    }

    func warn(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
        enqueue(level: "warn", tag: tag, message: message, data: data)
    }

    func error(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
        enqueue(level: "error", tag: tag, message: message, data: data)
    }

    private func enqueue(level: String, tag: String, message: String, data: [String: Any]?) {
        let entry = Entry(
            level: level,
            tag: tag,
            message: message,
            data: Self.sanitize(data),
            ts: ISO8601DateFormatter().string(from: Date()),
            requestId: nil
        )
        #if DEBUG
        if let data, !data.isEmpty {
            print("[\(tag)] \(message) \(data)")
        } else {
            print("[\(tag)] \(message)")
        }
        #endif
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(entry)
            if self.buffer.count > self.maxBuffer {
                self.buffer.removeFirst(self.buffer.count - self.maxBuffer)
            }
            self.persistToDisk()
            if self.buffer.count >= self.flushThreshold {
                self.flushLocked()
            }
        }
    }

    /// 직렬화 불가 값을 안전하게 문자열화 (sanitize).
    private static func sanitize(_ data: [String: Any]?) -> [String: String] {
        guard let data else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in data {
            switch v {
            case let s as String: out[k] = s
            case let n as NSNumber: out[k] = n.stringValue
            default: out[k] = String(describing: v)
            }
        }
        return out
    }

    // MARK: - Flush

    func flush() {
        queue.async { [weak self] in self?.flushLocked() }
    }

    /// background/terminate 시 best-effort 전송. **메인스레드를 블로킹하지 않는다.**
    /// 매 enqueue마다 persistToDisk()가 돌므로 durability는 디스크 버퍼가 보장한다
    /// (네트워크 전송 실패/미완료여도 다음 실행의 loadFromDisk로 복구). 따라서 세마포어로
    /// 메인을 멈출 필요가 없고, beginBackgroundTask로 잠깐의 추가 실행시간만 확보한다.
    func flushOnLifecycle() {
        let app = UIApplication.shared
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        let endTask = {
            if bgTask != .invalid { app.endBackgroundTask(bgTask); bgTask = .invalid }
        }
        bgTask = app.beginBackgroundTask(withName: "logservice.flush", expirationHandler: endTask)
        queue.async { [weak self] in
            guard let self else { endTask(); return }
            self.flushLocked { endTask() }
        }
    }

    /// queue 위에서만 호출. 전송 성공 후에만 dequeue.
    private func flushLocked(completion: (() -> Void)? = nil) {
        guard !sending, !buffer.isEmpty else { completion?(); return }

        // 미인증이어도 전송한다. 엔드포인트는 인증을 요구하지 않으며(익명 허용),
        // 로그인 실패/온보딩 구간 로그는 정의상 토큰이 없는 상태에서 발생하므로
        // 여기서 보류하면 그 텔레메트리가 영영 도착하지 않는다. 토큰은 있으면 첨부.
        let token = AuthService.shared.accessToken

        sending = true
        let batch = Array(buffer.prefix(flushThreshold * 2))
        let payload = buildPayload(batch)

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            sending = false
            completion?()
            return
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/dev/log/batch")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body   // 누락 시 빈 본문 전송 → 서버 422(body-level). FE 로깅 전면 무력화의 실제 원인.
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { completion?(); return }
            self.queue.async {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ok = error == nil && (200..<300).contains(code)
                if ok {
                    // 성공: 전송한 만큼만 제거(전송 중 추가분 보존).
                    let n = min(batch.count, self.buffer.count)
                    self.buffer.removeFirst(n)
                    self.backoffStep = 0
                    self.persistToDisk()
                } else {
                    // 실패: 버퍼 유지 + backoff 재시도 예약.
                    self.scheduleRetry()
                }
                self.sending = false
                completion?()
            }
        }.resume()
    }

    private func buildPayload(_ batch: [Entry]) -> [String: Any] {
        let logs: [[String: Any]] = batch.map { e in
            var d: [String: Any] = [
                "level": e.level, "tag": e.tag, "message": e.message,
                "data": e.data, "ts": e.ts,
            ]
            if let rid = e.requestId { d["request_id"] = rid }
            return d
        }
        return ["logs": logs, "context": context()]
    }

    private func context() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        var ctx: [String: Any] = [
            "user_id": AuthService.shared.syncUserId ?? "",
            "app_version": (info?["CFBundleShortVersionString"] as? String) ?? "",
            "build": (info?["CFBundleVersion"] as? String) ?? "",
            "os_version": UIDevice.current.systemVersion,
            "device_model": Self.deviceModel(),
            "locale": Locale.current.identifier,
            "session_id": sessionId,
        ]
        // FE 로그↔Sentry 트레이스 상관 — 현재 trace_id 동봉(spec §4.3). 없으면 생략.
        let traceId = Observability.currentTraceId()
        if !traceId.isEmpty { ctx["trace_id"] = traceId }
        return ctx
    }

    private static func deviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let id = mirror.children.compactMap { ($0.value as? Int8).map { Character(UnicodeScalar(UInt8($0))) } }
            .filter { $0 != "\0" }
        return String(id)
    }

    private func scheduleRetry() {
        let delay = pow(2.0, Double(min(backoffStep, maxBackoffStep)))
        backoffStep += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushLocked()
        }
    }

    // MARK: - Disk buffer

    private func persistToDisk() {
        guard let data = try? JSONEncoder().encode(buffer) else { return }
        try? data.write(to: bufferURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: bufferURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        buffer = entries
    }

    // MARK: - Timer / lifecycle

    private func startFlushTimer() {
        DispatchQueue.main.async {
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    private func registerLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flushOnLifecycle()
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flushOnLifecycle()
        }
    }
}

// 편의 함수
func appLog(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
    LogService.shared.info(tag, message, data)
}

func appLogWarn(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
    LogService.shared.warn(tag, message, data)
}

func appLogError(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
    LogService.shared.error(tag, message, data)
}
