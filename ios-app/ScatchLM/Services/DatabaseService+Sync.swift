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

    /// 부모 행이 로컬에 존재하는지. pull 적용 시 자식(feedback/chat/page/annotation)의 FK 부모가
    /// 없으면 INSERT가 FK 위반으로 throw → merge 전체가 죽고 커서가 안 넘어가 sync가 brick된다.
    /// (서버 orphan: purge로 부모만 하드삭제된 잔해 등.) 부모 없으면 그 행만 skip해 sync를 지킨다.
    private func rowExists(_ db: Database, table: String, id: String) throws -> Bool {
        (try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)", arguments: [id])) ?? false
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

    /// 페이지 pull 머지. **배치 단위 2-pass**로 적용한다.
    /// note_pages에는 `UNIQUE(note_id, page_index)`가 걸려 있는데, sync는 id 기준 LWW라
    /// 인덱스가 행들 사이에서 재배치되는 배치(reorder/삽입/삭제압축 전파)를 한 행씩 save하면
    /// 중간 상태가 유니크를 위반해 `SQLite error 19`로 merge 전체가 throw → 커서 미전진 →
    /// 같은 배치 재pull → **sync brick**이 된다. 로컬 reorder가 임시 슬롯 2-pass로 충돌을
    /// 피하는 것과 대칭으로, pull 적용에도 같은 보호를 적용한다.
    /// 1) 적용 대상을 임시 슬롯(>= 2,000,000)에 적재해 실제 슬롯을 모두 비우고,
    /// 2) 서버 인덱스(최종값)로 이동한다. 배치 밖 로컬 행이 슬롯을 점유한 진짜 충돌이면
    ///    점유 행을 말미로 밀어내(reposition을 dirty로 전파) 데이터·brick 없이 수렴시킨다.
    /// 반환값: 실제 적용된(또는 갱신된) 페이지 수.
    @discardableResult
    func applyPulledPages(_ incoming: [NotePage]) throws -> Int {
        guard let uid = syncUserId, !incoming.isEmpty else { return 0 }
        return try dbQueue.write { db in
            // 1) 적용 대상 선별: 부모 note 존재 + LWW 통과
            var toApply: [NotePage] = []
            for var p in incoming {
                guard try rowExists(db, table: "notes", id: p.noteId) else {
                    appLogWarn("sync", "skip orphan page (parent note absent)",
                               ["pageId": p.id, "noteId": p.noteId])
                    continue
                }
                guard try shouldApply(db, table: "note_pages", id: p.id, incoming: p.updatedAt, uid: uid) else { continue }
                p.userId = uid
                p.dirty = false
                toApply.append(p)
            }
            guard !toApply.isEmpty else { return 0 }

            // 2) 1-pass: 임시 슬롯으로 적재(로컬 reorder의 1,000,000 범위와도 겹치지 않게 2,000,000부터).
            //    INSERT/UPDATE(upsert)로 실제 슬롯을 모두 비워 swap/cycle 충돌을 제거한다.
            for (i, p) in toApply.enumerated() {
                var tmp = p
                tmp.pageIndex = 2_000_000 + i
                try tmp.save(db)
            }

            // 3) 2-pass: 서버 인덱스로 이동. 진짜 슬롯 충돌은 점유 행을 말미로 밀어내고 재시도.
            let now = Date()
            for p in toApply {
                do {
                    try db.execute(
                        sql: "UPDATE note_pages SET page_index = ? WHERE id = ? AND user_id = ?",
                        arguments: [p.pageIndex, p.id, uid]
                    )
                } catch let dbErr as DatabaseError where dbErr.resultCode == .SQLITE_CONSTRAINT {
                    try displaceOccupant(db, noteId: p.noteId, slot: p.pageIndex, keepId: p.id, uid: uid, now: now)
                    do {
                        try db.execute(
                            sql: "UPDATE note_pages SET page_index = ? WHERE id = ? AND user_id = ?",
                            arguments: [p.pageIndex, p.id, uid]
                        )
                    } catch {
                        // 최후 안전망: 충돌이 끝내 안 풀리면 말미에 붙여 brick·유실을 막는다.
                        let tail = try nextTailIndex(db, noteId: p.noteId, uid: uid)
                        appLogError("sync", "page slot conflict unresolved; appended to tail",
                                    ["pageId": p.id, "noteId": p.noteId, "wantedIndex": p.pageIndex, "tail": tail])
                        try db.execute(
                            sql: "UPDATE note_pages SET page_index = ?, dirty = 1, updated_at = ? WHERE id = ? AND user_id = ?",
                            arguments: [tail, now, p.id, uid]
                        )
                    }
                }
            }
            return toApply.count
        }
    }

    /// 슬롯을 점유한 다른 id의 로컬 행을 말미로 밀어내고 reposition을 dirty로 전파한다.
    private func displaceOccupant(_ db: Database, noteId: String, slot: Int, keepId: String, uid: String, now: Date) throws {
        guard let occId = try String.fetchOne(
            db,
            sql: "SELECT id FROM note_pages WHERE note_id = ? AND user_id = ? AND page_index = ? AND id <> ? LIMIT 1",
            arguments: [noteId, uid, slot, keepId]
        ) else { return }
        let tail = try nextTailIndex(db, noteId: noteId, uid: uid)
        try db.execute(
            sql: "UPDATE note_pages SET page_index = ?, dirty = 1, updated_at = ? WHERE id = ? AND user_id = ?",
            arguments: [tail, now, occId, uid]
        )
        appLogWarn("sync", "page slot conflict: displaced local occupant to tail",
                   ["slot": slot, "keptId": keepId, "displacedId": occId, "tail": tail])
    }

    /// 정상 인덱스 범위(0.., 임시/음수 제외)의 다음 말미 인덱스.
    private func nextTailIndex(_ db: Database, noteId: String, uid: String) throws -> Int {
        let maxIdx = try Int.fetchOne(
            db,
            sql: "SELECT MAX(page_index) FROM note_pages WHERE note_id = ? AND user_id = ? AND page_index >= 0 AND page_index < 1000000",
            arguments: [noteId, uid]
        )
        return (maxIdx ?? -1) + 1
    }

    @discardableResult
    func applyPulledPdfAnnotation(_ incoming: PdfAnnotation) throws -> Bool {
        guard let uid = syncUserId else { return false }
        return try dbQueue.write { db in
            guard try rowExists(db, table: "notes", id: incoming.noteId) else {
                appLogWarn("sync", "skip orphan pdf annotation (parent note absent)",
                           ["annotationId": incoming.id, "noteId": incoming.noteId])
                return false
            }
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
            guard try rowExists(db, table: "notes", id: incoming.noteId) else {
                appLogWarn("sync", "skip orphan feedback (parent note absent)",
                           ["feedbackId": incoming.id, "noteId": incoming.noteId])
                return false
            }
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
            // 레거시 feedbackId가 있는데 부모 feedback이 없으면 skip(FK 방어). nil이면 FK 무관.
            if let fid = incoming.feedbackId, try !rowExists(db, table: "feedbacks", id: fid) {
                appLogWarn("sync", "skip orphan chat (parent feedback absent)",
                           ["chatId": incoming.id, "feedbackId": fid])
                return false
            }
            guard try shouldApply(db, table: "feedback_chats", id: incoming.id, incoming: incoming.updatedAt, uid: uid) else { return false }
            var c = incoming
            c.userId = uid
            c.dirty = false
            try c.save(db)
            return true
        }
    }

    // MARK: - Purge queue (휴지통 영구삭제 → 서버 하드 삭제 전파)

    /// 서버 purge 대기 중인 노트 id. 현재 유저 스코프.
    func pendingPurgeIds() throws -> [String] {
        guard let uid = syncUserId else { return [] }
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM purge_queue WHERE user_id = ?", arguments: [uid])
        }
    }

    /// 서버 purge 성공한 id를 큐에서 제거.
    func clearPurges(ids: [String]) throws {
        guard let uid = syncUserId, !ids.isEmpty else { return }
        try dbQueue.write { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            var args: [DatabaseValueConvertible] = [uid]
            args.append(contentsOf: ids)
            try db.execute(
                sql: "DELETE FROM purge_queue WHERE user_id = ? AND id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
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
