import Foundation
import GRDB

// 모든 sync 대상 모델은 동기화 메타를 공유한다 (cloud-data-sync-spec §4.3):
//   userId    — 현재 세션 user.id 스코프 (§4.5). write 시 DatabaseService가 주입.
//   deleted   — soft delete tombstone.
//   dirty     — 미전송 로컬 변경. write 시 1, push 성공 시 0.
//   drawingHash — note/note_page만: PKDrawing blob의 sha256(hex). null=빈 드로잉.

struct Note: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "notes"

    var id: String
    var title: String
    var language: String
    var textbookId: String?
    var textbookName: String?
    var textbookPages: Int
    var drawingData: Data?
    var lastPage: Int
    var pdfOpen: Bool
    var currentPageIndex: Int
    var createdAt: Date
    var updatedAt: Date
    // sync 메타
    var userId: String
    var drawingHash: String?
    var deleted: Bool
    var dirty: Bool

    // DB 컬럼명 매핑 (snake_case)
    enum CodingKeys: String, CodingKey {
        case id, title, language
        case textbookId = "textbook_id"
        case textbookName = "textbook_name"
        case textbookPages = "textbook_pages"
        case drawingData = "drawing_data"
        case lastPage = "last_page"
        case pdfOpen = "pdf_open"
        case currentPageIndex = "current_page_index"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case userId = "user_id"
        case drawingHash = "drawing_hash"
        case deleted, dirty
    }

    enum Columns: String, ColumnExpression {
        case id, title, language
        case textbookId = "textbook_id"
        case textbookName = "textbook_name"
        case textbookPages = "textbook_pages"
        case drawingData = "drawing_data"
        case lastPage = "last_page"
        case pdfOpen = "pdf_open"
        case currentPageIndex = "current_page_index"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case userId = "user_id"
        case drawingHash = "drawing_hash"
        case deleted, dirty
    }

    init(
        id: String,
        title: String,
        language: String,
        textbookId: String?,
        textbookName: String?,
        textbookPages: Int,
        drawingData: Data?,
        lastPage: Int,
        pdfOpen: Bool,
        currentPageIndex: Int,
        createdAt: Date,
        updatedAt: Date,
        userId: String = "",
        drawingHash: String? = nil,
        deleted: Bool = false,
        dirty: Bool = true
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.textbookId = textbookId
        self.textbookName = textbookName
        self.textbookPages = textbookPages
        self.drawingData = drawingData
        self.lastPage = lastPage
        self.pdfOpen = pdfOpen
        self.currentPageIndex = currentPageIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userId = userId
        self.drawingHash = drawingHash
        self.deleted = deleted
        self.dirty = dirty
    }

    /// 제목 기본값 결정 — 비어 있으면 교재 이름(있으면)에서, 그것도 없으면 "제목 없음".
    /// PDF 확장자는 떼고 보여준다. 사용자가 입력한 제목이 있으면 그대로 둔다.
    static func resolveTitle(_ title: String, textbookName: String?) -> String {
        if !title.isEmpty { return title }
        if let name = textbookName, !name.isEmpty {
            let stripped = name.lowercased().hasSuffix(".pdf") ? String(name.dropLast(4)) : name
            if !stripped.isEmpty { return stripped }
        }
        return String(localized: "제목 없음")
    }

    static func new(title: String, language: String = "") -> Note {
        Note(
            id: UUID().uuidString,
            title: title,
            language: language,  // 빈 문자열이면 분야 중립 튜터 (백엔드가 처리)
            textbookId: nil,
            textbookName: nil,
            textbookPages: 0,
            drawingData: nil,
            lastPage: 1,
            pdfOpen: false,
            currentPageIndex: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct FeedbackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "feedbacks"

    var id: String
    var noteId: String
    var pageId: String?
    var content: String
    var positionX: Double
    var positionY: Double
    var bboxX: Double
    var bboxY: Double
    var bboxWidth: Double
    var bboxHeight: Double
    var strokeRangeStart: Int
    var strokeRangeEnd: Int
    var createdAt: Date
    var serverFeedbackId: String?
    var userRating: Int?
    var userRatingSyncedAt: Date?
    // sync 메타
    var userId: String
    var updatedAt: Date
    var deleted: Bool
    var dirty: Bool

    enum CodingKeys: String, CodingKey {
        case id, content
        case noteId = "note_id"
        case pageId = "page_id"
        case positionX = "position_x"
        case positionY = "position_y"
        case bboxX = "bbox_x"
        case bboxY = "bbox_y"
        case bboxWidth = "bbox_width"
        case bboxHeight = "bbox_height"
        case strokeRangeStart = "stroke_range_start"
        case strokeRangeEnd = "stroke_range_end"
        case createdAt = "created_at"
        case serverFeedbackId = "server_feedback_id"
        case userRating = "user_rating"
        case userRatingSyncedAt = "user_rating_synced_at"
        case userId = "user_id"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    enum Columns: String, ColumnExpression {
        case id, content
        case noteId = "note_id"
        case pageId = "page_id"
        case positionX = "position_x"
        case positionY = "position_y"
        case bboxX = "bbox_x"
        case bboxY = "bbox_y"
        case bboxWidth = "bbox_width"
        case bboxHeight = "bbox_height"
        case strokeRangeStart = "stroke_range_start"
        case strokeRangeEnd = "stroke_range_end"
        case createdAt = "created_at"
        case serverFeedbackId = "server_feedback_id"
        case userRating = "user_rating"
        case userRatingSyncedAt = "user_rating_synced_at"
        case userId = "user_id"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    init(
        id: String,
        noteId: String,
        pageId: String?,
        content: String,
        positionX: Double,
        positionY: Double,
        bboxX: Double,
        bboxY: Double,
        bboxWidth: Double,
        bboxHeight: Double,
        strokeRangeStart: Int,
        strokeRangeEnd: Int,
        createdAt: Date,
        serverFeedbackId: String? = nil,
        userRating: Int? = nil,
        userRatingSyncedAt: Date? = nil,
        userId: String = "",
        updatedAt: Date = Date(),
        deleted: Bool = false,
        dirty: Bool = true
    ) {
        self.id = id
        self.noteId = noteId
        self.pageId = pageId
        self.content = content
        self.positionX = positionX
        self.positionY = positionY
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxWidth = bboxWidth
        self.bboxHeight = bboxHeight
        self.strokeRangeStart = strokeRangeStart
        self.strokeRangeEnd = strokeRangeEnd
        self.createdAt = createdAt
        self.serverFeedbackId = serverFeedbackId
        self.userRating = userRating
        self.userRatingSyncedAt = userRatingSyncedAt
        self.userId = userId
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.dirty = dirty
    }
}

struct PdfDrawing: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pdf_drawings"

    var id: String
    var textbookId: String
    var page: Int
    var drawingData: Data
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, page
        case textbookId = "textbook_id"
        case drawingData = "drawing_data"
        case updatedAt = "updated_at"
    }

    enum Columns: String, ColumnExpression {
        case id, page
        case textbookId = "textbook_id"
        case drawingData = "drawing_data"
        case updatedAt = "updated_at"
    }
}

struct NotePage: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "note_pages"

    var id: String
    var noteId: String
    var pageIndex: Int
    var drawingData: Data?
    var createdAt: Date
    // sync 메타
    var userId: String
    var drawingHash: String?
    var updatedAt: Date
    var deleted: Bool
    var dirty: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case noteId = "note_id"
        case pageIndex = "page_index"
        case drawingData = "drawing_data"
        case createdAt = "created_at"
        case userId = "user_id"
        case drawingHash = "drawing_hash"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    enum Columns: String, ColumnExpression {
        case id
        case noteId = "note_id"
        case pageIndex = "page_index"
        case drawingData = "drawing_data"
        case createdAt = "created_at"
        case userId = "user_id"
        case drawingHash = "drawing_hash"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    init(
        id: String,
        noteId: String,
        pageIndex: Int,
        drawingData: Data?,
        createdAt: Date,
        userId: String = "",
        drawingHash: String? = nil,
        updatedAt: Date = Date(),
        deleted: Bool = false,
        dirty: Bool = true
    ) {
        self.id = id
        self.noteId = noteId
        self.pageIndex = pageIndex
        self.drawingData = drawingData
        self.createdAt = createdAt
        self.userId = userId
        self.drawingHash = drawingHash
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.dirty = dirty
    }
}

struct ChatMessageRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "feedback_chats"

    var id: String
    var feedbackId: String
    var role: String  // "user" or "assistant"
    var content: String
    var createdAt: Date
    var serverMessageId: String?
    var userRating: Int?
    var userRatingSyncedAt: Date?
    // sync 메타
    var userId: String
    var updatedAt: Date
    var deleted: Bool
    var dirty: Bool

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case feedbackId = "feedback_id"
        case createdAt = "created_at"
        case serverMessageId = "server_message_id"
        case userRating = "user_rating"
        case userRatingSyncedAt = "user_rating_synced_at"
        case userId = "user_id"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    enum Columns: String, ColumnExpression {
        case id, role, content
        case feedbackId = "feedback_id"
        case createdAt = "created_at"
        case serverMessageId = "server_message_id"
        case userRating = "user_rating"
        case userRatingSyncedAt = "user_rating_synced_at"
        case userId = "user_id"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    init(
        id: String,
        feedbackId: String,
        role: String,
        content: String,
        createdAt: Date,
        serverMessageId: String? = nil,
        userRating: Int? = nil,
        userRatingSyncedAt: Date? = nil,
        userId: String = "",
        updatedAt: Date = Date(),
        deleted: Bool = false,
        dirty: Bool = true
    ) {
        self.id = id
        self.feedbackId = feedbackId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.serverMessageId = serverMessageId
        self.userRating = userRating
        self.userRatingSyncedAt = userRatingSyncedAt
        self.userId = userId
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.dirty = dirty
    }
}
