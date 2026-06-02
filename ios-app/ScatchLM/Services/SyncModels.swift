import Foundation

// MARK: - 동결 계약 (§3.2) 와이어 DTO
//
// PK는 클라 생성 UUID를 서버·클라 공유 canonical id로 사용(§3.2). 날짜는 ISO8601 UTC 문자열.
// drawing 본문(blob)은 별도 채널(§3.2-c/d)로 전송하고 여기서는 drawing_hash만 오간다.
// DTO 프로퍼티명은 와이어 JSON 키와 1:1(snake_case)로 두어 CodingKeys 보일러플레이트를 없앤다.

struct SyncNoteDTO: Codable {
    var id: String
    var updated_at: String
    var deleted: Bool
    var title: String
    var language: String
    var textbook_id: String?
    var textbook_name: String?
    var textbook_pages: Int
    var last_page: Int
    var pdf_open: Bool
    var current_page_index: Int
    var drawing_hash: String?
    var created_at: String
}

struct SyncPageDTO: Codable {
    var id: String
    var updated_at: String
    var deleted: Bool
    var note_id: String
    var page_index: Int
    var drawing_hash: String?
    var created_at: String
}

struct SyncFeedbackDTO: Codable {
    var id: String
    var updated_at: String
    var deleted: Bool
    var note_id: String
    var page_id: String?
    var content: String
    var position_x: Double
    var position_y: Double
    var bbox_x: Double
    var bbox_y: Double
    var bbox_width: Double
    var bbox_height: Double
    var stroke_range_start: Int?
    var stroke_range_end: Int?
    var server_feedback_id: String?
    var user_rating: Int?
    var created_at: String
}

struct SyncChatDTO: Codable {
    var id: String
    var updated_at: String
    var deleted: Bool
    var feedback_id: String
    var role: String
    var content: String
    var server_message_id: String?
    var user_rating: Int?
    var created_at: String
}

struct SyncChanges: Codable {
    var notes: [SyncNoteDTO]
    var note_pages: [SyncPageDTO]
    var feedbacks: [SyncFeedbackDTO]
    var chat_messages: [SyncChatDTO]

    static let empty = SyncChanges(notes: [], note_pages: [], feedbacks: [], chat_messages: [])

    var isEmpty: Bool {
        notes.isEmpty && note_pages.isEmpty && feedbacks.isEmpty && chat_messages.isEmpty
    }
}

// MARK: - 요청/응답 (§3.2-a/b/c)

struct SyncPullRequest: Encodable {
    var since: String?
    var limit: Int
}

struct SyncPullResponse: Decodable {
    var changes: SyncChanges
    var cursor: String
    var has_more: Bool
}

struct SyncPushRequest: Encodable {
    var changes: SyncChanges
}

struct SyncPushResult: Decodable {
    var id: String
    var entity: String          // "note" | "note_page" | "feedback" | "chat_message"
    var status: String          // "applied" | "conflict" | "missing_blob"
    var server_updated_at: String?
}

struct SyncPushResponse: Decodable {
    var results: [SyncPushResult]
    var missing_blobs: [String]
}

struct SyncBlobResponse: Decodable {
    var hash: String
    var stored: Bool
}

// MARK: - API 추상화 (테스트 더블로 모킹 가능, §3.2 MSW 비고 / C-5)

protocol SyncAPIClient {
    func syncPull(since: String?, limit: Int) async throws -> SyncPullResponse
    func syncPush(_ changes: SyncChanges) async throws -> SyncPushResponse
    func syncUploadBlob(hash: String, data: Data) async throws -> SyncBlobResponse
    func syncDownloadBlob(hash: String) async throws -> Data
}

// MARK: - 날짜 변환 (ISO8601 UTC, ms 정밀도 — LWW 경계 정확성, §7)

enum SyncDate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// 프랙셔널 초가 없는 ISO8601("2026-06-01T08:12:00Z")도 허용하는 fallback 파서.
    private static let fallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? fallback.date(from: string)
    }
}
