import XCTest
@testable import ScatchLM

/// SyncAPIClient 테스트 더블 (§3.2 MSW 비고 / C-5). 네트워크 없이 sync 엔진을 구동한다.
final class MockSyncAPIClient: SyncAPIClient, @unchecked Sendable {
    // pull: 순서대로 소비되는 응답 큐. 소진되면 빈 변경 + has_more=false.
    var pullResponses: [SyncPullResponse] = []
    private(set) var pullIndex = 0
    private(set) var pulledSince: [String?] = []

    // push: 호출별 응답을 결정하는 핸들러.
    var pushHandler: ((SyncChanges, Int) -> SyncPushResponse)?
    private(set) var pushCallCount = 0
    private(set) var lastPushedChanges: SyncChanges?

    // blob
    private(set) var uploadedBlobs: [String: Data] = [:]
    var downloadStore: [String: Data] = [:]
    private(set) var downloadedHashes: [String] = []

    func syncPull(since: String?, limit: Int) async throws -> SyncPullResponse {
        pulledSince.append(since)
        defer { pullIndex += 1 }
        if pullIndex < pullResponses.count { return pullResponses[pullIndex] }
        return SyncPullResponse(changes: .empty, cursor: since ?? "", has_more: false)
    }

    func syncPush(_ changes: SyncChanges) async throws -> SyncPushResponse {
        lastPushedChanges = changes
        defer { pushCallCount += 1 }
        return pushHandler?(changes, pushCallCount) ?? SyncPushResponse(results: [], missing_blobs: [])
    }

    // purge
    private(set) var purgedNoteIds: [String] = []
    func syncPurge(noteIds: [String]) async throws -> SyncPurgeResponse {
        purgedNoteIds.append(contentsOf: noteIds)
        return SyncPurgeResponse(purged: noteIds)
    }

    func syncUploadBlob(hash: String, data: Data) async throws -> SyncBlobResponse {
        uploadedBlobs[hash] = data
        downloadStore[hash] = data
        return SyncBlobResponse(hash: hash, stored: true)
    }

    func syncDownloadBlob(hash: String) async throws -> Data {
        downloadedHashes.append(hash)
        if let d = downloadStore[hash] { return d }
        throw APIError.serverError(404, "no blob \(hash)")
    }
}

final class SyncServiceTests: XCTestCase {
    private var db: DatabaseService!
    private var api: MockSyncAPIClient!
    private var defaults: UserDefaults!
    private var sync: SyncService!
    private var user: String!

    override func setUp() {
        super.setUp()
        db = DatabaseService.shared
        api = MockSyncAPIClient()
        let suite = "SyncServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        // 테스트마다 고유 user_id로 스코프 격리 (다른 테스트 데이터와 분리)
        user = UUID().uuidString.lowercased()
        db.currentUserId = user
        sync = SyncService(api: api, db: db, defaults: defaults)
    }

    override func tearDown() {
        db.currentUserId = nil
        super.tearDown()
    }

    private func iso(_ secondsFromNow: TimeInterval) -> String {
        SyncDate.string(from: Date().addingTimeInterval(secondsFromNow))
    }

    // MARK: - Pull merge

    func testPullInsertsNewNote() async throws {
        let id = UUID().uuidString
        let dto = SyncNoteDTO(
            id: id, updated_at: iso(0), deleted: false, title: "불어 1과", language: "fr",
            folder_id: nil, textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], folders: [], notes: [dto], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: []),
                             cursor: iso(0), has_more: false)
        ]
        try await sync.pullChanges()

        let fetched = try db.note(id: id)
        XCTAssertEqual(fetched?.title, "불어 1과")
        XCTAssertEqual(fetched?.dirty, false, "서버발 머지는 dirty=0")
    }

    func testPullTombstoneHidesNote() async throws {
        // 로컬에 노트 생성 후, 서버가 더 최신 tombstone(deleted)을 내려보냄
        var note = Note.new(title: "삭제될 노트", language: "fr")
        try db.saveNote(&note)

        let dto = SyncNoteDTO(
            id: note.id, updated_at: iso(10), deleted: true, title: note.title, language: "fr",
            folder_id: nil, textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], folders: [], notes: [dto], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: []),
                             cursor: iso(10), has_more: false)
        ]
        try await sync.pullChanges()

        XCTAssertNil(try db.note(id: note.id), "tombstone는 조회에서 제외(deleted=1)")
        XCTAssertFalse(try db.allNotes().contains { $0.id == note.id })
    }

    // MARK: - LWW

    func testPullDoesNotOverwriteNewerLocal() async throws {
        var note = Note.new(title: "로컬 최신", language: "fr")
        try db.saveNote(&note)   // updatedAt ≈ now

        // incoming은 더 오래된 버전
        let dto = SyncNoteDTO(
            id: note.id, updated_at: iso(-100), deleted: false, title: "서버 옛버전", language: "fr",
            folder_id: nil, textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-200)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], folders: [], notes: [dto], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: []),
                             cursor: iso(0), has_more: false)
        ]
        try await sync.pullChanges()

        XCTAssertEqual(try db.note(id: note.id)?.title, "로컬 최신", "로컬이 더 최신이면 LWW로 보존")
    }

    func testPullOverwritesOlderLocal() async throws {
        var note = Note.new(title: "로컬 옛버전", language: "fr")
        try db.saveNote(&note)

        let dto = SyncNoteDTO(
            id: note.id, updated_at: iso(100), deleted: false, title: "서버 최신", language: "fr",
            folder_id: nil, textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], folders: [], notes: [dto], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: []),
                             cursor: iso(100), has_more: false)
        ]
        try await sync.pullChanges()

        XCTAssertEqual(try db.note(id: note.id)?.title, "서버 최신", "서버가 더 최신이면 적용")
    }

    // MARK: - Cursor

    func testCursorAdvancesAcrossPages() async throws {
        let c1 = iso(10), c2 = iso(20)
        api.pullResponses = [
            SyncPullResponse(changes: .empty, cursor: c1, has_more: true),
            SyncPullResponse(changes: .empty, cursor: c2, has_more: false)
        ]
        try await sync.pullChanges()

        XCTAssertEqual(api.pulledSince.count, 2)
        XCTAssertNil(api.pulledSince[0], "최초 pull은 since=nil")
        XCTAssertEqual(api.pulledSince[1], c1, "2번째 pull은 직전 cursor를 since로")
        XCTAssertEqual(defaults.string(forKey: "syncCursor.\(user!)"), c2, "최종 cursor 저장")
    }

    // MARK: - Push

    func testPushClearsDirtyOnApplied() async throws {
        var note = Note.new(title: "push 대상", language: "fr")
        try db.saveNote(&note)
        XCTAssertFalse(try db.dirtyNotes().isEmpty)

        api.pushHandler = { changes, _ in
            let results = changes.notes.map {
                SyncPushResult(id: $0.id, entity: "note", status: "applied", server_updated_at: $0.updated_at)
            }
            return SyncPushResponse(results: results, missing_blobs: [])
        }
        try await sync.pushDirty()

        XCTAssertTrue(try db.dirtyNotes().isEmpty, "applied 후 dirty 해제")
        XCTAssertEqual(api.pushCallCount, 1)
    }

    func testPushClearsDirtyOnConflict() async throws {
        var note = Note.new(title: "conflict 대상", language: "fr")
        try db.saveNote(&note)

        api.pushHandler = { changes, _ in
            let results = changes.notes.map {
                SyncPushResult(id: $0.id, entity: "note", status: "conflict", server_updated_at: $0.updated_at)
            }
            return SyncPushResponse(results: results, missing_blobs: [])
        }
        try await sync.pushDirty()

        XCTAssertTrue(try db.dirtyNotes().isEmpty, "conflict도 dirty 해제(다음 pull로 서버본 수용)")
    }

    func testPushUploadsMissingBlobThenRepushes() async throws {
        // 드로잉 있는 페이지 생성 → drawing_hash 산출, dirty=1
        var note = Note.new(title: "blob 노트", language: "fr")
        try db.saveNote(&note)
        let page = try db.createPage(noteId: note.id, pageIndex: 0)
        let drawing = "PKDRAWING-BYTES".data(using: .utf8)!
        try db.savePageDrawing(pageId: page.id, data: drawing)

        let saved = try XCTUnwrap(try db.pages(noteId: note.id).first)
        let hash = try XCTUnwrap(saved.drawingHash)

        api.pushHandler = { changes, callIndex in
            // 1번째 push: 페이지가 missing_blob. 2번째(재push): applied.
            let pageResults = changes.note_pages.map { dto -> SyncPushResult in
                let status = callIndex == 0 ? "missing_blob" : "applied"
                return SyncPushResult(id: dto.id, entity: "note_page", status: status, server_updated_at: dto.updated_at)
            }
            let noteResults = changes.notes.map {
                SyncPushResult(id: $0.id, entity: "note", status: "applied", server_updated_at: $0.updated_at)
            }
            let missing = callIndex == 0 ? [hash] : []
            return SyncPushResponse(results: pageResults + noteResults, missing_blobs: missing)
        }
        try await sync.pushDirty()

        XCTAssertEqual(api.uploadedBlobs[hash], drawing, "missing_blob hash의 본문이 업로드됨")
        XCTAssertGreaterThanOrEqual(api.pushCallCount, 2, "blob 업로드 후 재push")
        XCTAssertTrue(try db.dirtyPages().isEmpty, "재push applied 후 dirty 해제")
    }

    // MARK: - Blob download on pull

    func testPullDownloadsMissingBlob() async throws {
        let pageId = UUID().uuidString
        let noteId = UUID().uuidString
        // 노트가 있어야 page 머지가 의미있지만, applyPulledPage는 note FK를 강제하지 않으니 page만 검증
        let drawing = "REMOTE-DRAWING".data(using: .utf8)!
        let hash = DrawingHash.sha256(drawing)
        api.downloadStore[hash] = drawing

        let pageDTO = SyncPageDTO(
            id: pageId, updated_at: iso(0), deleted: false, note_id: noteId,
            page_index: 0, drawing_hash: hash, created_at: iso(-60)
        )
        // note도 함께 내려 FK 충족
        let noteDTO = SyncNoteDTO(
            id: noteId, updated_at: iso(0), deleted: false, title: "원격 노트", language: "fr",
            folder_id: nil, textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], folders: [], notes: [noteDTO], note_pages: [pageDTO], pdf_annotations: [], feedbacks: [], chat_messages: []),
                             cursor: iso(0), has_more: false)
        ]
        try await sync.pullChanges()

        XCTAssertTrue(api.downloadedHashes.contains(hash), "로컬에 없는 blob은 다운로드")
        let storedPage = try db.page(noteId: noteId, pageIndex: 0)
        XCTAssertEqual(storedPage?.drawingData, drawing, "다운로드한 blob이 drawing_data로 복원")
    }

    /// 부모 note 없는 orphan feedback(서버 purge 잔해 등)이 와도, 그 행만 skip하고 정상 행은
    /// 적용 + 커서 전진. 과거엔 FK 위반이 merge 전체를 throw → 커서 미저장 → fresh-install sync brick.
    func testPullSkipsOrphanFeedbackWithoutBricking() async throws {
        let noteId = UUID().uuidString
        let okId = UUID().uuidString
        let orphanId = UUID().uuidString
        let noteDTO = SyncNoteDTO(
            id: noteId, updated_at: iso(0), deleted: false, title: "노트", language: "fr",
            folder_id: nil, textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        func fb(_ id: String, _ note: String) -> SyncFeedbackDTO {
            SyncFeedbackDTO(
                id: id, updated_at: iso(0), deleted: false, note_id: note, page_id: nil,
                content: "c", position_x: 0, position_y: 0, bbox_x: 0, bbox_y: 0,
                bbox_width: 0, bbox_height: 0, stroke_range_start: nil, stroke_range_end: nil,
                server_feedback_id: nil, user_rating: nil, session_id: nil, created_at: iso(-60)
            )
        }
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(
                sessions: [], folders: [], notes: [noteDTO], note_pages: [], pdf_annotations: [],
                feedbacks: [fb(okId, noteId), fb(orphanId, UUID().uuidString)], chat_messages: []),
                cursor: iso(0), has_more: false)
        ]
        try await sync.pullChanges()   // orphan이 있어도 throw하지 않아야 함

        let stored = try db.feedbacks(noteId: noteId)
        XCTAssertTrue(stored.contains { $0.id == okId }, "정상 feedback은 저장")
        XCTAssertFalse(stored.contains { $0.id == orphanId }, "orphan(부모 note 없음)은 skip")
        XCTAssertEqual(defaults.string(forKey: "syncCursor.\(user!)"), iso(0),
                       "orphan에도 커서 전진 — sync가 brick되지 않음")
    }

    // MARK: - 유저 격리

    func testCrossUserIsolation() throws {
        var note = Note.new(title: "유저A 노트", language: "fr")
        try db.saveNote(&note)            // currentUserId = user (A)

        db.currentUserId = UUID().uuidString.lowercased()   // user B
        XCTAssertNil(try db.note(id: note.id), "다른 유저는 A의 노트를 볼 수 없음")
        XCTAssertFalse(try db.allNotes().contains { $0.id == note.id })

        db.currentUserId = user           // back to A
        XCTAssertNotNil(try db.note(id: note.id))
    }

    // MARK: - Folders (note-folders-spec)

    func testFolderCRUDAndNoteMove() throws {
        var folder = Folder(name: "라틴어", sortOrder: 0)
        try db.saveFolder(&folder)
        XCTAssertTrue(try db.allFolders().contains { $0.id == folder.id })

        var note = Note.new(title: "1과")
        try db.saveNote(&note)
        try db.moveNote(id: note.id, toFolder: folder.id)
        XCTAssertEqual(try db.note(id: note.id)?.folderId, folder.id, "노트가 폴더로 이동")

        // 폴더 삭제 시 노트는 보존되고 folder_id=NULL로 이동 (§4.4 R2)
        try db.deleteFolder(id: folder.id)
        XCTAssertFalse(try db.allFolders().contains { $0.id == folder.id }, "삭제된 폴더는 목록에서 제외")
        let moved = try db.note(id: note.id)
        XCTAssertNotNil(moved, "노트는 절대 삭제 안 함")
        XCTAssertNil(moved?.folderId, "소속 노트는 전체(NULL)로 이동")
    }

    func testFolderPushRoundTrip() async throws {
        var folder = Folder(name: "그리스어", sortOrder: 2)
        try db.saveFolder(&folder)

        api.pushHandler = { changes, _ in
            SyncPushResponse(
                results: changes.folders.map {
                    SyncPushResult(id: $0.id, entity: "folder", status: "applied", server_updated_at: $0.updated_at)
                },
                missing_blobs: []
            )
        }
        try await sync.pushDirty()

        let pushed = api.lastPushedChanges?.folders.first { $0.id == folder.id }
        XCTAssertEqual(pushed?.name, "그리스어")
        XCTAssertEqual(pushed?.sort_order, 2)
        XCTAssertTrue(try db.dirtyFolders().isEmpty, "applied 후 dirty 해제")
    }

    func testFolderPullMerge() async throws {
        let id = UUID().uuidString
        let dto = SyncFolderDTO(id: id, updated_at: iso(0), deleted: false,
                                name: "수학", sort_order: 1, created_at: iso(-60))
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], folders: [dto], notes: [], note_pages: [],
                                                  pdf_annotations: [], feedbacks: [], chat_messages: []),
                             cursor: iso(0), has_more: false)
        ]
        try await sync.pullChanges()

        let fetched = try db.allFolders().first { $0.id == id }
        XCTAssertEqual(fetched?.name, "수학")
        XCTAssertEqual(fetched?.dirty, false, "서버발 머지는 dirty=0")
    }

    func testNoteFolderIdSurvivesPushRoundTrip() async throws {
        var folder = Folder(name: "F", sortOrder: 0)
        try db.saveFolder(&folder)
        var note = Note.new(title: "분류된 노트", folderId: folder.id)
        try db.saveNote(&note)

        var captured: String??
        api.pushHandler = { changes, _ in
            captured = changes.notes.first { $0.id == note.id }?.folder_id
            return SyncPushResponse(results: [], missing_blobs: [])
        }
        try await sync.pushDirty()
        XCTAssertEqual(captured ?? nil, folder.id, "note.folder_id가 와이어로 전송")
    }

    // MARK: - Trash & 재귀 폴더 삭제

    func testFolderDeleteRecursivelyTrashesNotes() throws {
        var folder = Folder(name: "삭제대상", sortOrder: 0)
        try db.saveFolder(&folder)
        var note = Note.new(title: "안의 노트", folderId: folder.id)
        try db.saveNote(&note)

        try db.deleteFolder(id: folder.id)

        XCTAssertFalse(try db.allFolders().contains { $0.id == folder.id }, "폴더 삭제")
        XCTAssertNil(try db.note(id: note.id), "노트는 active 목록에서 제외(휴지통으로)")
        XCTAssertTrue(try db.trashedNotes().contains { $0.id == note.id }, "노트는 휴지통에 존재(복구 가능)")
    }

    func testRestoreNoteFromTrash() throws {
        var note = Note.new(title: "복구할 노트")
        try db.saveNote(&note)
        try db.deleteNote(id: note.id)
        XCTAssertTrue(try db.trashedNotes().contains { $0.id == note.id })

        try db.restoreNote(id: note.id)
        XCTAssertFalse(try db.trashedNotes().contains { $0.id == note.id }, "복구 후 휴지통에서 제외")
        XCTAssertNotNil(try db.note(id: note.id), "active 목록으로 복귀")
        XCTAssertEqual(try db.note(id: note.id)?.dirty, true, "복구는 dirty=1로 재push")
    }

    func testPermanentDeleteNoteIsHardDelete() throws {
        var note = Note.new(title: "영구삭제 노트")
        try db.saveNote(&note)
        try db.deleteNote(id: note.id)

        try db.permanentlyDeleteNote(id: note.id)
        XCTAssertFalse(try db.trashedNotes().contains { $0.id == note.id }, "휴지통에서 사라짐")
        XCTAssertNil(try db.note(id: note.id))
        // 하드 삭제: dirtyNotes에도 안 잡혀야(행 자체가 없음)
        XCTAssertFalse(try db.dirtyNotes().contains { $0.id == note.id }, "행 자체가 하드 삭제됨")
    }

    func testEmptyTrashPurgesAll() throws {
        var a = Note.new(title: "A"); try db.saveNote(&a)
        var b = Note.new(title: "B"); try db.saveNote(&b)
        try db.deleteNote(id: a.id)
        try db.deleteNote(id: b.id)
        XCTAssertEqual(try db.trashedNotes().count, 2)

        try db.emptyTrash()
        XCTAssertTrue(try db.trashedNotes().isEmpty, "비우기 후 휴지통 비어있음")
        XCTAssertNil(try db.note(id: a.id))
        XCTAssertNil(try db.note(id: b.id))
    }

    func testPermanentDeleteEnqueuesServerPurge() throws {
        var note = Note.new(title: "퍼지 큐")
        try db.saveNote(&note)
        try db.deleteNote(id: note.id)
        try db.permanentlyDeleteNote(id: note.id)

        XCTAssertTrue(try db.pendingPurgeIds().contains(note.id), "영구삭제는 서버 purge 큐에 적재")
    }

    func testFlushPurgesCallsServerAndClearsQueue() async throws {
        var note = Note.new(title: "서버 퍼지")
        try db.saveNote(&note)
        try db.deleteNote(id: note.id)
        try db.permanentlyDeleteNote(id: note.id)
        XCTAssertFalse(try db.pendingPurgeIds().isEmpty)

        try await sync.flushPurges()

        XCTAssertTrue(api.purgedNoteIds.contains(note.id), "서버 /sync/purge 호출")
        XCTAssertTrue(try db.pendingPurgeIds().isEmpty, "성공 후 큐 비움")
    }

    // MARK: - 계약 skew 내성 (회귀: sync 멈춤 사건)

    /// 서버가 클라보다 구버전이라 'folders' 등 엔티티 키를 안 내려줘도, pull 디코딩이
    /// keyNotFound로 전체 브릭되지 않고 누락 키를 빈 배열로 처리해야 한다.
    /// (배포 순서 skew로 folders 키 누락 → 몇 시간 sync 멈춘 사건의 회귀 가드.)
    func testSyncChangesDecodesWithMissingKeys() throws {
        let json = Data("""
        {"notes":[],"note_pages":[],"feedbacks":[],"chat_messages":[]}
        """.utf8)
        let changes = try JSONDecoder().decode(SyncChanges.self, from: json)
        XCTAssertTrue(changes.folders.isEmpty)
        XCTAssertTrue(changes.pdf_annotations.isEmpty)
        XCTAssertTrue(changes.sessions.isEmpty)
        XCTAssertTrue(changes.isEmpty)
    }

    /// 빈 객체 `{}`도 안전하게 빈 변경으로 디코딩(키 전무).
    func testSyncChangesDecodesEmptyObject() throws {
        let changes = try JSONDecoder().decode(SyncChanges.self, from: Data("{}".utf8))
        XCTAssertTrue(changes.isEmpty)
    }
}
