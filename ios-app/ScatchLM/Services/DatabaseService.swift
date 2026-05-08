import Foundation
import GRDB

final class DatabaseService {
    static let shared = DatabaseService()

    private var dbQueue: DatabaseQueue!

    private init() {
        do {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dbURL = appSupport.appendingPathComponent("scatchlm.db")
            dbQueue = try DatabaseQueue(path: dbURL.path)
            try migrate()
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "notes", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("language", .text).notNull().defaults(to: "en")
                t.column("textbook_id", .text)
                t.column("textbook_name", .text)
                t.column("textbook_pages", .integer).defaults(to: 0)
                t.column("drawing_data", .blob)
                t.column("last_page", .integer).defaults(to: 1)
                t.column("pdf_open", .boolean).defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "feedbacks", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).notNull().references("notes", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("position_x", .double).notNull()
                t.column("position_y", .double).notNull()
                t.column("bbox_x", .double).notNull()
                t.column("bbox_y", .double).notNull()
                t.column("bbox_width", .double).notNull()
                t.column("bbox_height", .double).notNull()
                t.column("created_at", .datetime).notNull()
            }

            try db.create(table: "pdf_drawings", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("textbook_id", .text).notNull()
                t.column("page", .integer).notNull()
                t.column("drawing_data", .blob).notNull()
                t.column("updated_at", .datetime).notNull()
                t.uniqueKey(["textbook_id", "page"])
            }

        }

        migrator.registerMigration("v2_feedback_chats") { db in
            try db.create(table: "feedback_chats", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("feedback_id", .text).notNull().references("feedbacks", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v3_note_pages") { db in
            // 1. Create note_pages table
            try db.create(table: "note_pages", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).notNull().references("notes", onDelete: .cascade)
                t.column("page_index", .integer).notNull()
                t.column("drawing_data", .blob)
                t.column("created_at", .datetime).notNull()
                t.uniqueKey(["note_id", "page_index"])
            }

            // 2. Add page_id to feedbacks
            try db.alter(table: "feedbacks") { t in
                t.add(column: "page_id", .text)
            }

            // 3. Add current_page_index to notes
            try db.alter(table: "notes") { t in
                t.add(column: "current_page_index", .integer).defaults(to: 0)
            }

            // 4. Migrate existing drawing_data to page 0
            let notes = try Row.fetchAll(db, sql: "SELECT id, drawing_data FROM notes")
            for note in notes {
                let noteId: String = note["id"]
                let drawingData: Data? = note["drawing_data"]
                let pageId = UUID().uuidString
                try db.execute(
                    sql: "INSERT INTO note_pages (id, note_id, page_index, drawing_data, created_at) VALUES (?, ?, 0, ?, ?)",
                    arguments: [pageId, noteId, drawingData, Date()]
                )
                // Link existing feedbacks to this page
                try db.execute(
                    sql: "UPDATE feedbacks SET page_id = ? WHERE note_id = ?",
                    arguments: [pageId, noteId]
                )
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Notes

    func allNotes() throws -> [Note] {
        try dbQueue.read { db in
            try Note.order(Note.Columns.updatedAt.desc).fetchAll(db)
        }
    }

    func note(id: String) throws -> Note? {
        try dbQueue.read { db in
            try Note.fetchOne(db, key: id)
        }
    }

    func saveNote(_ note: inout Note) throws {
        try dbQueue.write { db in
            try note.save(db)
        }
    }

    func deleteNote(id: String) throws {
        try dbQueue.write { db in
            _ = try Note.deleteOne(db, key: id)
        }
    }

    func updateDrawingData(noteId: String, data: Data) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET drawing_data = ?, updated_at = ? WHERE id = ?",
                arguments: [data, Date(), noteId]
            )
        }
    }

    func updateLastPage(noteId: String, page: Int) throws {
        guard page >= 1 && page <= 10000 else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET last_page = ? WHERE id = ?",
                arguments: [page, noteId]
            )
        }
    }

    func updatePdfOpen(noteId: String, open: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET pdf_open = ? WHERE id = ?",
                arguments: [open, noteId]
            )
        }
    }

    func linkTextbook(noteId: String, textbookId: String, name: String, pages: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET textbook_id = ?, textbook_name = ?, textbook_pages = ?, updated_at = ? WHERE id = ?",
                arguments: [textbookId, name, pages, Date(), noteId]
            )
        }
    }

    // MARK: - Feedbacks

    func feedbacks(noteId: String) throws -> [FeedbackRecord] {
        try dbQueue.read { db in
            try FeedbackRecord
                .filter(FeedbackRecord.Columns.noteId == noteId)
                .order(FeedbackRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func saveFeedback(_ feedback: inout FeedbackRecord) throws {
        try dbQueue.write { db in
            try feedback.save(db)
        }
    }

    // MARK: - PDF Drawings

    func pdfDrawing(textbookId: String, page: Int) throws -> PdfDrawing? {
        try dbQueue.read { db in
            try PdfDrawing
                .filter(PdfDrawing.Columns.textbookId == textbookId && PdfDrawing.Columns.page == page)
                .fetchOne(db)
        }
    }

    func savePdfDrawing(textbookId: String, page: Int, data: Data) throws {
        try dbQueue.write { db in
            let id = "\(textbookId)_\(page)"
            let drawing = PdfDrawing(
                id: id,
                textbookId: textbookId,
                page: page,
                drawingData: data,
                updatedAt: Date()
            )
            try drawing.save(db)
        }
    }

    // MARK: - Note Pages

    func pages(noteId: String) throws -> [NotePage] {
        try dbQueue.read { db in
            try NotePage
                .filter(NotePage.Columns.noteId == noteId)
                .order(NotePage.Columns.pageIndex.asc)
                .fetchAll(db)
        }
    }

    func page(noteId: String, pageIndex: Int) throws -> NotePage? {
        try dbQueue.read { db in
            try NotePage
                .filter(NotePage.Columns.noteId == noteId && NotePage.Columns.pageIndex == pageIndex)
                .fetchOne(db)
        }
    }

    func createPage(noteId: String, pageIndex: Int) throws -> NotePage {
        var page = NotePage(
            id: UUID().uuidString,
            noteId: noteId,
            pageIndex: pageIndex,
            drawingData: nil,
            createdAt: Date()
        )
        try dbQueue.write { db in
            try page.save(db)
        }
        return page
    }

    func savePageDrawing(pageId: String, data: Data) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note_pages SET drawing_data = ? WHERE id = ?",
                arguments: [data, pageId]
            )
        }
    }

    func updateCurrentPageIndex(noteId: String, index: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET current_page_index = ? WHERE id = ?",
                arguments: [index, noteId]
            )
        }
    }

    func feedbacks(pageId: String) throws -> [FeedbackRecord] {
        try dbQueue.read { db in
            try FeedbackRecord
                .filter(sql: "page_id = ?", arguments: [pageId])
                .order(FeedbackRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    // MARK: - Feedback Chats

    func chatMessages(feedbackId: String) throws -> [ChatMessageRecord] {
        try dbQueue.read { db in
            try ChatMessageRecord
                .filter(ChatMessageRecord.Columns.feedbackId == feedbackId)
                .order(ChatMessageRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func saveChatMessage(_ msg: inout ChatMessageRecord) throws {
        try dbQueue.write { db in
            try msg.save(db)
        }
    }
}
