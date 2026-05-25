import Foundation
import GRDB

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
    }

    static func new(title: String, language: String = "en") -> Note {
        Note(
            id: UUID().uuidString,
            title: title,
            language: language,
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
        userRatingSyncedAt: Date? = nil
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

    enum CodingKeys: String, CodingKey {
        case id
        case noteId = "note_id"
        case pageIndex = "page_index"
        case drawingData = "drawing_data"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id
        case noteId = "note_id"
        case pageIndex = "page_index"
        case drawingData = "drawing_data"
        case createdAt = "created_at"
    }
}

struct ChatMessageRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "feedback_chats"

    var id: String
    var feedbackId: String
    var role: String  // "user" or "assistant"
    var content: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case feedbackId = "feedback_id"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id, role, content
        case feedbackId = "feedback_id"
        case createdAt = "created_at"
    }
}
