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
            textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], notes: [dto], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: []),
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
            textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], notes: [dto], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: []),
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
            textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-200)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], notes: [dto], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: []),
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
            textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], notes: [dto], note_pages: [], pdf_annotations: [], feedbacks: [], chat_messages: []),
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
            textbook_id: nil, textbook_name: nil, textbook_pages: 0, last_page: 1,
            pdf_open: false, current_page_index: 0, drawing_hash: nil, created_at: iso(-60)
        )
        api.pullResponses = [
            SyncPullResponse(changes: SyncChanges(sessions: [], notes: [noteDTO], note_pages: [pageDTO], pdf_annotations: [], feedbacks: [], chat_messages: []),
                             cursor: iso(0), has_more: false)
        ]
        try await sync.pullChanges()

        XCTAssertTrue(api.downloadedHashes.contains(hash), "로컬에 없는 blob은 다운로드")
        let storedPage = try db.page(noteId: noteId, pageIndex: 0)
        XCTAssertEqual(storedPage?.drawingData, drawing, "다운로드한 blob이 drawing_data로 복원")
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
}
