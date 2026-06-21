import XCTest
@testable import ScatchLM

/// DMN 타이머 단어 추출 회귀 테스트. UI(슬라이드 애니메이션)는 제외하고,
/// 순수 함수인 `WordExtractor.importantWords`의 룰 베이스 동작만 검증한다.
final class WordExtractorTests: XCTestCase {

    func testStripsMarkdownMarkers() {
        let words = WordExtractor.importantWords(from: ["**중요** `코드` # 제목"])
        // 마크업 문자(*, `, #)가 단어에 섞여 나오면 안 됨
        XCTAssertFalse(words.contains { $0.contains("*") || $0.contains("`") || $0.contains("#") })
    }

    func testRemovesCodeBlocksAndLatex() {
        let words = WordExtractor.importantWords(from: ["설명 ```let x = 99``` 수식 $E = mc^2$ 끝맺음"])
        // 코드/수식 내부 토큰은 제외
        XCTAssertFalse(words.contains("let"))
        XCTAssertFalse(words.contains("mc"))
    }

    func testKeepsLinkDisplayTextDropsURL() {
        let words = WordExtractor.importantWords(from: ["[문법설명](https://example.com/page) 참조"])
        XCTAssertTrue(words.contains("문법설명"))
        XCTAssertFalse(words.contains { $0.contains("example") || $0.contains("https") })
    }

    func testFiltersStopwordsAndPureNumbers() {
        let words = WordExtractor.importantWords(from: ["그리고 the 123 동사변화"])
        XCTAssertFalse(words.contains("그리고"))
        XCTAssertFalse(words.contains("the"))
        XCTAssertFalse(words.contains("123"))
        XCTAssertTrue(words.contains("동사변화"))
    }

    func testStripsKoreanJosa() {
        // "동사변화를" → 조사 "를" 제거 → "동사변화"
        let words = WordExtractor.importantWords(from: ["동사변화를 동사변화는 동사변화"])
        XCTAssertTrue(words.contains("동사변화"))
        XCTAssertFalse(words.contains("동사변화를"))
    }

    func testRanksByFrequency() {
        let contents = ["속격 속격 속격 여격", "탈격"]
        let words = WordExtractor.importantWords(from: contents)
        // 가장 빈번한 단어가 맨 앞
        XCTAssertEqual(words.first, "속격")
    }

    func testRespectsLimit() {
        let many = (0..<100).map { "단어\($0)koreanword" }.joined(separator: " ")
        let words = WordExtractor.importantWords(from: [many], limit: 10)
        XCTAssertLessThanOrEqual(words.count, 10)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(WordExtractor.importantWords(from: []).isEmpty)
        XCTAssertTrue(WordExtractor.importantWords(from: ["", "  ", "## ---"]).isEmpty)
    }

    func testDeduplicatesCaseInsensitively() {
        let words = WordExtractor.importantWords(from: ["Genitive genitive GENITIVE 여격"])
        let genitiveCount = words.filter { $0.lowercased() == "genitive" }.count
        XCTAssertEqual(genitiveCount, 1)
    }
}
