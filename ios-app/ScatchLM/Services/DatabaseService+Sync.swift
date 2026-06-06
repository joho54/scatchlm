import Foundation
import GRDB

/// Sync 엔진(Track C)이 사용하는 DatabaseService 확장.
/// - dirty 수집(push 대상), markClean(push 성공 후)
/// - applyPulled*(서버 → 로컬 LWW 머지, dirty=0)
/// - blob 조회(content-addressed)
///
/// 일반 앱 write와 달리 applyPulled*/markClean은 dirty/updated_at을 스스로 통제하며
/// onWrite 훅을 호출하지 않는다(서버발 변경이 다시 push 트리거를 유발하지 않도록).
/// (claimLegacyRows는 본체 DatabaseService에 정의되어 있다.)
extension DatabaseService {

    /// sync 스코프 user_id. 미로그인이면 nil → 수집/머지 no-op.
    private var syncUserId: String? {
        guard let uid = currentUserId, !uid.isEmpty else { return nil }
        return uid
    }

    // MARK: - Dirty 수집 (push 대상, tombstone 포함)

    func dirtyNotes() throws -> [Note] {
        guard let uid = syncUserId else { return [] }
        return try dbQueue.read { db in
            try Note.filter(Note.Columns.userId == uid && Note.Columns.dirty == true).fetchAll(db)
        }
    }

    func dirtyPages() throws -> [NotePage] {
        guard let uid = syncUserId else { return [] }
        return try dbQueue.read { db in
            try NotePage.filter(NotePage.Columns.userId == uid && NotePage.Columns.dirty == true).fetchAll(db)
        }
    }

    func dirtyPdfAnnotations() throws -> [PdfAnnotation] {
        guard let uid = syncUserId else { return [] }
        return try dbQueue.read { db in
            try PdfAnnotation.filter(PdfAnnotation.Columns.userId == uid && PdfAnnotation.Columns.dirty == true).fetchAll(db)
        }
    }

    func dirtyFeedbacks() throws -> [FeedbackRecord] {
        guard let uid = syncUserId else { return [] }
        return try dbQueue.read { db in
            try FeedbackRecord.filter(FeedbackRecord.Columns.userId == uid && FeedbackRecord.Columns.dirty == true).fetchAll(db)
        }
    }

    func dirtyChats() throws -> [ChatMessageRecord] {
        guard let uid = syncUserId else { return [] }
        return try dbQueue.read { db in
            try ChatMessageRecord.filter(ChatMessageRecord.Columns.userId == uid && ChatMessageRecord.Columns.dirty == true).fetchAll(db)
        }
    }

    func dirtySessions() throws -> [ChatSessionRecord] {
        guard let uid = syncUserId else { return [] }
        return try dbQueue.read { db in
            try ChatSessionRecord.filter(ChatSessionRecord.Columns.userId == uid && ChatSessionRecord.Columns.dirty == true).fetchAll(db)
        }
    }

    func dirtyFolders() throws -> [Folder] {
        guard let uid = syncUserId else { return [] }
        return try dbQueue.read { db in
            try Folder.filter(Folder.Columns.userId == uid && Folder.Columns.dirty == true).fetchAll(db)
        }
    }

    func hasDirtyRecords() throws -> Bool {
        try !dirtySessions().isEmpty || !dirtyFolders().isEmpty || !dirtyNotes().isEmpty || !dirtyPages().isEmpty || !dirtyPdfAnnotations().isEmpty || !dirtyFeedbacks().isEmpty || !dirtyChats().isEmpty
    }

    // MARK: - markClean (push applied/conflict 후 dirty 해제)

    func markClean(table: String, ids: [String]) throws {
        guard let uid = syncUserId, !ids.isEmpty else { return }
        try dbQueue.write { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            var args: [DatabaseValueConvertible] = [uid]
            args.append(contentsOf: ids)
            try db.execute(
                sql: "UPDATE \(table) SET dirty = 0 WHERE user_id = ? AND id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - applyPulled (서버 → 로컬 LWW 머지)

    /// LWW: 로컬에 같은 id가 있고 그 updated_at이 incoming 이상이면 머지하지 않는다(로컬 우선·멱등).
    private func shouldApply(_ db: Database, table: String, id: String, incoming: Date, uid: String) throws -> Bool {
        if let local = try Date.fetchOne(db, sql: "SELECT updated_at FROM \(table) WHERE id = ? AND user_id = ?", arguments: [id, uid]) {
            return incoming > local
        }
        return true
    }

    @discardableResult
    func applyPulledNote(_ incoming: Note) throws -> Bool {
        guard let uid = syncUserId else { return false }
        return try dbQueue.write { db in
            guard try shouldApply(db, table: "notes", id: incoming.id, incoming: incoming.updatedAt, uid: uid) else { return false }
            var n = incoming
            n.userId = uid
            n.dirty = false
            try n.save(db)
            return true
        }
    }

    @discardableResult
    func applyPulledPage(_ incoming: NotePage) throws -> Bool {
        guard let uid = syncUserId else { return false }
        return try dbQueue.write { db in
            guard try shouldApply(db, table: "note_pages", id: incoming.id, incoming: incoming.updatedAt, uid: uid) else { return false }
            var p = incoming
            p.userId = uid
            p.dirty = false
            try p.save(db)
            return true
        }
    }

    @discardableResult
    func applyPulledPdfAnnotation(_ incoming: PdfAnnotation) throws -> Bool {
        guard let uid = syncUserId else { return false }
        return try dbQueue.write { db in
            guard try shouldApply(db, table: "pdf_annotations", id: incoming.id, incoming: incoming.updatedAt, uid: uid) else { return false }
            var a = incoming
            a.userId = uid
            a.dirty = false
            try a.save(db)
            return true
        }
    }

    @discardableResult
    func applyPulledFeedback(_ incoming: FeedbackRecord) throws -> Bool {
        guard let uid = syncUserId else { return false }
        return try dbQueue.write { db in
            guard try shouldApply(db, table: "feedbacks", id: incoming.id, incoming: incoming.updatedAt, uid: uid) else { return false }
            var f = incoming
            f.userId = uid
            f.dirty = false
            try f.save(db)
            return true
        }
    }

    @discardableResult
    func applyPulledSession(_ incoming: ChatSessionRecord) throws -> Bool {
        guard let uid = syncUserId else { return false }
        return try dbQueue.write { db in
            guard try shouldApply(db, table: "chat_sessions", id: incoming.id, incoming: incoming.updatedAt, uid: uid) else { return false }
            var s = incoming
            s.userId = uid
            s.dirty = false
            try s.save(db)
            return true
        }
    }

    @discardableResult
    func applyPulledFolder(_ incoming: Folder) throws -> Bool {
        guard let uid = syncUserId else { return false }
        return try dbQueue.write { db in
            guard try shouldApply(db, table: "folders", id: incoming.id, incoming: incoming.updatedAt, uid: uid) else { return false }
            var f = incoming
            f.userId = uid
            f.dirty = false
            try f.save(db)
            return true
        }
    }

    @discardableResult
    func applyPulledChat(_ incoming: ChatMessageRecord) throws -> Bool {
        guard let uid = syncUserId else { return false }
        return try dbQueue.write { db in
            guard try shouldApply(db, table: "feedback_chats", id: incoming.id, incoming: incoming.updatedAt, uid: uid) else { return false }
            var c = incoming
            c.userId = uid
            c.dirty = false
            try c.save(db)
            return true
        }
    }

    // MARK: - Blob (content-addressed)

    /// 로컬에 보유한 hash의 drawing blob을 찾는다(note_pages 우선, 없으면 notes).
    /// push 시 missing_blob 업로드 소스, pull 시 중복 다운로드 회피에 사용.
    func blobData(forHash hash: String) throws -> Data? {
        guard let uid = syncUserId else { return nil }
        return try dbQueue.read { db in
            if let d = try Data.fetchOne(db, sql: "SELECT drawing_data FROM note_pages WHERE drawing_hash = ? AND user_id = ? AND drawing_data IS NOT NULL LIMIT 1", arguments: [hash, uid]) {
                return d
            }
            if let d = try Data.fetchOne(db, sql: "SELECT drawing_data FROM pdf_annotations WHERE drawing_hash = ? AND user_id = ? AND drawing_data IS NOT NULL LIMIT 1", arguments: [hash, uid]) {
                return d
            }
            return try Data.fetchOne(db, sql: "SELECT drawing_data FROM notes WHERE drawing_hash = ? AND user_id = ? AND drawing_data IS NOT NULL LIMIT 1", arguments: [hash, uid])
        }
    }
}
