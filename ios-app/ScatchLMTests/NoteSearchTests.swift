import XCTest
@testable import ScatchLM

/// HomeView 노트 검색(`Note.matchesSearch`) 회귀 테스트.
/// 제목만 매칭하던 동작을 과목(language)·교재명(textbookName)까지 확장한 변경을 고정한다.
final class NoteSearchTests: XCTestCase {

    private func makeNote(title: String, language: String = "", textbookName: String? = nil) -> Note {
        Note(
            id: UUID().uuidString,
            title: title,
            language: language,
            textbookId: textbookName == nil ? nil : "tb",
            textbookName: textbookName,
            textbookPages: 0,
            drawingData: nil,
            lastPage: 1,
            pdfOpen: false,
            currentPageIndex: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testEmptyOrWhitespaceTermMatchesEverything() {
        let note = makeNote(title: "라틴어 문법")
        XCTAssertTrue(note.matchesSearch(""))
        XCTAssertTrue(note.matchesSearch("   "))
    }

    func testMatchesByTitle() {
        let note = makeNote(title: "키케로 연설 정리")
        XCTAssertTrue(note.matchesSearch("키케로"))
        XCTAssertFalse(note.matchesSearch("호메로스"))
    }

    func testMatchesByLanguageSubject() {
        // 과목(language)으로 검색 — 제목엔 없지만 language에 있으면 매칭.
        let note = makeNote(title: "1주차 정리", language: "라틴어")
        XCTAssertTrue(note.matchesSearch("라틴어"))
    }

    func testMatchesByTextbookName() {
        // 연결된 교재명으로 검색.
        let note = makeNote(title: "노트", textbookName: "wheelock_latin.pdf")
        XCTAssertTrue(note.matchesSearch("wheelock"))
    }

    func testCaseInsensitiveAndTrimmed() {
        let note = makeNote(title: "Greek Grammar", language: "Greek")
        XCTAssertTrue(note.matchesSearch("  greek  "))
        XCTAssertTrue(note.matchesSearch("GRAMMAR"))
    }

    func testNoMatchAcrossAllFields() {
        let note = makeNote(title: "수학 정리", language: "수학", textbookName: "calculus.pdf")
        XCTAssertFalse(note.matchesSearch("라틴어"))
    }

    func testNilTextbookNameDoesNotCrashOrMatch() {
        let note = makeNote(title: "제목", language: "en", textbookName: nil)
        XCTAssertFalse(note.matchesSearch("calculus"))
        XCTAssertTrue(note.matchesSearch("제목"))
    }
}
