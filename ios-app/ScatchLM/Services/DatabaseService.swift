import Foundation
import GRDB

enum DatabaseServiceError: Error {
    /// 로그인 세션이 없어 sync 대상 write를 수행할 수 없음 (§4.5).
    case noActiveUser
}

final class DatabaseService {
    static let shared = DatabaseService()

    /// Sync 확장(DatabaseService+Sync)이 접근할 수 있도록 read 가시성만 개방.
    private(set) var dbQueue: DatabaseQueue!

    /// 현재 세션 user.id (소문자 UUID, JWT sub와 일치). AuthService가 주입한다(§4.5 / B-4).
    /// 모든 sync 대상 read/write가 이 값으로 스코프된다. nil/빈값이면 미로그인.
    var currentUserId: String?

    /// 앱발 write(노트/페이지/피드백/채팅 저장·삭제) 직후 호출되는 훅(§4.2-1, D-2).
    /// SyncService가 디바운스 push 트리거로 사용한다. 서버발 머지(applyPulled*)·claim은 호출하지 않는다.
    var onWrite: (() -> Void)?

    private func notifyWrite() { onWrite?() }

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

    /// sync 대상 write에 필요한 현재 user_id. 세션 없으면 throw (§4.5: 미로그인 시 write 보류).
    private func requireUserId() throws -> String {
        guard let uid = currentUserId, !uid.isEmpty else {
            throw DatabaseServiceError.noActiveUser
        }
        return uid
    }

    /// 조회 스코프 user_id. 세션 없으면 nil → 호출부는 빈 결과를 반환한다.
    private var scopedUserId: String? {
        guard let uid = currentUserId, !uid.isEmpty else { return nil }
        return uid
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

        migrator.registerMigration("v4_feedback_stroke_range") { db in
            try db.alter(table: "feedbacks") { t in
                t.add(column: "stroke_range_start", .integer).notNull().defaults(to: 0)
                t.add(column: "stroke_range_end", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v5_feedback_user_rating") { db in
            try db.alter(table: "feedbacks") { t in
                t.add(column: "server_feedback_id", .text)
                t.add(column: "user_rating", .integer)
                t.add(column: "user_rating_synced_at", .datetime)
            }
        }

        migrator.registerMigration("v6_chat_message_rating") { db in
            try db.alter(table: "feedback_chats") { t in
                t.add(column: "server_message_id", .text)
                t.add(column: "user_rating", .integer)
                t.add(column: "user_rating_synced_at", .datetime)
            }
        }

        // v7: 동기화 메타 (cloud-data-sync-spec §4.3 / §4.6 / B-1)
        // sync 대상 4개 테이블(notes/note_pages/feedbacks/feedback_chats)에
        // user_id/deleted/dirty 추가. notes/note_pages에는 drawing_hash,
        // note_pages/feedbacks/feedback_chats에는 updated_at(LWW 기준) 추가.
        // 기존 행: user_id='' sentinel(§4.6 → 첫 로그인 시 claim), dirty=1(미전송),
        // updated_at=created_at backfill.
        migrator.registerMigration("v7_sync_metadata") { db in
            // notes (updated_at 기존 보유)
            try db.alter(table: "notes") { t in
                t.add(column: "user_id", .text).notNull().defaults(to: "")
                t.add(column: "drawing_hash", .text)
                t.add(column: "deleted", .boolean).notNull().defaults(to: false)
                t.add(column: "dirty", .boolean).notNull().defaults(to: true)
            }

            // note_pages (updated_at 신규)
            try db.alter(table: "note_pages") { t in
                t.add(column: "user_id", .text).notNull().defaults(to: "")
                t.add(column: "drawing_hash", .text)
                t.add(column: "updated_at", .datetime)
                t.add(column: "deleted", .boolean).notNull().defaults(to: false)
                t.add(column: "dirty", .boolean).notNull().defaults(to: true)
            }
            try db.execute(sql: "UPDATE note_pages SET updated_at = created_at WHERE updated_at IS NULL")

            // feedbacks (updated_at 신규)
            try db.alter(table: "feedbacks") { t in
                t.add(column: "user_id", .text).notNull().defaults(to: "")
                t.add(column: "updated_at", .datetime)
                t.add(column: "deleted", .boolean).notNull().defaults(to: false)
                t.add(column: "dirty", .boolean).notNull().defaults(to: true)
            }
            try db.execute(sql: "UPDATE feedbacks SET updated_at = created_at WHERE updated_at IS NULL")

            // feedback_chats (updated_at 신규)
            try db.alter(table: "feedback_chats") { t in
                t.add(column: "user_id", .text).notNull().defaults(to: "")
                t.add(column: "updated_at", .datetime)
                t.add(column: "deleted", .boolean).notNull().defaults(to: false)
                t.add(column: "dirty", .boolean).notNull().defaults(to: true)
            }
            try db.execute(sql: "UPDATE feedback_chats SET updated_at = created_at WHERE updated_at IS NULL")
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - 레거시 행 claim (§4.6)

    /// v7 이전 단일 공유 DB의 sentinel(user_id='') 행을 현재 user.id로 1회 흡수한다.
    /// 첫 로그인 시 호출(D-1). dirty=1로 표시해 이후 sync로 서버에 올라간다.
    /// claim 후 sentinel 행이 사라지므로 재호출은 no-op(멱등).
    func claimLegacyRows(for userId: String) throws {
        guard !userId.isEmpty else { return }
        try dbQueue.write { db in
            let now = Date()
            for table in ["notes", "note_pages", "feedbacks", "feedback_chats"] {
                try db.execute(
                    sql: "UPDATE \(table) SET user_id = ?, dirty = 1, updated_at = ? WHERE user_id = ''",
                    arguments: [userId, now]
                )
            }
        }
    }

    // MARK: - Notes

    func allNotes() throws -> [Note] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try Note
                .filter(Note.Columns.userId == uid && Note.Columns.deleted == false)
                .order(Note.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    func note(id: String) throws -> Note? {
        guard let uid = scopedUserId else { return nil }
        return try dbQueue.read { db in
            try Note
                .filter(Note.Columns.id == id && Note.Columns.userId == uid && Note.Columns.deleted == false)
                .fetchOne(db)
        }
    }

    func saveNote(_ note: inout Note) throws {
        let uid = try requireUserId()
        note.userId = uid
        note.updatedAt = Date()
        note.dirty = true
        note.drawingHash = DrawingHash.hash(for: note.drawingData)
        let toSave = note
        try dbQueue.write { db in
            var n = toSave
            try n.save(db)
        }
        notifyWrite()
    }

    func deleteNote(id: String) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            let now = Date()
            // cascade soft delete: chats → feedbacks → pages → note (tombstone)
            try db.execute(
                sql: """
                    UPDATE feedback_chats SET deleted = 1, dirty = 1, updated_at = ?
                    WHERE user_id = ? AND feedback_id IN (
                        SELECT id FROM feedbacks WHERE note_id = ? AND user_id = ?
                    )
                    """,
                arguments: [now, uid, id, uid]
            )
            try db.execute(
                sql: "UPDATE feedbacks SET deleted = 1, dirty = 1, updated_at = ? WHERE note_id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
            try db.execute(
                sql: "UPDATE note_pages SET deleted = 1, dirty = 1, updated_at = ? WHERE note_id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
            try db.execute(
                sql: "UPDATE notes SET deleted = 1, dirty = 1, updated_at = ? WHERE id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
        }
        notifyWrite()
    }

    func updateDrawingData(noteId: String, data: Data) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET drawing_data = ?, drawing_hash = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [data, DrawingHash.hash(for: data), Date(), noteId, uid]
            )
        }
        notifyWrite()
    }

    func updateLastPage(noteId: String, page: Int) throws {
        guard page >= 1 && page <= 10000 else { return }
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET last_page = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [page, Date(), noteId, uid]
            )
        }
        notifyWrite()
    }

    func updatePdfOpen(noteId: String, open: Bool) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET pdf_open = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [open, Date(), noteId, uid]
            )
        }
        notifyWrite()
    }

    func linkTextbook(noteId: String, textbookId: String, name: String, pages: Int) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET textbook_id = ?, textbook_name = ?, textbook_pages = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [textbookId, name, pages, Date(), noteId, uid]
            )
        }
        notifyWrite()
    }

    // MARK: - Feedbacks

    func feedbacks(noteId: String) throws -> [FeedbackRecord] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try FeedbackRecord
                .filter(FeedbackRecord.Columns.noteId == noteId
                        && FeedbackRecord.Columns.userId == uid
                        && FeedbackRecord.Columns.deleted == false)
                .order(FeedbackRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func saveFeedback(_ feedback: inout FeedbackRecord) throws {
        let uid = try requireUserId()
        feedback.userId = uid
        feedback.updatedAt = Date()
        feedback.dirty = true
        let toSave = feedback
        try dbQueue.write { db in
            var f = toSave
            try f.save(db)
        }
        notifyWrite()
    }

    func deleteFeedback(id: String) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            let now = Date()
            try db.execute(
                sql: "UPDATE feedback_chats SET deleted = 1, dirty = 1, updated_at = ? WHERE feedback_id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
            try db.execute(
                sql: "UPDATE feedbacks SET deleted = 1, dirty = 1, updated_at = ? WHERE id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
        }
        notifyWrite()
    }

    func updateFeedbackRating(id: String, rating: Int?, syncedAt: Date?) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE feedbacks SET user_rating = ?, user_rating_synced_at = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [rating, syncedAt, Date(), id, uid]
            )
        }
        notifyWrite()
    }

    // MARK: - PDF Drawings (휴면 테이블 — sync 제외, §1.2)

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
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try NotePage
                .filter(NotePage.Columns.noteId == noteId
                        && NotePage.Columns.userId == uid
                        && NotePage.Columns.deleted == false)
                .order(NotePage.Columns.pageIndex.asc)
                .fetchAll(db)
        }
    }

    func page(noteId: String, pageIndex: Int) throws -> NotePage? {
        guard let uid = scopedUserId else { return nil }
        return try dbQueue.read { db in
            try NotePage
                .filter(NotePage.Columns.noteId == noteId
                        && NotePage.Columns.pageIndex == pageIndex
                        && NotePage.Columns.userId == uid
                        && NotePage.Columns.deleted == false)
                .fetchOne(db)
        }
    }

    func createPage(noteId: String, pageIndex: Int) throws -> NotePage {
        let uid = try requireUserId()
        var page = NotePage(
            id: UUID().uuidString,
            noteId: noteId,
            pageIndex: pageIndex,
            drawingData: nil,
            createdAt: Date(),
            userId: uid,
            updatedAt: Date(),
            dirty: true
        )
        try dbQueue.write { db in
            try page.save(db)
        }
        notifyWrite()
        return page
    }

    func savePageDrawing(pageId: String, data: Data) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note_pages SET drawing_data = ?, drawing_hash = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [data, DrawingHash.hash(for: data), Date(), pageId, uid]
            )
        }
        notifyWrite()
    }

    func updateCurrentPageIndex(noteId: String, index: Int) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET current_page_index = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [index, Date(), noteId, uid]
            )
        }
        notifyWrite()
    }

    func feedbacks(pageId: String) throws -> [FeedbackRecord] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try FeedbackRecord
                .filter(sql: "page_id = ? AND user_id = ? AND deleted = 0", arguments: [pageId, uid])
                .order(FeedbackRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    // MARK: - Feedback Chats

    func chatMessages(feedbackId: String) throws -> [ChatMessageRecord] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try ChatMessageRecord
                .filter(ChatMessageRecord.Columns.feedbackId == feedbackId
                        && ChatMessageRecord.Columns.userId == uid
                        && ChatMessageRecord.Columns.deleted == false)
                .order(ChatMessageRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func saveChatMessage(_ msg: inout ChatMessageRecord) throws {
        let uid = try requireUserId()
        msg.userId = uid
        msg.updatedAt = Date()
        msg.dirty = true
        let toSave = msg
        try dbQueue.write { db in
            var m = toSave
            try m.save(db)
        }
        notifyWrite()
    }

    func updateChatMessageRating(id: String, rating: Int, syncedAt: Date?) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE feedback_chats SET user_rating = ?, user_rating_synced_at = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [rating, syncedAt, Date(), id, uid]
            )
        }
        notifyWrite()
    }
}
