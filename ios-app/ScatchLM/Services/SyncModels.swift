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
    var folder_id: String?      // 미분류=null (§3.2-a). 폴더 정리
    var textbook_id: String?
    var textbook_name: String?
    var textbook_pages: Int
    var last_page: Int
    var pdf_open: Bool
    var current_page_index: Int
    var template: String?       // 캔버스 배경 템플릿(NoteTemplate.rawValue). 구버전 페이로드 호환 위해 옵셔널.
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

/// PDF 페이지 필기 오버레이 (필기 전용). note 참조 → notes 다음에 적용.
/// drawing 본문은 blob 채널(drawing_hash)로 별도 전송.
struct SyncPdfAnnotationDTO: Codable {
    var id: String
    var updated_at: String
    var deleted: Bool
    var note_id: String
    var pdf_page: Int
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
    var session_id: String?     // placement → 세션 (§3.2-a). 레거시 단독 카드는 null
    var created_at: String
}

struct SyncChatDTO: Codable {
    var id: String
    var updated_at: String
    var deleted: Bool
    var session_id: String      // 신규 FK (§3.2-a)
    var feedback_id: String?    // 레거시. 마이그레이션 후 null 가능
    var role: String
    var content: String
    var server_message_id: String?
    var user_rating: Int?
    var created_at: String
}

/// 캔버스 비종속 채팅 세션 (§3.2-a). push/pull 양방향.
struct SyncSessionDTO: Codable {
    var id: String
    var updated_at: String
    var deleted: Bool
    var kind: String            // page_guide | chapter_guide | feedback
    var title: String
    var note_id: String?
    var textbook_id: String?
    var anchor_page: Int?
    var chapter_title: String?
    var source_feedback_id: String?
    var created_at: String
}

/// 노트 정리 폴더 (note-folders-spec §3.2-a). push/pull 양방향.
/// notes보다 먼저 적용해 note.folder_id가 가리키는 폴더를 우선 머지한다(참조 무결성).
struct SyncFolderDTO: Codable {
    var id: String
    var updated_at: String
    var deleted: Bool
    var name: String
    var sort_order: Int
    var created_at: String
}

struct SyncChanges: Codable {
    // sessions를 먼저 두어 직렬화/적용 순서에서 chat_messages보다 앞서게 한다(참조 무결성, §3.2-a).
    // folders는 notes 앞 — note.folder_id 참조 무결성(§3.2-a / R1).
    var sessions: [SyncSessionDTO]
    var folders: [SyncFolderDTO]
    var notes: [SyncNoteDTO]
    var note_pages: [SyncPageDTO]
    var pdf_annotations: [SyncPdfAnnotationDTO]
    var feedbacks: [SyncFeedbackDTO]
    var chat_messages: [SyncChatDTO]

    static let empty = SyncChanges(sessions: [], folders: [], notes: [], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: [])

    var isEmpty: Bool {
        sessions.isEmpty && folders.isEmpty && notes.isEmpty && note_pages.isEmpty && pdf_annotations.isEmpty && feedbacks.isEmpty && chat_messages.isEmpty
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

/// 휴지통 영구삭제 — 노트 하드 삭제 요청/응답 (서버 행 제거로 full-pull 부활 방지).
struct SyncPurgeRequest: Encodable {
    var note_ids: [String]
}

struct SyncPurgeResponse: Decodable {
    var purged: [String]
}

// MARK: - API 추상화 (테스트 더블로 모킹 가능, §3.2 MSW 비고 / C-5)

protocol SyncAPIClient {
    func syncPull(since: String?, limit: Int) async throws -> SyncPullResponse
    func syncPush(_ changes: SyncChanges) async throws -> SyncPushResponse
    func syncPurge(noteIds: [String]) async throws -> SyncPurgeResponse
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
