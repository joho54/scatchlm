import Foundation
import GRDB
import WidgetKit

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

        // v8: 챕터 채팅 드로어 (chapter-chat-drawer-spec §4.1).
        // 캔버스 비종속 chat_session 테이블 신설 + feedback_chats/feedbacks에 session_id 추가.
        // 기존 feedback_chats를 feedback_id로 그룹핑해 kind=feedback 세션으로 백필한다.
        // 세션 id는 feedback_id 기반 **결정적**("sess_"+feedback_id)으로 생성해 멀티디바이스
        // 독립 백필이 같은 행으로 머지되도록 한다(§7 R1).
        migrator.registerMigration("v8_chat_sessions") { db in
            try db.create(table: "chat_sessions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("note_id", .text)
                t.column("textbook_id", .text)
                t.column("anchor_page", .integer)
                t.column("chapter_title", .text)
                t.column("source_feedback_id", .text)
                t.column("created_at", .datetime).notNull()
                // sync 메타 (v7과 동일 패턴)
                t.column("user_id", .text).notNull().defaults(to: "")
                t.column("updated_at", .datetime).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "ix_chat_sessions_user_updated", on: "chat_sessions",
                          columns: ["user_id", "updated_at"], ifNotExists: true)

            // session_id 컬럼 추가. feedback_chats는 notNull(빈 sentinel) — 모든 기존 행은
            // 아래 백필이 실제 세션으로 덮는다. feedbacks는 nullable(레거시 단독 카드 = null).
            try db.alter(table: "feedback_chats") { t in
                t.add(column: "session_id", .text).notNull().defaults(to: "")
            }
            try db.alter(table: "feedbacks") { t in
                t.add(column: "session_id", .text)
            }

            // 백필: feedback_chats를 feedback_id로 그룹핑 → 그룹마다 kind=feedback 세션 1개.
            let feedbackIds = try String.fetchAll(
                db, sql: "SELECT DISTINCT feedback_id FROM feedback_chats WHERE feedback_id IS NOT NULL"
            )
            for feedbackId in feedbackIds {
                let sessionId = "sess_" + feedbackId
                guard let parent = try Row.fetchOne(
                    db,
                    sql: "SELECT note_id, server_feedback_id, user_id, created_at FROM feedbacks WHERE id = ?",
                    arguments: [feedbackId]
                ) else { continue }
                let noteId: String? = parent["note_id"]
                let sourceFeedbackId: String? = parent["server_feedback_id"]
                let userId: String = parent["user_id"] ?? ""
                let createdAt: Date = parent["created_at"] ?? Date()
                // 제목 = 그룹 첫 user 메시지, 없으면 폴백.
                let firstUserMsg = try String.fetchOne(
                    db,
                    sql: "SELECT content FROM feedback_chats WHERE feedback_id = ? AND role = 'user' ORDER BY created_at ASC LIMIT 1",
                    arguments: [feedbackId]
                )
                let title = firstUserMsg ?? "피드백 대화"
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO chat_sessions
                        (id, kind, title, note_id, textbook_id, anchor_page, chapter_title,
                         source_feedback_id, created_at, user_id, updated_at, deleted, dirty)
                        VALUES (?, 'feedback', ?, ?, NULL, NULL, NULL, ?, ?, ?, ?, 0, 1)
                        """,
                    arguments: [sessionId, title, noteId, sourceFeedbackId, createdAt, userId, createdAt]
                )
                // 메시지 → 세션 연결, 부모 카드 → placement 연결. 둘 다 dirty=1로 재push.
                try db.execute(
                    sql: "UPDATE feedback_chats SET session_id = ?, dirty = 1 WHERE feedback_id = ?",
                    arguments: [sessionId, feedbackId]
                )
                try db.execute(
                    sql: "UPDATE feedbacks SET session_id = ?, dirty = 1 WHERE id = ?",
                    arguments: [sessionId, feedbackId]
                )
            }
        }

        // v9: PDF 페이지 필기 오버레이 (pdf-annotation 필기 전용).
        // 노트 종속(note_id) + PDF 페이지 번호(pdf_page) 키. note_pages와 동일한 sync 메타.
        // drawing blob은 기존 content-addressed blob 채널(drawing_hash)로 동기화한다.
        migrator.registerMigration("v9_pdf_annotations") { db in
            try db.create(table: "pdf_annotations", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).notNull().references("notes", onDelete: .cascade)
                t.column("pdf_page", .integer).notNull()
                t.column("drawing_data", .blob)
                t.column("created_at", .datetime).notNull()
                // sync 메타 (v7 패턴)
                t.column("user_id", .text).notNull().defaults(to: "")
                t.column("drawing_hash", .text)
                t.column("updated_at", .datetime).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.uniqueKey(["note_id", "pdf_page"])
            }
            try db.create(index: "ix_pdf_annotations_user_updated", on: "pdf_annotations",
                          columns: ["user_id", "updated_at"], ifNotExists: true)
        }

        // v10: 노트 폴더 정리 (note-folders-spec §4.2).
        // 플랫(단일 레벨) folders 테이블 + notes.folder_id(NULL=미분류). 기존 노트는
        // folder_id NULL로 자연 호환. sync 메타는 v7/v8 패턴과 동일.
        migrator.registerMigration("v10_note_folders") { db in
            try db.create(table: "folders", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                // sync 메타 (v7 패턴)
                t.column("user_id", .text).notNull().defaults(to: "")
                t.column("updated_at", .datetime).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "ix_folders_user_updated", on: "folders",
                          columns: ["user_id", "updated_at"], ifNotExists: true)
            try db.alter(table: "notes") { t in
                t.add(column: "folder_id", .text)
            }
            try db.create(index: "idx_notes_folder_id", on: "notes",
                          columns: ["folder_id"], ifNotExists: true)
        }

        // v11: feedback_chats.feedback_id NOT NULL 제약 해제 (chapter-chat-drawer 버그픽스).
        // v2에서 feedback_id를 notNull+FK로 만들었는데, 세션 도입으로 가이드/피드백 메시지는
        // feedback_id=nil로 저장된다. SQLite는 ALTER COLUMN으로 NOT NULL을 못 떼므로
        // 테이블을 재생성한다(12-step). GRDB 마이그레이터는 기본 deferred FK check라 안전.
        // (이걸 안 하면 모든 신규 세션 메시지 INSERT가 NOT NULL 위반으로 실패 → 채팅 저장 안 됨.)
        migrator.registerMigration("v11_feedback_chats_nullable_feedback_id") { db in
            try db.create(table: "feedback_chats_new") { t in
                t.column("id", .text).primaryKey()
                t.column("feedback_id", .text)            // nullable (FK 제거 — 앱 레벨 soft FK)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("server_message_id", .text)
                t.column("user_rating", .integer)
                t.column("user_rating_synced_at", .datetime)
                t.column("user_id", .text).notNull().defaults(to: "")
                t.column("updated_at", .datetime)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("session_id", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: """
                INSERT INTO feedback_chats_new
                    (id, feedback_id, role, content, created_at, server_message_id,
                     user_rating, user_rating_synced_at, user_id, updated_at, deleted, dirty, session_id)
                SELECT id, feedback_id, role, content, created_at, server_message_id,
                       user_rating, user_rating_synced_at, user_id, updated_at, deleted, dirty, session_id
                FROM feedback_chats
                """)
            try db.drop(table: "feedback_chats")
            try db.rename(table: "feedback_chats_new", to: "feedback_chats")
        }

        // v12: notes.template — 캔버스 배경 템플릿(NoteTemplate.rawValue). 기존 노트는 "blank"로
        // 자연 호환. sync 필드(folder_id 패턴)와 동일하게 push/pull은 ENTITY_FIELDS로 자동 처리.
        migrator.registerMigration("v12_note_template") { db in
            try db.alter(table: "notes") { t in
                t.add(column: "template", .text).notNull().defaults(to: "blank")
            }
        }

        // v13: 휴지통 영구삭제 큐. 영구삭제 시 노트를 로컬 하드 삭제하되, 서버에도 하드
        // 삭제(POST /api/sync/purge)를 전파하기 위해 id를 큐에 적재한다. sync 사이클이
        // pull 직전에 비워(서버 행 제거 → full-pull 부활 방지). soft delete(deleted=1)와 별개.
        migrator.registerMigration("v13_purge_queue") { db in
            try db.create(table: "purge_queue", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()        // note id
                t.column("user_id", .text).notNull().defaults(to: "")
            }
        }

        // DMN 휴식 타이머 인출 단서. feedback/chat 응답의 keywords를 노트 scope로 모아둔다.
        // 로컬 전용(sync 안 함) — 휴식용 ephemeral 단서라 기기 간 이력 동기화 불필요, 새 응답이 곧 채운다.
        migrator.registerMigration("v14_dmn_cues") { db in
            try db.create(table: "dmn_cues", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).notNull().indexed()
                t.column("keyword", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "feedback")  // feedback | chat
                t.column("user_id", .text).notNull().defaults(to: "")
                t.column("created_at", .datetime).notNull()
            }
        }

        // DMN 단서에 세션 링크 추가 — 위젯에서 단서 탭 시 해당 세션 시트로 점프하기 위함.
        // nullable: 레거시 단서/세션 없는 적재는 nil(점프 불가, 노트로 폴백).
        migrator.registerMigration("v15_dmn_cue_session") { db in
            try db.alter(table: "dmn_cues") { t in
                t.add(column: "session_id", .text)
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - 계정 삭제용 하드 purge (L1 / D-1)

    /// 계정 삭제 시 로컬 전 테이블 행을 **하드 삭제**한다(sync 소프트삭제와 별개).
    /// sync 대상 4테이블은 user_id로 스코프, pdf_drawings는 user 스코프가 없어 전체 삭제.
    func purgeAllData(userId: String) throws {
        guard !userId.isEmpty else { return }
        try dbQueue.write { db in
            for table in ["dmn_cues", "feedback_chats", "feedbacks", "pdf_annotations", "note_pages", "notes", "folders", "purge_queue"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE user_id = ?", arguments: [userId])
            }
            // pdf_drawings는 user 스코프 컬럼이 없음 — 디바이스 로컬 전체 삭제.
            try db.execute(sql: "DELETE FROM pdf_drawings")
        }
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

    // MARK: - Folders (note-folders-spec §4.1 / B-2)

    /// 현재 유저의 폴더 목록(미삭제). sort_order 오름차순, 동률은 생성순.
    func allFolders() throws -> [Folder] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try Folder
                .filter(Folder.Columns.userId == uid && Folder.Columns.deleted == false)
                .order(Folder.Columns.sortOrder.asc, Folder.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func saveFolder(_ folder: inout Folder) throws {
        let uid = try requireUserId()
        folder.userId = uid
        folder.updatedAt = Date()
        folder.dirty = true
        let toSave = folder
        try dbQueue.write { db in
            var f = toSave
            try f.save(db)
        }
        notifyWrite()
    }

    /// 폴더 soft delete + 안의 노트를 재귀적으로 휴지통(soft delete)으로 이동.
    /// 노트의 페이지·피드백·채팅도 함께 tombstone(deleteNote와 동일 cascade).
    /// 노트는 휴지통에서 복구/영구삭제할 수 있다(노트 유실 방지). 빈 폴더면 폴더만 삭제.
    func deleteFolder(id: String) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            let now = Date()
            // cascade: chats → feedbacks → pages → notes (해당 폴더 소속), 그다음 folder
            try db.execute(
                sql: """
                    UPDATE feedback_chats SET deleted = 1, dirty = 1, updated_at = ?
                    WHERE user_id = ? AND feedback_id IN (
                        SELECT id FROM feedbacks WHERE user_id = ? AND note_id IN (
                            SELECT id FROM notes WHERE folder_id = ? AND user_id = ?
                        )
                    )
                    """,
                arguments: [now, uid, uid, id, uid]
            )
            try db.execute(
                sql: """
                    UPDATE feedbacks SET deleted = 1, dirty = 1, updated_at = ?
                    WHERE user_id = ? AND note_id IN (
                        SELECT id FROM notes WHERE folder_id = ? AND user_id = ?
                    )
                    """,
                arguments: [now, uid, id, uid]
            )
            try db.execute(
                sql: """
                    UPDATE note_pages SET deleted = 1, dirty = 1, updated_at = ?
                    WHERE user_id = ? AND note_id IN (
                        SELECT id FROM notes WHERE folder_id = ? AND user_id = ?
                    )
                    """,
                arguments: [now, uid, id, uid]
            )
            try db.execute(
                sql: "UPDATE notes SET deleted = 1, dirty = 1, updated_at = ? WHERE folder_id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
            try db.execute(
                sql: "UPDATE folders SET deleted = 1, dirty = 1, updated_at = ? WHERE id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
        }
        notifyWrite()
    }

    /// 노트를 폴더로 이동(folderId=nil이면 전체로). note dirty 경로로 자동 동기화.
    func moveNote(id: String, toFolder folderId: String?) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET folder_id = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ?",
                arguments: [folderId, Date(), id, uid]
            )
        }
        notifyWrite()
    }

    // MARK: - Trash (휴지통 — soft delete된 노트 복구/영구삭제)

    /// 휴지통: soft delete(deleted=1)된 노트. 최근 삭제순.
    func trashedNotes() throws -> [Note] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try Note
                .filter(Note.Columns.userId == uid && Note.Columns.deleted == true)
                .order(Note.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    /// 휴지통 → 복구. 노트와 그 페이지·피드백·채팅의 tombstone을 해제(deleted=0, dirty=1).
    /// updated_at을 now로 올려 LWW로 서버 tombstone을 덮어 un-delete가 전파되게 한다.
    /// (폴더가 이미 사라졌다면 folder_id가 dangling → UI는 "전체"로 폴백 렌더, §7 R1.)
    func restoreNote(id: String) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            let now = Date()
            try db.execute(
                sql: """
                    UPDATE feedback_chats SET deleted = 0, dirty = 1, updated_at = ?
                    WHERE user_id = ? AND feedback_id IN (
                        SELECT id FROM feedbacks WHERE note_id = ? AND user_id = ?
                    )
                    """,
                arguments: [now, uid, id, uid]
            )
            try db.execute(
                sql: "UPDATE feedbacks SET deleted = 0, dirty = 1, updated_at = ? WHERE note_id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
            try db.execute(
                sql: "UPDATE note_pages SET deleted = 0, dirty = 1, updated_at = ? WHERE note_id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
            try db.execute(
                sql: "UPDATE notes SET deleted = 0, dirty = 1, updated_at = ? WHERE id = ? AND user_id = ?",
                arguments: [now, id, uid]
            )
        }
        notifyWrite()
    }

    /// 영구 삭제 — 로컬 하드 삭제(노트 + 페이지/피드백/채팅/PDF 필기) + 서버 purge 큐 적재.
    /// 복구 불가. 큐에 적재된 id는 다음 sync 사이클이 `POST /api/sync/purge`로 서버 행까지
    /// 하드 삭제해(pull 직전) tombstone 부활을 막는다(`SyncService.flushPurges`).
    func permanentlyDeleteNote(id: String) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            // 서버 하드 삭제 전파용 큐에 먼저 적재(로컬 행을 지운 뒤엔 user_id를 모르므로 순서 중요).
            try db.execute(
                sql: "INSERT OR IGNORE INTO purge_queue (id, user_id) VALUES (?, ?)",
                arguments: [id, uid]
            )
            try db.execute(
                sql: """
                    DELETE FROM feedback_chats WHERE user_id = ? AND feedback_id IN (
                        SELECT id FROM feedbacks WHERE note_id = ? AND user_id = ?
                    )
                    """,
                arguments: [uid, id, uid]
            )
            try db.execute(sql: "DELETE FROM feedbacks WHERE note_id = ? AND user_id = ?", arguments: [id, uid])
            try db.execute(sql: "DELETE FROM note_pages WHERE note_id = ? AND user_id = ?", arguments: [id, uid])
            try db.execute(sql: "DELETE FROM pdf_annotations WHERE note_id = ? AND user_id = ?", arguments: [id, uid])
            try db.execute(sql: "DELETE FROM notes WHERE id = ? AND user_id = ?", arguments: [id, uid])
        }
        // 서버 purge를 즉시 시도하도록 sync 트리거(오프라인이면 큐에 남아 다음 사이클에 재시도).
        notifyWrite()
    }

    /// 휴지통 비우기 — 모든 soft-deleted 노트를 영구 삭제.
    func emptyTrash() throws {
        let ids = try trashedNotes().map(\.id)
        for nid in ids {
            try permanentlyDeleteNote(id: nid)
        }
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

    /// 세션에 연결된 피드백 카드 1건. 위젯 딥링크로 세션 시트를 루트에서 열 때 원본 피드백
    /// 본문(headerContent)을 복원하는 데 쓴다. NoteView 밖이라 카드 메모리 배열이 없기 때문.
    func feedbackForSession(_ sessionId: String) -> FeedbackRecord? {
        guard let uid = scopedUserId else { return nil }
        return try? dbQueue.read { db in
            try FeedbackRecord
                .filter(FeedbackRecord.Columns.sessionId == sessionId
                        && FeedbackRecord.Columns.userId == uid
                        && FeedbackRecord.Columns.deleted == false)
                .order(FeedbackRecord.Columns.createdAt.asc)
                .fetchOne(db)
        }
    }

    /// 최신 피드백 N개. DMN 타이머 단어 추출용 — skip 센티넬·빈 본문은 제외.
    /// `noteId`가 주어지면 그 노트로 한정(DMN은 "지금 이 노트" 맥락 앵커가 핵심), nil이면 전역.
    func recentFeedbacks(noteId: String? = nil, limit: Int = 10) throws -> [FeedbackRecord] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            var query = FeedbackRecord
                .filter(FeedbackRecord.Columns.userId == uid
                        && FeedbackRecord.Columns.deleted == false
                        && FeedbackRecord.Columns.content != FeedbackRecord.skipSentinel
                        && FeedbackRecord.Columns.content != "")
            if let noteId {
                query = query.filter(FeedbackRecord.Columns.noteId == noteId)
            }
            return try query
                .order(FeedbackRecord.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - DMN 단서 (인출 단서, 로컬 전용)

    /// feedback/chat 응답의 keywords를 노트 scope 단서로 적재한다. 빈 배열·공백은 건너뛴다.
    /// `sessionId`가 있으면 단서에 세션을 링크해 위젯에서 해당 세션 시트로 점프할 수 있게 한다.
    func insertDMNCues(noteId: String, keywords: [String], source: String, sessionId: String? = nil) throws {
        guard let uid = scopedUserId else { return }
        let cleaned = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let now = Date()
        try dbQueue.write { db in
            for kw in cleaned {
                var cue = DMNCue(id: UUID().uuidString, noteId: noteId, keyword: kw,
                                 source: source, sessionId: sessionId, userId: uid, createdAt: now)
                try cue.insert(db)
            }
        }
        // 위젯 공유 스냅샷 갱신 — 새 단서가 홈화면 위젯에 즉시 반영되도록.
        refreshWidgetCues()
    }

    /// 위젯 표시용 최근 단서 — **사용자 scope 전체**(노트 무관), 최신·중복제거·길이필터.
    /// 노트별 DMN 타이머(`recentDMNCues`)와 달리 위젯은 "최근 공부한 내용" 전반을 보여준다.
    func recentCuesForWidget(limit: Int = 8) -> [WidgetCue] {
        guard let uid = scopedUserId else { return [] }
        let cues = (try? dbQueue.read { db in
            try DMNCue
                .filter(DMNCue.Columns.userId == uid)
                .order(DMNCue.Columns.createdAt.desc)
                .limit(limit * 4)   // 길이/중복 필터 여유분
                .fetchAll(db)
        }) ?? []
        var seen = Set<String>()
        var out: [WidgetCue] = []
        for c in cues {
            let kw = c.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard kw.count <= Self.dmnCueMaxLen else { continue }
            guard seen.insert(kw.lowercased()).inserted else { continue }
            out.append(WidgetCue(id: c.id, keyword: kw, sessionId: c.sessionId,
                                 noteId: c.noteId, createdAt: c.createdAt))
            if out.count >= limit { break }
        }
        return out
    }

    /// 최근 단서 스냅샷을 App Group에 쓰고 위젯 타임라인을 새로고침한다.
    func refreshWidgetCues() {
        let cues = recentCuesForWidget()
        WidgetShared.writeCues(cues)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// DMN 단서 표시 상한 길이 — 휴식 중 흘끗 보는 인출 단서라 한 문장/구절은 부적합.
    /// LLM 프롬프트로 짧은 단일 개념어를 유도하지만(1차), 안 지킬 때 표시 단에서 거른다(2차 방어).
    static let dmnCueMaxLen = 10

    /// 노트 scope 최신 단서 N개(중복 제거, 최신 우선, 길이 초과 제외). DMN 타이머용.
    func recentDMNCues(noteId: String, limit: Int = 12) throws -> [String] {
        guard let uid = scopedUserId else { return [] }
        let cues = try dbQueue.read { db in
            try DMNCue
                .filter(DMNCue.Columns.userId == uid && DMNCue.Columns.noteId == noteId)
                .order(DMNCue.Columns.createdAt.desc)
                .limit(limit * 4)   // 길이/중복 필터 여유분
                .fetchAll(db)
        }
        var seen = Set<String>()
        var out: [String] = []
        for c in cues {
            let kw = c.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard kw.count <= Self.dmnCueMaxLen else { continue }   // 구절/문장 컷
            if seen.insert(kw.lowercased()).inserted {
                out.append(kw)
                if out.count >= limit { break }
            }
        }
        return out
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

    // MARK: - PDF Annotations (PDF 페이지 위 필기 오버레이, sync 대상)

    /// 노트의 모든 PDF 필기. 페이지별로 조회해 캔버스에 로드한다.
    func pdfAnnotations(noteId: String) throws -> [PdfAnnotation] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try PdfAnnotation
                .filter(PdfAnnotation.Columns.noteId == noteId
                        && PdfAnnotation.Columns.userId == uid
                        && PdfAnnotation.Columns.deleted == false)
                .order(PdfAnnotation.Columns.pdfPage.asc)
                .fetchAll(db)
        }
    }

    /// 특정 PDF 페이지의 필기 1건.
    func pdfAnnotation(noteId: String, page: Int) throws -> PdfAnnotation? {
        guard let uid = scopedUserId else { return nil }
        return try dbQueue.read { db in
            try PdfAnnotation
                .filter(PdfAnnotation.Columns.noteId == noteId
                        && PdfAnnotation.Columns.pdfPage == page
                        && PdfAnnotation.Columns.userId == uid
                        && PdfAnnotation.Columns.deleted == false)
                .fetchOne(db)
        }
    }

    /// (note_id, pdf_page) upsert. 기존 행이 있으면 drawing만 갱신, 없으면 새로 만든다.
    /// 빈 drawing은 호출 전에 거른다(스트로크 있을 때만 저장).
    func savePdfAnnotation(noteId: String, page: Int, data: Data) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            let now = Date()
            let hash = DrawingHash.hash(for: data)
            if let existing = try PdfAnnotation
                .filter(PdfAnnotation.Columns.noteId == noteId
                        && PdfAnnotation.Columns.pdfPage == page
                        && PdfAnnotation.Columns.userId == uid)
                .fetchOne(db) {
                try db.execute(
                    sql: "UPDATE pdf_annotations SET drawing_data = ?, drawing_hash = ?, updated_at = ?, deleted = 0, dirty = 1 WHERE id = ?",
                    arguments: [data, hash, now, existing.id]
                )
            } else {
                var ann = PdfAnnotation(
                    id: UUID().uuidString,
                    noteId: noteId,
                    pdfPage: page,
                    drawingData: data,
                    createdAt: now,
                    userId: uid,
                    drawingHash: hash,
                    updatedAt: now,
                    dirty: true
                )
                try ann.save(db)
            }
        }
        notifyWrite()
    }

    /// 페이지 필기 전체 삭제(지우개로 비웠을 때). soft delete tombstone.
    func deletePdfAnnotation(noteId: String, page: Int) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pdf_annotations SET drawing_data = NULL, drawing_hash = NULL, deleted = 1, dirty = 1, updated_at = ? WHERE note_id = ? AND pdf_page = ? AND user_id = ?",
                arguments: [Date(), noteId, page, uid]
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

    /// 페이지 순서 재정렬. `orderedIds`는 새 표시 순서(0..n-1)의 페이지 id 배열.
    /// UNIQUE(note_id, page_index) 충돌을 피하려 2-pass(임시 큰 값 → 최종값)로 갱신한다.
    func reorderPages(noteId: String, orderedIds: [String]) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            let now = Date()
            for (i, id) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE note_pages SET page_index = ? WHERE id = ? AND note_id = ? AND user_id = ?",
                    arguments: [1_000_000 + i, id, noteId, uid]
                )
            }
            for (i, id) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE note_pages SET page_index = ?, updated_at = ?, dirty = 1 WHERE id = ? AND note_id = ? AND user_id = ?",
                    arguments: [i, now, id, noteId, uid]
                )
            }
        }
        notifyWrite()
    }

    /// 페이지 소프트 삭제 + 남은 페이지 page_index 0..n-1 재압축. 해당 페이지의 피드백·채팅도 cascade 삭제.
    /// `remainingOrderedIds`는 삭제 후 남는 페이지의 표시 순서 id 배열.
    func deletePage(noteId: String, pageId: String, remainingOrderedIds: [String]) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            let now = Date()
            // cascade: chats → feedbacks (해당 페이지)
            try db.execute(
                sql: """
                    UPDATE feedback_chats SET deleted = 1, dirty = 1, updated_at = ?
                    WHERE user_id = ? AND feedback_id IN (
                        SELECT id FROM feedbacks WHERE page_id = ? AND user_id = ?
                    )
                    """,
                arguments: [now, uid, pageId, uid]
            )
            try db.execute(
                sql: "UPDATE feedbacks SET deleted = 1, dirty = 1, updated_at = ? WHERE page_id = ? AND user_id = ?",
                arguments: [now, pageId, uid]
            )
            // 삭제 페이지를 UNIQUE 범위 밖(유니크 음수 slot)으로 옮기며 tombstone 처리.
            // soft-delete된 행도 page_index를 점유하므로 0..n-1과 충돌하지 않게 비운다.
            let minIdx = try Int.fetchOne(
                db,
                sql: "SELECT MIN(page_index) FROM note_pages WHERE note_id = ? AND user_id = ?",
                arguments: [noteId, uid]
            ) ?? 0
            let parking = min(minIdx, 0) - 1
            try db.execute(
                sql: "UPDATE note_pages SET deleted = 1, dirty = 1, updated_at = ?, page_index = ? WHERE id = ? AND note_id = ? AND user_id = ?",
                arguments: [now, parking, pageId, noteId, uid]
            )
            // 남은 페이지 0..n-1 재압축 (2-pass)
            for (i, id) in remainingOrderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE note_pages SET page_index = ? WHERE id = ? AND note_id = ? AND user_id = ?",
                    arguments: [1_000_000 + i, id, noteId, uid]
                )
            }
            for (i, id) in remainingOrderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE note_pages SET page_index = ?, updated_at = ?, dirty = 1 WHERE id = ? AND note_id = ? AND user_id = ?",
                    arguments: [i, now, id, noteId, uid]
                )
            }
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

    /// 채팅 메시지 soft-delete — 전송 실패한 user 메시지를 '수정'으로 입력창에 되돌릴 때
    /// 실패 버블을 제거한다. deleted+dirty로 표시해 sync가 삭제를 전파(messages 쿼리는 deleted=false만 로드).
    func softDeleteChatMessage(id: String) throws {
        let uid = try requireUserId()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE feedback_chats SET deleted = 1, dirty = 1, updated_at = ? WHERE id = ? AND user_id = ?",
                arguments: [Date(), id, uid]
            )
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

    // MARK: - Chat Sessions (chapter-chat-drawer-spec §4.1)

    /// 세션 기반 메시지 로드 (드로어/세션 채팅 일반화 §4.4).
    func messages(sessionId: String) throws -> [ChatMessageRecord] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try ChatMessageRecord
                .filter(ChatMessageRecord.Columns.sessionId == sessionId
                        && ChatMessageRecord.Columns.userId == uid
                        && ChatMessageRecord.Columns.deleted == false)
                .order(ChatMessageRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func session(id: String) throws -> ChatSessionRecord? {
        guard let uid = scopedUserId else { return nil }
        return try dbQueue.read { db in
            try ChatSessionRecord
                .filter(ChatSessionRecord.Columns.id == id
                        && ChatSessionRecord.Columns.userId == uid
                        && ChatSessionRecord.Columns.deleted == false)
                .fetchOne(db)
        }
    }

    /// 드로어용 세션 목록 — **노트 단위 격리**. 이 노트(note_id)에 속한 세션만 보여준다.
    /// 가이드·피드백 세션 모두 생성 시 note_id가 채워지므로(PdfViewerView는 noteId를 주입받음)
    /// note_id 하나로 충분하다. (교재 공유 노트 간 누수 방지 — 이전 textbook_id OR 제거.)
    func sessions(noteId: String) throws -> [ChatSessionRecord] {
        guard let uid = scopedUserId else { return [] }
        return try dbQueue.read { db in
            try ChatSessionRecord
                .filter(ChatSessionRecord.Columns.noteId == noteId
                        && ChatSessionRecord.Columns.userId == uid
                        && ChatSessionRecord.Columns.deleted == false)
                .order(ChatSessionRecord.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    /// 같은 노트·페이지·교재의 가이드 세션을 찾는다(있으면 이어가기, 없으면 새로 생성). §4.6.
    /// note_id까지 스코프해 같은 교재를 쓰는 다른 노트의 가이드 세션과 섞이지 않게 한다.
    func guideSession(kind: ChatSessionRecord.Kind, textbookId: String, anchorPage: Int, noteId: String?) throws -> ChatSessionRecord? {
        guard let uid = scopedUserId else { return nil }
        return try dbQueue.read { db in
            try ChatSessionRecord
                .filter(sql: "user_id = ? AND deleted = 0 AND kind = ? AND textbook_id = ? AND anchor_page = ? AND note_id IS ?",
                        arguments: [uid, kind.rawValue, textbookId, anchorPage, noteId])
                .order(ChatSessionRecord.Columns.updatedAt.desc)
                .fetchOne(db)
        }
    }

    func saveSession(_ session: inout ChatSessionRecord) throws {
        let uid = try requireUserId()
        session.userId = uid
        session.updatedAt = Date()
        session.dirty = true
        let toSave = session
        try dbQueue.write { db in
            var s = toSave
            try s.save(db)
        }
        notifyWrite()
    }

    /// 세션 제목이 비어 있을 때만 첫 user 질문으로 세팅한다 (결정 2 / §4.4).
    func setSessionTitleIfEmpty(sessionId: String, title: String) throws {
        let uid = try requireUserId()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET title = ?, updated_at = ?, dirty = 1 WHERE id = ? AND user_id = ? AND title = ''",
                arguments: [trimmed, Date(), sessionId, uid]
            )
        }
        notifyWrite()
    }

    /// 세션을 가리키는 캔버스 placement(피드백 카드) 중 가장 최근 것. 드로어 "캔버스로 점프"용.
    func placement(sessionId: String) throws -> FeedbackRecord? {
        guard let uid = scopedUserId else { return nil }
        return try dbQueue.read { db in
            try FeedbackRecord
                .filter(sql: "session_id = ? AND user_id = ? AND deleted = 0",
                        arguments: [sessionId, uid])
                .order(FeedbackRecord.Columns.createdAt.desc)
                .fetchOne(db)
        }
    }
}
