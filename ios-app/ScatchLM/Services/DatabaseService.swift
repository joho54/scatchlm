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
}
