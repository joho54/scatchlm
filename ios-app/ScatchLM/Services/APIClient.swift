import Foundation

final class APIClient {
    static let shared = APIClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true          // 네트워크 복구 시 자동 재개
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        session = URLSession(configuration: config)
    }

    private var baseURL: String { Config.apiBaseURL }

    /// 응답을 검증한다. 비-2xx면 적절한 APIError를 던지고, X-Request-Id를 로그에 동봉한다.
    /// 반환값은 서버 생성 request_id(없으면 nil).
    @discardableResult
    private func validate(
        _ data: Data, _ response: URLResponse, method: String, path: String
    ) throws -> String? {
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        let requestId = http?.value(forHTTPHeaderField: "X-Request-Id")
        var logData: [String: Any] = ["bytes": "\(data.count)"]
        if let requestId { logData["request_id"] = requestId }
        appLog("api", "← \(statusCode) \(method) \(path)", logData)

        guard 200..<300 ~= statusCode else {
            // 429 quota 초과 — 친화 처리(§3.2-b). 정상 흐름이라 Sentry 미캡처.
            if statusCode == 429, let info = QuotaInfo.decode(from: data) {
                throw APIError.quotaExceeded(info)
            }
            // 서버 5xx만 Sentry 에러로 캡처(4xx는 클라이언트 측, 노이즈 제외 — spec §B-3·§7).
            if statusCode >= 500 {
                Observability.captureServerError(
                    status: statusCode, method: method, path: path, requestId: requestId
                )
            }
            throw APIError.serverError(statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return requestId
    }

    private func authHeaders() async -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let token = AuthService.shared.accessToken {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    // MARK: - GET

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        appLog("api", "→ GET \(path)", query.isEmpty ? nil : query)
        let (data, response) = try await session.data(for: request)
        try validate(data, response, method: "GET", path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - POST (JSON)

    @discardableResult
    func postJSON<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let (data, _) = try await postJSONRaw(path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func postJSONNoContent(_ path: String, body: [String: Any]) async throws {
        _ = try await postJSONRaw(path, body: body)
    }

    private func postJSONRaw(_ path: String, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validate(data, response, method: "POST", path: path)
        return (data, response as! HTTPURLResponse)
    }

    // MARK: - POST (multipart/form-data)

    func postMultipart<T: Decodable>(
        _ path: String,
        fields: [String: String],
        fileField: String? = nil,
        fileData: Data? = nil,
        fileName: String? = nil,
        mimeType: String? = nil
    ) async throws -> T {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()

        // Text fields
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // File field
        if let fileField, let fileData, let fileName, let mimeType {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validate(data, response, method: "POST(multipart)", path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Codable JSON helpers (sync)

    func postCodable<Req: Encodable, Res: Decodable>(_ path: String, body: Req) async throws -> Res {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(body)

        appLog("api", "→ POST \(path)")
        let (data, response) = try await session.data(for: request)
        try validate(data, response, method: "POST", path: path)
        return try JSONDecoder().decode(Res.self, from: data)
    }

    /// 바이너리 본문을 그대로 받는 GET (blob 다운로드, §3.2-d).
    func getData(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "GET"
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        try validate(data, response, method: "GET", path: path)
        return data
    }

    // MARK: - POST file upload

    func uploadFile<T: Decodable>(
        _ path: String,
        fileURL: URL,
        fields: [String: String] = [:]
    ) async throws -> T {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()

        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validate(data, response, method: "POST(upload)", path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// DELETE — 본문 없이 호출, 디코딩 가능한 응답 반환(계정 삭제 등).
    @discardableResult
    func delete<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "DELETE"
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        appLog("api", "→ DELETE \(path)")
        let (data, response) = try await session.data(for: request)
        try validate(data, response, method: "DELETE", path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// DELETE — 502(부분 실패)도 호출부에서 분기할 수 있게 status를 반환.
    /// 계정 삭제(§3.2-a): 200=완전 성공, 502=데이터 삭제됐으나 auth 잔존(로컬 purge는 진행).
    func deleteRaw(_ path: String) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "DELETE"
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        appLog("api", "→ DELETE \(path)")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        var logData: [String: Any] = ["bytes": "\(data.count)"]
        if let rid = http?.value(forHTTPHeaderField: "X-Request-Id") { logData["request_id"] = rid }
        appLog("api", "← \(status) DELETE \(path)", logData)
        return (status, data)
    }
}

// MARK: - IAP (구독 검증/상태, §3.2-a/c)

/// /api/iap/verify·/status 공통 응답. verify는 environment 포함, status는 active 포함(둘 다 optional).
struct IAPEntitlement: Decodable {
    let tier: String
    let product_id: String?
    let expires_at: String?
    let environment: String?
    let active: Bool?

    var isPro: Bool { tier == "pro" }
}

extension APIClient {
    /// 구매 트랜잭션 검증 → 서버가 tier 동기화. 200/pro면 호출부가 refreshSession()으로 JWT 갱신.
    func iapVerify(signedTransaction: String) async throws -> IAPEntitlement {
        try await postJSON("/iap/verify", body: ["signed_transaction": signedTransaction])
    }

    /// 현재 entitlement 조회(앱 시작/복원 시 재동기화).
    func iapStatus() async throws -> IAPEntitlement {
        try await get("/iap/status")
    }
}

// MARK: - SyncAPIClient 준수 (§3.2-a/b/c/d)

extension APIClient: SyncAPIClient {
    func syncPull(since: String?, limit: Int) async throws -> SyncPullResponse {
        try await postCodable("/sync/pull", body: SyncPullRequest(since: since, limit: limit))
    }

    func syncPush(_ changes: SyncChanges) async throws -> SyncPushResponse {
        try await postCodable("/sync/push", body: SyncPushRequest(changes: changes))
    }

    func syncUploadBlob(hash: String, data: Data) async throws -> SyncBlobResponse {
        try await postMultipart(
            "/sync/blob",
            fields: ["hash": hash],
            fileField: "file",
            fileData: data,
            fileName: hash,
            mimeType: "application/octet-stream"
        )
    }

    func syncDownloadBlob(hash: String) async throws -> Data {
        try await getData("/sync/blob/\(hash)")
    }
}

/// 일일 사용량 한도 초과(429) 응답 본문 (§3.2-b).
struct QuotaInfo: Decodable {
    let code: String
    let tier: String?
    let limit_usd: Double?
    let used_usd: Double?
    let reset_at: String?

    static func decode(from data: Data) -> QuotaInfo? {
        // detail 래핑 형태({"detail": {...}}) 와 평탄 형태 모두 수용.
        if let info = try? JSONDecoder().decode(QuotaInfo.self, from: data), info.code == "quota_exceeded" {
            return info
        }
        struct Wrapper: Decodable { let detail: QuotaInfo }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: data), w.detail.code == "quota_exceeded" {
            return w.detail
        }
        return nil
    }
}

enum APIError: LocalizedError {
    case serverError(Int, String)
    case quotaExceeded(QuotaInfo)

    var errorDescription: String? {
        switch self {
        case .quotaExceeded:
            return "오늘 사용량을 모두 사용했어요. 내일 다시 시도해 주세요."
        case .serverError(let code, _):
            switch code {
            case 401:
                return "로그인이 만료되었어요. 다시 로그인해 주세요."
            case 403:
                return "이 작업을 수행할 권한이 없어요."
            case 404:
                return "요청한 항목을 찾을 수 없어요."
            case 413:
                return "파일이 너무 커요. 더 작은 파일을 사용해 주세요."
            case 429:
                return "오늘 사용량을 모두 사용했어요. 내일 다시 시도해 주세요."
            case 500...599:
                return "서버에 일시적인 문제가 생겼어요. 잠시 후 다시 시도해 주세요."
            default:
                return "요청을 처리하지 못했어요. 잠시 후 다시 시도해 주세요."
            }
        }
    }
}
