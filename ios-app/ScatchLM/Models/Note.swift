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
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct FeedbackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "feedbacks"

    var id: String
    var noteId: String
    var content: String
    var positionX: Double
    var positionY: Double
    var bboxX: Double
    var bboxY: Double
    var bboxWidth: Double
    var bboxHeight: Double
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, content
        case noteId = "note_id"
        case positionX = "position_x"
        case positionY = "position_y"
        case bboxX = "bbox_x"
        case bboxY = "bbox_y"
        case bboxWidth = "bbox_width"
        case bboxHeight = "bbox_height"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id, content
        case noteId = "note_id"
        case positionX = "position_x"
        case positionY = "position_y"
        case bboxX = "bbox_x"
        case bboxY = "bbox_y"
        case bboxWidth = "bbox_width"
        case bboxHeight = "bbox_height"
        case createdAt = "created_at"
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
