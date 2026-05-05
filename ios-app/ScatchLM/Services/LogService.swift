import Foundation

final class LogService {
    static let shared = LogService()

    private var queue: [[String: Any]] = []
    private let maxQueue = 50
    private var flushTimer: Timer?
    private let baseURL = Config.apiBaseURL

    private init() {
        startFlushTimer()
    }

    private func startFlushTimer() {
        DispatchQueue.main.async {
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func info(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
        enqueue(level: "info", tag: tag, message: message, data: data)
    }

    func error(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
        enqueue(level: "error", tag: tag, message: message, data: data)
    }

    private func enqueue(level: String, tag: String, message: String, data: [String: Any]?) {
        let entry: [String: Any] = [
            "level": level,
            "tag": tag,
            "message": message,
            "data": data ?? [:],
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        queue.append(entry)

        // 콘솔에도 출력
        if let data, !data.isEmpty {
            print("[\(tag)] \(message) \(data)")
        } else {
            print("[\(tag)] \(message)")
        }

        if queue.count >= maxQueue {
            flush()
        }
    }

    func flush() {
        guard !queue.isEmpty else { return }
        let logs = queue
        queue = []

        Task {
            do {
                let body = try JSONSerialization.data(withJSONObject: ["logs": logs])
                var request = URLRequest(url: URL(string: "\(baseURL)/dev/log/batch")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                _ = try await URLSession.shared.data(for: request)
            } catch {
                // 로그 전송 실패는 무시
            }
        }
    }
}

// 편의 함수
func appLog(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
    LogService.shared.info(tag, message, data)
}

func appLogError(_ tag: String, _ message: String, _ data: [String: Any]? = nil) {
    LogService.shared.error(tag, message, data)
}
