import XCTest
@testable import ScatchLM

/// `recentCuesForWidget` 투영 로직 회귀 테스트 — 위젯에 뭘 띄울지 결정하는 부분.
/// 세션 링크 통과·키워드 중복제거·길이 컷·사용자 격리·최신 우선을 검증한다.
/// (DMNCue는 로컬 전용 테이블, note_id에 FK가 없어 임의 노트 id로 적재 가능.)
final class WidgetCueProjectionTests: XCTestCase {
    private var db: DatabaseService!

    override func setUp() {
        super.setUp()
        db = DatabaseService.shared
        db.currentUserId = UUID().uuidString.lowercased()   // 테스트마다 스코프 격리
    }

    override func tearDown() {
        db.currentUserId = nil
        super.tearDown()
    }

    func testSessionIdIsLinkedThrough() throws {
        try db.insertDMNCues(noteId: "n1", keywords: ["역전파", "경사하강"],
                             source: "feedback", sessionId: "sess-A")
        let cues = db.recentCuesForWidget()
        XCTAssertEqual(cues.count, 2)
        XCTAssertTrue(cues.allSatisfy { $0.sessionId == "sess-A" })
        XCTAssertTrue(cues.allSatisfy { $0.noteId == "n1" })
    }

    func testNilSessionForLegacyInsert() throws {
        try db.insertDMNCues(noteId: "n1", keywords: ["베이즈"], source: "guide-chat")
        let cue = try XCTUnwrap(db.recentCuesForWidget().first)
        XCTAssertNil(cue.sessionId)
    }

    func testKeywordDedupCaseInsensitive() throws {
        try db.insertDMNCues(noteId: "n1", keywords: ["Bayes"], source: "feedback", sessionId: "s1")
        try db.insertDMNCues(noteId: "n2", keywords: ["bayes"], source: "feedback", sessionId: "s2")
        let cues = db.recentCuesForWidget()
        XCTAssertEqual(cues.filter { $0.keyword.lowercased() == "bayes" }.count, 1)
    }

    func testLongKeywordFilteredOut() throws {
        // dmnCueMaxLen=10 초과는 구절로 보고 제외(휴식 중 흘끗 보는 단서엔 부적합).
        let long = String(repeating: "가", count: DatabaseService.dmnCueMaxLen + 1)
        try db.insertDMNCues(noteId: "n1", keywords: [long, "짧은말"], source: "feedback", sessionId: "s1")
        let keywords = db.recentCuesForWidget().map(\.keyword)
        XCTAssertFalse(keywords.contains(long))
        XCTAssertTrue(keywords.contains("짧은말"))
    }

    func testMostRecentFirst() throws {
        try db.insertDMNCues(noteId: "n1", keywords: ["먼저"], source: "feedback", sessionId: "s1")
        try db.insertDMNCues(noteId: "n1", keywords: ["나중"], source: "feedback", sessionId: "s2")
        let keywords = db.recentCuesForWidget().map(\.keyword)
        XCTAssertEqual(keywords.first, "나중")
    }

    func testRespectsLimit() throws {
        let many = (0..<12).map { "단서\($0)" }
        try db.insertDMNCues(noteId: "n1", keywords: many, source: "feedback", sessionId: "s1")
        XCTAssertEqual(db.recentCuesForWidget(limit: 5).count, 5)
    }

    func testScopedToUser() throws {
        try db.insertDMNCues(noteId: "n1", keywords: ["내것"], source: "feedback", sessionId: "s1")
        db.currentUserId = UUID().uuidString.lowercased()   // 다른 유저로 전환
        XCTAssertTrue(db.recentCuesForWidget().isEmpty)
    }
}
