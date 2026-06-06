import Foundation
import Network

/// iOS Sync 엔진 (Track C). delta sync + LWW (§4.1).
///
/// 단일 진실원은 로컬 `dirty` 플래그(§4.2): 어떤 트리거든 "dirty push → cursor 이후 pull"만
/// 수행하므로 트리거가 중복돼도 멱등하다. 동시 실행은 coalescing으로 직렬화한다.
@Observable
final class SyncService: @unchecked Sendable {
    static let shared = SyncService()

    enum Status: Equatable {
        case idle
        case syncing
        case offline
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastSyncedAt: Date?

    private let api: SyncAPIClient
    private let db: DatabaseService
    private let defaults: UserDefaults

    // 실행 직렬화 / coalescing
    private let lock = NSLock()
    private var isRunning = false
    private var pendingResync = false

    // 트리거 보조
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var backoffStep = 0

    // reachability (C-6)
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.joho54.scatchlm.sync.monitor")
    private var isOnline = true
    private var monitorStarted = false

    private let debounceInterval: TimeInterval
    private let maxPushAttempts = 3
    private let pullLimit = 500

    init(
        api: SyncAPIClient = APIClient.shared,
        db: DatabaseService = .shared,
        defaults: UserDefaults = .standard,
        debounceInterval: TimeInterval = 1.5
    ) {
        self.api = api
        self.db = db
        self.defaults = defaults
        self.debounceInterval = debounceInterval
    }

    // MARK: - Lifecycle

    /// 앱 시작/로그인 시 1회 호출: write 훅 연결 + reachability 감시 시작.
    func start() {
        db.onWrite = { [weak self] in
            self?.scheduleDebouncedSync()
        }
        startMonitorIfNeeded()
    }

    private func startMonitorIfNeeded() {
        guard !monitorStarted else { return }
        monitorStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            let wasOnline = self.isOnline
            self.isOnline = online
            if online && !wasOnline {
                // 네트워크 복구 → 남은 dirty push + pull 재개 (§4.2-3)
                appLog("sync", "reachability online → resume")
                self.requestSync()
            } else if !online {
                self.setStatus(.offline)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - Triggers

    /// 즉시(coalesced) 전체 sync 요청. 이미 실행 중이면 1회 추가 실행을 예약.
    func requestSync() {
        Task { await self.runLoop() }
    }

    /// 로컬 write 후 디바운스 push (§4.2-1). 연속 편집을 한 번으로 묶는다.
    func scheduleDebouncedSync() {
        debounceTask?.cancel()
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.runLoop()
        }
    }

    /// background/종료 직전 즉시 flush (§4.2-2). 대기 중 디바운스를 취소하고 끝까지 await.
    func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        await runLoop()
    }

    /// 로그인 직후 (D-1): 레거시 행 claim 후 최초 sync(push 후 full pull).
    func onLogin(userId: String) {
        guard !userId.isEmpty else { return }
        try? db.claimLegacyRows(for: userId)
        start()
        requestSync()
    }

    /// 로그아웃 (D-1): 진행/예약 작업 중단 + 커서·상태 클리어. 로컬 데이터는 보존(§4.5).
    func onLogout(userId: String) {
        debounceTask?.cancel(); debounceTask = nil
        retryTask?.cancel(); retryTask = nil
        backoffStep = 0
        clearCursor(userId: userId)
        setStatus(.idle)
        lastSyncedAt = nil
    }

    // MARK: - Run loop (coalescing)

    private func runLoop() async {
        lock.lock()
        if isRunning {
            pendingResync = true
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        while true {
            lock.lock(); pendingResync = false; lock.unlock()
            await performSync()
            lock.lock()
            let again = pendingResync
            if !again { isRunning = false }
            lock.unlock()
            if !again { break }
        }
    }

    private func performSync() async {
        guard let uid = db.currentUserId, !uid.isEmpty else { return }   // 미로그인: sync 보류 (§4.5)
        _ = uid
        guard isOnline else { setStatus(.offline); return }

        setStatus(.syncing)
        do {
            try await pushDirty()
            try await pullChanges()
            backoffStep = 0
            retryTask?.cancel(); retryTask = nil
            lastSyncedAt = Date()
            setStatus(.idle)
        } catch {
            appLogError("sync", "performSync failed", ["error": "\(error)"])
            setStatus(isOnline ? .error("\(error)") : .offline)
            scheduleRetry()
        }
    }

    // MARK: - Push (§3.2-b, C-3)

    func pushDirty() async throws {
        var attempt = 0
        while attempt < maxPushAttempts {
            let changes = try collectDirtyChanges()
            if changes.isEmpty { return }

            let res = try await api.syncPush(changes)

            // missing_blob: 참조 blob 업로드 후 재push (§3.2-c, §4.4)
            for hash in res.missing_blobs {
                if let data = try db.blobData(forHash: hash) {
                    _ = try await api.syncUploadBlob(hash: hash, data: data)
                } else {
                    appLogError("sync", "missing_blob not found locally", ["hash": hash])
                }
            }

            // applied/conflict → dirty 해제. missing_blob → dirty 유지(다음 attempt 재push).
            try markCleanFromResults(res.results)

            if res.missing_blobs.isEmpty { return }
            attempt += 1
        }
        appLog("sync", "pushDirty reached max attempts", ["attempts": "\(maxPushAttempts)"])
    }

    private func collectDirtyChanges() throws -> SyncChanges {
        SyncChanges(
            sessions: try db.dirtySessions().map(Self.sessionDTO),
            folders: try db.dirtyFolders().map(Self.folderDTO),
            notes: try db.dirtyNotes().map(Self.noteDTO),
            note_pages: try db.dirtyPages().map(Self.pageDTO),
            pdf_annotations: try db.dirtyPdfAnnotations().map(Self.pdfAnnotationDTO),
            feedbacks: try db.dirtyFeedbacks().map(Self.feedbackDTO),
            chat_messages: try db.dirtyChats().map(Self.chatDTO)
        )
    }

    private func markCleanFromResults(_ results: [SyncPushResult]) throws {
        var byTable: [String: [String]] = [:]
        for r in results where r.status != "missing_blob" {
            guard let table = Self.tableForEntity[r.entity] else { continue }
            byTable[table, default: []].append(r.id)
        }
        for (table, ids) in byTable {
            try db.markClean(table: table, ids: ids)
        }
    }

    // MARK: - Pull (§3.2-a, C-2)

    func pullChanges() async throws {
        guard let uid = db.currentUserId, !uid.isEmpty else { return }
        var since = loadCursor(userId: uid)
        while true {
            let res = try await api.syncPull(since: since, limit: pullLimit)
            try await merge(res.changes, uid: uid)
            since = res.cursor
            saveCursor(res.cursor, userId: uid)
            if !res.has_more { break }
        }
    }

    /// pull 결과를 로컬에 LWW 머지. note/page는 drawing_hash로 blob을 해소(로컬 재사용/다운로드).
    private func merge(_ changes: SyncChanges, uid: String) async throws {
        // sessions를 chat_messages/feedbacks보다 먼저 적용해 참조 무결성을 지킨다(§3.2-a / R2).
        for dto in changes.sessions {
            try db.applyPulledSession(Self.session(from: dto, userId: uid))
        }
        // folders를 notes 앞에 적용해 note.folder_id 참조 무결성을 지킨다(§3.2-a / R1).
        for dto in changes.folders {
            try db.applyPulledFolder(Self.folder(from: dto, userId: uid))
        }
        for dto in changes.notes {
            let blob = try await resolveBlob(hash: dto.drawing_hash)
            try db.applyPulledNote(Self.note(from: dto, drawingData: blob, userId: uid))
        }
        for dto in changes.note_pages {
            let blob = try await resolveBlob(hash: dto.drawing_hash)
            try db.applyPulledPage(Self.page(from: dto, drawingData: blob, userId: uid))
        }
        for dto in changes.pdf_annotations {
            let blob = try await resolveBlob(hash: dto.drawing_hash)
            try db.applyPulledPdfAnnotation(Self.pdfAnnotation(from: dto, drawingData: blob, userId: uid))
        }
        for dto in changes.feedbacks {
            try db.applyPulledFeedback(Self.feedback(from: dto, userId: uid))
        }
        for dto in changes.chat_messages {
            try db.applyPulledChat(Self.chat(from: dto, userId: uid))
        }
    }

    private func resolveBlob(hash: String?) async throws -> Data? {
        guard let hash else { return nil }
        if let local = try db.blobData(forHash: hash) { return local }
        return try await api.syncDownloadBlob(hash: hash)
    }

    // MARK: - Cursor (§4.1)

    private func cursorKey(_ userId: String) -> String { "syncCursor.\(userId)" }
    private func loadCursor(userId: String) -> String? { defaults.string(forKey: cursorKey(userId)) }
    private func saveCursor(_ cursor: String, userId: String) { defaults.set(cursor, forKey: cursorKey(userId)) }
    private func clearCursor(userId: String) { defaults.removeObject(forKey: cursorKey(userId)) }

    // MARK: - Retry (C-6, §4.2-3)

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = min(60.0, pow(2.0, Double(backoffStep)) * 2.0)   // 2,4,8,...,60s
        backoffStep += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self, self.isOnline else { return }
            await self.runLoop()
        }
    }

    // MARK: - Status (@Observable, UI 바인딩)

    private func setStatus(_ s: Status) {
        if Thread.isMainThread {
            status = s
        } else {
            DispatchQueue.main.async { self.status = s }
        }
    }

    // MARK: - DTO 매핑 (local model ↔ wire, §3.2)

    static let tableForEntity: [String: String] = [
        "chat_session": "chat_sessions",
        "folder": "folders",
        "note": "notes",
        "note_page": "note_pages",
        "pdf_annotation": "pdf_annotations",
        "feedback": "feedbacks",
        "chat_message": "feedback_chats"
    ]

    static func sessionDTO(_ s: ChatSessionRecord) -> SyncSessionDTO {
        SyncSessionDTO(
            id: s.id, updated_at: SyncDate.string(from: s.updatedAt), deleted: s.deleted,
            kind: s.kind, title: s.title, note_id: s.noteId, textbook_id: s.textbookId,
            anchor_page: s.anchorPage, chapter_title: s.chapterTitle,
            source_feedback_id: s.sourceFeedbackId,
            created_at: SyncDate.string(from: s.createdAt)
        )
    }

    static func session(from d: SyncSessionDTO, userId: String) -> ChatSessionRecord {
        ChatSessionRecord(
            id: d.id, kind: d.kind, title: d.title, noteId: d.note_id, textbookId: d.textbook_id,
            anchorPage: d.anchor_page, chapterTitle: d.chapter_title, sourceFeedbackId: d.source_feedback_id,
            createdAt: SyncDate.date(from: d.created_at) ?? Date(),
            userId: userId, updatedAt: SyncDate.date(from: d.updated_at) ?? Date(),
            deleted: d.deleted, dirty: false
        )
    }

    static func folderDTO(_ f: Folder) -> SyncFolderDTO {
        SyncFolderDTO(
            id: f.id, updated_at: SyncDate.string(from: f.updatedAt), deleted: f.deleted,
            name: f.name, sort_order: f.sortOrder,
            created_at: SyncDate.string(from: f.createdAt)
        )
    }

    static func folder(from d: SyncFolderDTO, userId: String) -> Folder {
        Folder(
            id: d.id, name: d.name, sortOrder: d.sort_order,
            createdAt: SyncDate.date(from: d.created_at) ?? Date(),
            userId: userId, updatedAt: SyncDate.date(from: d.updated_at) ?? Date(),
            deleted: d.deleted, dirty: false
        )
    }

    static func noteDTO(_ n: Note) -> SyncNoteDTO {
        SyncNoteDTO(
            id: n.id, updated_at: SyncDate.string(from: n.updatedAt), deleted: n.deleted,
            title: n.title, language: n.language, folder_id: n.folderId,
            textbook_id: n.textbookId, textbook_name: n.textbookName,
            textbook_pages: n.textbookPages, last_page: n.lastPage, pdf_open: n.pdfOpen,
            current_page_index: n.currentPageIndex, drawing_hash: n.drawingHash,
            created_at: SyncDate.string(from: n.createdAt)
        )
    }

    static func note(from d: SyncNoteDTO, drawingData: Data?, userId: String) -> Note {
        Note(
            id: d.id, title: d.title, language: d.language, folderId: d.folder_id,
            textbookId: d.textbook_id,
            textbookName: d.textbook_name, textbookPages: d.textbook_pages, drawingData: drawingData,
            lastPage: d.last_page, pdfOpen: d.pdf_open, currentPageIndex: d.current_page_index,
            createdAt: SyncDate.date(from: d.created_at) ?? Date(),
            updatedAt: SyncDate.date(from: d.updated_at) ?? Date(),
            userId: userId, drawingHash: d.drawing_hash, deleted: d.deleted, dirty: false
        )
    }

    static func pageDTO(_ p: NotePage) -> SyncPageDTO {
        SyncPageDTO(
            id: p.id, updated_at: SyncDate.string(from: p.updatedAt), deleted: p.deleted,
            note_id: p.noteId, page_index: p.pageIndex, drawing_hash: p.drawingHash,
            created_at: SyncDate.string(from: p.createdAt)
        )
    }

    static func page(from d: SyncPageDTO, drawingData: Data?, userId: String) -> NotePage {
        NotePage(
            id: d.id, noteId: d.note_id, pageIndex: d.page_index, drawingData: drawingData,
            createdAt: SyncDate.date(from: d.created_at) ?? Date(),
            userId: userId, drawingHash: d.drawing_hash,
            updatedAt: SyncDate.date(from: d.updated_at) ?? Date(),
            deleted: d.deleted, dirty: false
        )
    }

    static func pdfAnnotationDTO(_ a: PdfAnnotation) -> SyncPdfAnnotationDTO {
        SyncPdfAnnotationDTO(
            id: a.id, updated_at: SyncDate.string(from: a.updatedAt), deleted: a.deleted,
            note_id: a.noteId, pdf_page: a.pdfPage, drawing_hash: a.drawingHash,
            created_at: SyncDate.string(from: a.createdAt)
        )
    }

    static func pdfAnnotation(from d: SyncPdfAnnotationDTO, drawingData: Data?, userId: String) -> PdfAnnotation {
        PdfAnnotation(
            id: d.id, noteId: d.note_id, pdfPage: d.pdf_page, drawingData: drawingData,
            createdAt: SyncDate.date(from: d.created_at) ?? Date(),
            userId: userId, drawingHash: d.drawing_hash,
            updatedAt: SyncDate.date(from: d.updated_at) ?? Date(),
            deleted: d.deleted, dirty: false
        )
    }

    static func feedbackDTO(_ f: FeedbackRecord) -> SyncFeedbackDTO {
        SyncFeedbackDTO(
            id: f.id, updated_at: SyncDate.string(from: f.updatedAt), deleted: f.deleted,
            note_id: f.noteId, page_id: f.pageId, content: f.content,
            position_x: f.positionX, position_y: f.positionY,
            bbox_x: f.bboxX, bbox_y: f.bboxY, bbox_width: f.bboxWidth, bbox_height: f.bboxHeight,
            stroke_range_start: f.strokeRangeStart, stroke_range_end: f.strokeRangeEnd,
            server_feedback_id: f.serverFeedbackId, user_rating: f.userRating,
            session_id: f.sessionId,
            created_at: SyncDate.string(from: f.createdAt)
        )
    }

    static func feedback(from d: SyncFeedbackDTO, userId: String) -> FeedbackRecord {
        FeedbackRecord(
            id: d.id, noteId: d.note_id, pageId: d.page_id, content: d.content,
            positionX: d.position_x, positionY: d.position_y,
            bboxX: d.bbox_x, bboxY: d.bbox_y, bboxWidth: d.bbox_width, bboxHeight: d.bbox_height,
            strokeRangeStart: d.stroke_range_start ?? 0, strokeRangeEnd: d.stroke_range_end ?? 0,
            createdAt: SyncDate.date(from: d.created_at) ?? Date(),
            serverFeedbackId: d.server_feedback_id, userRating: d.user_rating, userRatingSyncedAt: nil,
            sessionId: d.session_id,
            userId: userId, updatedAt: SyncDate.date(from: d.updated_at) ?? Date(),
            deleted: d.deleted, dirty: false
        )
    }

    static func chatDTO(_ c: ChatMessageRecord) -> SyncChatDTO {
        SyncChatDTO(
            id: c.id, updated_at: SyncDate.string(from: c.updatedAt), deleted: c.deleted,
            session_id: c.sessionId, feedback_id: c.feedbackId, role: c.role, content: c.content,
            server_message_id: c.serverMessageId, user_rating: c.userRating,
            created_at: SyncDate.string(from: c.createdAt)
        )
    }

    static func chat(from d: SyncChatDTO, userId: String) -> ChatMessageRecord {
        ChatMessageRecord(
            id: d.id, sessionId: d.session_id, feedbackId: d.feedback_id, role: d.role, content: d.content,
            createdAt: SyncDate.date(from: d.created_at) ?? Date(),
            serverMessageId: d.server_message_id, userRating: d.user_rating, userRatingSyncedAt: nil,
            userId: userId, updatedAt: SyncDate.date(from: d.updated_at) ?? Date(),
            deleted: d.deleted, dirty: false
        )
    }
}
