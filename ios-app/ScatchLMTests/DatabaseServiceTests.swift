import XCTest
@testable import ScatchLM

final class DatabaseServiceTests: XCTestCase {
    private var db: DatabaseService!

    override func setUp() {
        super.setUp()
        db = DatabaseService.shared
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
}
