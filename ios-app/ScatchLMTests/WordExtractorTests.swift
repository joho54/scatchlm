import XCTest
@testable import ScatchLM

/// DMN 타이머 단서 추출 회귀 테스트. 중요도는 LLM의 볼드(**...**) 강조에서 가져오고,
/// `WordExtractor`는 그 스팬을 기계적으로 추출하기만 한다. 그 추출 규칙을 검증한다.
final class WordExtractorTests: XCTestCase {

    func testExtractsBoldSpan() {
        let words = WordExtractor.importantWords(from: ["**속격**은 소유를 나타냅니다"])
        XCTAssertEqual(words, ["속격"])
    }

    func testIgnoresNonBoldText() {
        // 굵게 강조 안 된 본문에서는 아무것도 뽑지 않는다(빈도/불용어 추정 안 함)
        let words = WordExtractor.importantWords(from: ["속격은 소유를 나타내고 여격은 간접목적어다"])
        XCTAssertTrue(words.isEmpty)
    }

    func testExtractsUnderscoreBold() {
        let words = WordExtractor.importantWords(from: ["__탈격__ 참고"])
        XCTAssertEqual(words, ["탈격"])
    }

    func testDropsLongBoldSentences() {
        // 문장 통째로 굵게 친 것은 단서로 부적합 — 단어 수/길이 초과로 제외
        let words = WordExtractor.importantWords(from: ["**이 부분은 매우 길고 여러 단어로 된 문장입니다**"])
        XCTAssertTrue(words.isEmpty)
    }

    func testAllowsShortMultiWordPhrase() {
        let words = WordExtractor.importantWords(from: ["**부정 과거**는 중요하다"])
        XCTAssertEqual(words, ["부정 과거"])
    }

    func testStripsEdgePunctuation() {
        let words = WordExtractor.importantWords(from: ["**속격.** 그리고 **여격,**"])
        XCTAssertEqual(words, ["속격", "여격"])
    }

    func testDeduplicatesCaseInsensitively() {
        let words = WordExtractor.importantWords(from: ["**Gen** ... **gen**", "**GEN**"])
        XCTAssertEqual(words, ["Gen"])
    }

    func testPreservesRecencyOrderAcrossFeedbacks() {
        // 입력은 최신 → 과거 순서. 최신 피드백 단서가 앞에.
        let words = WordExtractor.importantWords(from: ["**여격**", "**속격**"])
        XCTAssertEqual(words, ["여격", "속격"])
    }

    func testRejectsPureNumberBold() {
        let words = WordExtractor.importantWords(from: ["**123** 그리고 **속격**"])
        XCTAssertEqual(words, ["속격"])
    }

    func testRespectsLimit() {
        let content = (0..<30).map { "**개념\($0)**" }.joined(separator: " ")
        let words = WordExtractor.importantWords(from: [content], limit: 5)
        XCTAssertEqual(words.count, 5)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(WordExtractor.importantWords(from: []).isEmpty)
        XCTAssertTrue(WordExtractor.importantWords(from: ["", "강조 없는 본문"]).isEmpty)
    }
}
