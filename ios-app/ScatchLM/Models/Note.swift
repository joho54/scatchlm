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
    var folderId: String?   // 미분류=nil (전체). 폴더 정리 (note-folders-spec §4.1)
    var textbookId: String?
    var textbookName: String?
    var textbookPages: Int
    var drawingData: Data?
    var lastPage: Int
    var pdfOpen: Bool
    var currentPageIndex: Int
    var template: String   // 캔버스 배경 템플릿 (NoteTemplate.rawValue). 기본 "blank".
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
        case folderId = "folder_id"
        case textbookId = "textbook_id"
        case textbookName = "textbook_name"
        case textbookPages = "textbook_pages"
        case drawingData = "drawing_data"
        case lastPage = "last_page"
        case pdfOpen = "pdf_open"
        case currentPageIndex = "current_page_index"
        case template
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case userId = "user_id"
        case drawingHash = "drawing_hash"
        case deleted, dirty
    }

    enum Columns: String, ColumnExpression {
        case id, title, language
        case folderId = "folder_id"
        case textbookId = "textbook_id"
        case textbookName = "textbook_name"
        case textbookPages = "textbook_pages"
        case drawingData = "drawing_data"
        case lastPage = "last_page"
        case pdfOpen = "pdf_open"
        case currentPageIndex = "current_page_index"
        case template
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
        folderId: String? = nil,
        textbookId: String?,
        textbookName: String?,
        textbookPages: Int,
        drawingData: Data?,
        lastPage: Int,
        pdfOpen: Bool,
        currentPageIndex: Int,
        template: String = "blank",
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
        self.folderId = folderId
        self.textbookId = textbookId
        self.textbookName = textbookName
        self.textbookPages = textbookPages
        self.drawingData = drawingData
        self.lastPage = lastPage
        self.pdfOpen = pdfOpen
        self.currentPageIndex = currentPageIndex
        self.template = template
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

    /// 노트 목록 검색 매칭 — 제목·과목(language)·연결된 교재명 중 하나라도
    /// 부분 매칭(대소문자 무시)되면 true. 빈/공백 검색어는 항상 true(전체 노출).
    func matchesSearch(_ rawTerm: String) -> Bool {
        let term = rawTerm.trimmingCharacters(in: .whitespaces)
        if term.isEmpty { return true }
        return title.localizedCaseInsensitiveContains(term)
            || language.localizedCaseInsensitiveContains(term)
            || (textbookName?.localizedCaseInsensitiveContains(term) ?? false)
    }

    static func new(title: String, language: String = "", folderId: String? = nil) -> Note {
        Note(
            id: UUID().uuidString,
            title: title,
            language: language,  // 빈 문자열이면 분야 중립 튜터 (백엔드가 처리)
            folderId: folderId,
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

/// 노트 정리용 플랫(단일 레벨) 폴더 (note-folders-spec §4.1).
/// note.folderId가 이 폴더를 가리킨다. 삭제는 soft delete이며 소속 노트는
/// folderId=nil(전체)로 옮겨 보존한다(§4.4). sync 메타는 다른 엔티티와 동일.
struct Folder: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "folders"

    var id: String
    var name: String
    var sortOrder: Int
    var createdAt: Date
    // sync 메타
    var userId: String
    var updatedAt: Date
    var deleted: Bool
    var dirty: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case userId = "user_id"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    enum Columns: String, ColumnExpression {
        case id, name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case userId = "user_id"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        userId: String = "",
        updatedAt: Date = Date(),
        deleted: Bool = false,
        dirty: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.userId = userId
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.dirty = dirty
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
    /// placement → 세션 (§4.5). 세션을 캔버스에 배치한 뷰. 레거시 단독 카드는 nil.
    var sessionId: String?
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
        case sessionId = "session_id"
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
        case sessionId = "session_id"
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
        sessionId: String? = nil,
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
        self.sessionId = sessionId
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

/// PDF 페이지 위 필기(마크업) 오버레이. AI 비종속 순수 필기.
/// note_pages와 동일한 노트 종속·sync 모델이되 페이지 키가 PDF 페이지 번호(1-based).
/// 같은 교재라도 노트마다 독립된 필기를 갖는다(귀속: note_id + pdf_page).
struct PdfAnnotation: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "pdf_annotations"

    var id: String
    var noteId: String
    var pdfPage: Int          // 1-based PDF 페이지 번호
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
        case pdfPage = "pdf_page"
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
        case pdfPage = "pdf_page"
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
        pdfPage: Int,
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
        self.pdfPage = pdfPage
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
    /// 세션 FK (§4.1). 모든 신규 메시지는 세션에 속한다.
    var sessionId: String
    /// 레거시 FK. 마이그레이션 후 null 가능, 하위호환 위해 유지(§3.2-a / R3).
    var feedbackId: String?
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
        case sessionId = "session_id"
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
        case sessionId = "session_id"
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
        sessionId: String,
        feedbackId: String? = nil,
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
        self.sessionId = sessionId
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

/// 캔버스 비종속 채팅 세션 (chapter-chat-drawer-spec §4.1).
/// 가이드 채팅·피드백 채팅을 한 엔티티로 흡수한다. 챕터 귀속은 `textbookId`+`anchorPage`로
/// 보관하고, 표시 시점에 backend chapters(page_start/page_end)로 page→챕터를 계산한다.
struct ChatSessionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "chat_sessions"

    var id: String
    var kind: String          // "page_guide" | "chapter_guide" | "feedback"
    var title: String         // 첫 사용자 질문 (피드백 세션은 백필 폴백)
    var noteId: String?       // 세션이 생성된 노트 (가이드는 null 가능)
    var textbookId: String?
    var anchorPage: Int?      // page→챕터 계산 기준 (1-based)
    var chapterTitle: String? // 표시용 스냅샷 (교재 미로드 시 폴백)
    var sourceFeedbackId: String?  // feedback 세션 원본 AIResponse id (rating 연계)
    var createdAt: Date
    // sync 메타
    var userId: String
    var updatedAt: Date
    var deleted: Bool
    var dirty: Bool

    /// 세션 종류.
    enum Kind: String {
        case pageGuide = "page_guide"
        case chapterGuide = "chapter_guide"
        case feedback
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title
        case noteId = "note_id"
        case textbookId = "textbook_id"
        case anchorPage = "anchor_page"
        case chapterTitle = "chapter_title"
        case sourceFeedbackId = "source_feedback_id"
        case createdAt = "created_at"
        case userId = "user_id"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    enum Columns: String, ColumnExpression {
        case id, kind, title
        case noteId = "note_id"
        case textbookId = "textbook_id"
        case anchorPage = "anchor_page"
        case chapterTitle = "chapter_title"
        case sourceFeedbackId = "source_feedback_id"
        case createdAt = "created_at"
        case userId = "user_id"
        case updatedAt = "updated_at"
        case deleted, dirty
    }

    init(
        id: String = UUID().uuidString,
        kind: String,
        title: String,
        noteId: String? = nil,
        textbookId: String? = nil,
        anchorPage: Int? = nil,
        chapterTitle: String? = nil,
        sourceFeedbackId: String? = nil,
        createdAt: Date = Date(),
        userId: String = "",
        updatedAt: Date = Date(),
        deleted: Bool = false,
        dirty: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.noteId = noteId
        self.textbookId = textbookId
        self.anchorPage = anchorPage
        self.chapterTitle = chapterTitle
        self.sourceFeedbackId = sourceFeedbackId
        self.createdAt = createdAt
        self.userId = userId
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.dirty = dirty
    }
}
