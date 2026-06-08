import XCTest
@testable import ScatchLM

final class DatabaseServiceTests: XCTestCase {
    private var db: DatabaseService!

    override func setUp() {
        super.setUp()
        db = DatabaseService.shared
        // v7 이후 모든 sync 대상 write는 활성 세션(user_id)을 요구한다(§4.5).
        // 테스트마다 고유 user_id로 스코프를 격리한다.
        db.currentUserId = UUID().uuidString.lowercased()
    }

    override func tearDown() {
        db.currentUserId = nil
        super.tearDown()
    }

    // MARK: - Note CRUD

    func testCreateAndFetchNote() throws {
        var note = Note.new(title: "Test Note", language: "Greek")
        try db.saveNote(&note)

        let fetched = try db.note(id: note.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test Note")
        XCTAssertEqual(fetched?.language, "Greek")

        // Cleanup
        try db.deleteNote(id: note.id)
    }

    func testUpdateNoteTitleAndLanguagePersists() throws {
        // EditNoteSheet flow: 같은 id로 title/language를 바꿔 re-save 하면
        // GRDB upsert로 덮어써져야 한다.
        var note = Note.new(title: "Old Title", language: "en")
        try db.saveNote(&note)

        var updated = try XCTUnwrap(db.note(id: note.id))
        updated.title = "New Title"
        updated.language = "Japanese"
        updated.updatedAt = Date()
        try db.saveNote(&updated)

        let refetched = try db.note(id: note.id)
        XCTAssertEqual(refetched?.title, "New Title")
        XCTAssertEqual(refetched?.language, "Japanese")
        XCTAssertEqual(refetched?.id, note.id)

        try db.deleteNote(id: note.id)
    }

    // MARK: - Page System

    func testCreatePagesAndSwitch() throws {
        // Create note
        var note = Note.new(title: "Page Test")
        try db.saveNote(&note)

        // Create pages
        let page0 = try db.createPage(noteId: note.id, pageIndex: 0)
        let page1 = try db.createPage(noteId: note.id, pageIndex: 1)

        // Verify pages
        let pages = try db.pages(noteId: note.id)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].pageIndex, 0)
        XCTAssertEqual(pages[1].pageIndex, 1)

        // Save drawing to page 0
        let testData = "page0-drawing".data(using: .utf8)!
        try db.savePageDrawing(pageId: page0.id, data: testData)

        // Verify drawing persists after page switch
        let loaded = try db.page(noteId: note.id, pageIndex: 0)
        XCTAssertEqual(loaded?.drawingData, testData)

        // Page 1 should have no drawing
        let loaded1 = try db.page(noteId: note.id, pageIndex: 1)
        XCTAssertNil(loaded1?.drawingData)

        // Cleanup
        try db.deleteNote(id: note.id)
    }

    func testSaveDrawingDoesNotCrossPages() throws {
        var note = Note.new(title: "Cross Page Test")
        try db.saveNote(&note)

        let page0 = try db.createPage(noteId: note.id, pageIndex: 0)
        let page1 = try db.createPage(noteId: note.id, pageIndex: 1)

        // Save to page 0
        let data0 = "drawing-0".data(using: .utf8)!
        try db.savePageDrawing(pageId: page0.id, data: data0)

        // Save to page 1
        let data1 = "drawing-1".data(using: .utf8)!
        try db.savePageDrawing(pageId: page1.id, data: data1)

        // Verify isolation
        let loaded0 = try db.page(noteId: note.id, pageIndex: 0)
        let loaded1 = try db.page(noteId: note.id, pageIndex: 1)
        XCTAssertEqual(loaded0?.drawingData, data0)
        XCTAssertEqual(loaded1?.drawingData, data1)

        // Cleanup
        try db.deleteNote(id: note.id)
    }

    // MARK: - Feedback per Page

    func testFeedbackIsolationPerPage() throws {
        var note = Note.new(title: "Feedback Isolation")
        try db.saveNote(&note)

        let page0 = try db.createPage(noteId: note.id, pageIndex: 0)
        let page1 = try db.createPage(noteId: note.id, pageIndex: 1)

        // Add feedback to page 0
        var fb0 = FeedbackRecord(
            id: UUID().uuidString, noteId: note.id, pageId: page0.id,
            content: "feedback for page 0",
            positionX: 16, positionY: 100,
            bboxX: 16, bboxY: 100, bboxWidth: 300, bboxHeight: 200,
            strokeRangeStart: 0, strokeRangeEnd: 0,
            createdAt: Date()
        )
        try db.saveFeedback(&fb0)

        // Page 0 should have 1 feedback
        let fbs0 = try db.feedbacks(pageId: page0.id)
        XCTAssertEqual(fbs0.count, 1)

        // Page 1 should have 0 feedbacks
        let fbs1 = try db.feedbacks(pageId: page1.id)
        XCTAssertEqual(fbs1.count, 0)

        // Cleanup
        try db.deleteNote(id: note.id)
    }

    // MARK: - Feedback Rating

    func testUpdateFeedbackRating() throws {
        var note = Note.new(title: "Rating Test")
        try db.saveNote(&note)
        let page = try db.createPage(noteId: note.id, pageIndex: 0)

        var fb = FeedbackRecord(
            id: UUID().uuidString, noteId: note.id, pageId: page.id,
            content: "fb",
            positionX: 0, positionY: 0,
            bboxX: 0, bboxY: 0, bboxWidth: 100, bboxHeight: 100,
            strokeRangeStart: 0, strokeRangeEnd: 0,
            createdAt: Date(),
            serverFeedbackId: "srv-123"
        )
        try db.saveFeedback(&fb)

        let now = Date()
        try db.updateFeedbackRating(id: fb.id, rating: 1, syncedAt: now)
        let fetched = try db.feedbacks(pageId: page.id).first
        XCTAssertEqual(fetched?.userRating, 1)
        XCTAssertEqual(fetched?.serverFeedbackId, "srv-123")
        XCTAssertNotNil(fetched?.userRatingSyncedAt)

        try db.deleteNote(id: note.id)
    }

    // MARK: - Empty Drawing Save

    func testSaveEmptyDrawing() throws {
        var note = Note.new(title: "Empty Drawing Test")
        try db.saveNote(&note)

        let page = try db.createPage(noteId: note.id, pageIndex: 0)

        // 빈 드로잉 데이터 저장 (빈 캔버스도 저장되어야 함)
        let emptyData = Data()
        try db.savePageDrawing(pageId: page.id, data: emptyData)

        let loaded = try db.page(noteId: note.id, pageIndex: 0)
        XCTAssertNotNil(loaded?.drawingData)
        XCTAssertEqual(loaded?.drawingData, emptyData)

        // Cleanup
        try db.deleteNote(id: note.id)
    }

    func testOverwriteDrawingWithEmpty() throws {
        var note = Note.new(title: "Overwrite Test")
        try db.saveNote(&note)

        let page = try db.createPage(noteId: note.id, pageIndex: 0)

        // 먼저 데이터 저장
        let data = "some-drawing".data(using: .utf8)!
        try db.savePageDrawing(pageId: page.id, data: data)

        // 빈 데이터로 덮어쓰기 — 이전 필기가 남으면 안 됨
        let emptyData = Data()
        try db.savePageDrawing(pageId: page.id, data: emptyData)

        let loaded = try db.page(noteId: note.id, pageIndex: 0)
        XCTAssertEqual(loaded?.drawingData, emptyData)

        try db.deleteNote(id: note.id)
    }

    // MARK: - Cascade Delete

    func testDeleteNoteCascadesPages() throws {
        var note = Note.new(title: "Cascade Test")
        try db.saveNote(&note)

        _ = try db.createPage(noteId: note.id, pageIndex: 0)
        _ = try db.createPage(noteId: note.id, pageIndex: 1)

        // 노트 삭제
        try db.deleteNote(id: note.id)

        // 페이지도 삭제되어야 함
        let pages = try db.pages(noteId: note.id)
        XCTAssertEqual(pages.count, 0)
    }

    func testDeleteNoteCascadesFeedbacks() throws {
        var note = Note.new(title: "Cascade FB Test")
        try db.saveNote(&note)

        let page = try db.createPage(noteId: note.id, pageIndex: 0)

        var fb = FeedbackRecord(
            id: UUID().uuidString, noteId: note.id, pageId: page.id,
            content: "test feedback",
            positionX: 16, positionY: 100,
            bboxX: 16, bboxY: 100, bboxWidth: 300, bboxHeight: 200,
            strokeRangeStart: 0, strokeRangeEnd: 0,
            createdAt: Date()
        )
        try db.saveFeedback(&fb)

        // 노트 삭제
        try db.deleteNote(id: note.id)

        // 피드백도 삭제되어야 함
        let fbs = try db.feedbacks(pageId: page.id)
        XCTAssertEqual(fbs.count, 0)
    }

    // MARK: - Current Page Index

    func testCurrentPageIndexPersistence() throws {
        var note = Note.new(title: "Page Index Test")
        try db.saveNote(&note)

        try db.updateCurrentPageIndex(noteId: note.id, index: 3)

        let fetched = try db.note(id: note.id)
        XCTAssertEqual(fetched?.currentPageIndex, 3)

        // Cleanup
        try db.deleteNote(id: note.id)
    }

    // MARK: - applyPulledPages (pull 머지 슬롯 충돌 회귀)

    private func pulledPage(id: String, noteId: String, index: Int, updatedAt: Date) -> NotePage {
        NotePage(id: id, noteId: noteId, pageIndex: index, drawingData: nil,
                 createdAt: Date(timeIntervalSince1970: 0), userId: db.currentUserId ?? "",
                 drawingHash: nil, updatedAt: updatedAt, deleted: false, dirty: false)
    }

    /// 두 페이지의 인덱스를 맞바꾸는 배치를 pull로 적용해도 UNIQUE(note_id,page_index)
    /// 충돌로 throw하지 않고 정확히 swap 되어야 한다(2-pass). 회귀: 행 단위 save는 brick.
    func testApplyPulledPagesSwapDoesNotBrick() throws {
        var note = Note.new(title: "Swap")
        try db.saveNote(&note)
        let p0 = try db.createPage(noteId: note.id, pageIndex: 0)
        let p1 = try db.createPage(noteId: note.id, pageIndex: 1)

        let newer = Date().addingTimeInterval(60)
        // 서버가 인덱스를 맞바꿔 보냄: p0→1, p1→0
        XCTAssertNoThrow(try db.applyPulledPages([
            pulledPage(id: p0.id, noteId: note.id, index: 1, updatedAt: newer),
            pulledPage(id: p1.id, noteId: note.id, index: 0, updatedAt: newer),
        ]))

        let pages = try db.pages(noteId: note.id)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(try db.page(noteId: note.id, pageIndex: 0)?.id, p1.id)
        XCTAssertEqual(try db.page(noteId: note.id, pageIndex: 1)?.id, p0.id)

        try db.deleteNote(id: note.id)
    }

    /// 배치 밖 로컬 행이 점유한 슬롯을 다른 id의 incoming이 차지하는 진짜 충돌도
    /// throw 없이: incoming이 슬롯을 갖고 점유 행은 말미로 밀려나며 유실되지 않아야 한다.
    func testApplyPulledPagesSlotConflictDisplacesOccupant() throws {
        var note = Note.new(title: "Conflict")
        try db.saveNote(&note)
        let local = try db.createPage(noteId: note.id, pageIndex: 0)

        let incomingId = UUID().uuidString
        let newer = Date().addingTimeInterval(60)
        // 로컬에 없던 새 페이지가 이미 점유된 슬롯 0을 요구
        XCTAssertNoThrow(try db.applyPulledPages([
            pulledPage(id: incomingId, noteId: note.id, index: 0, updatedAt: newer),
        ]))

        let pages = try db.pages(noteId: note.id)
        XCTAssertEqual(pages.count, 2, "두 페이지 모두 보존(유실 없음)")
        XCTAssertEqual(try db.page(noteId: note.id, pageIndex: 0)?.id, incomingId, "incoming이 슬롯 차지")
        XCTAssertTrue(pages.contains { $0.id == local.id }, "점유 행은 말미로 밀려나며 보존")

        try db.deleteNote(id: note.id)
    }
}
