import XCTest
@testable import ScatchLM

/// 채팅 글자 크기 설정 회귀 테스트 — 클램프(12~24)·기본값·영속 round-trip 검증.
/// `Config.chatFontSize`는 `UserDefaults.standard`를 직접 읽고 쓰므로, 키를 저장/복원해
/// 다른 테스트·실제 설정에 누출되지 않게 한다.
final class ConfigChatFontSizeTests: XCTestCase {
    private let key = "chatFontSize"
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testDefaultWhenUnset() {
        XCTAssertEqual(Config.chatFontSize, Config.defaultChatFontSize)
        XCTAssertEqual(Config.defaultChatFontSize, 16)
    }

    func testPersistsInRangeValue() {
        Config.chatFontSize = 18
        XCTAssertEqual(Config.chatFontSize, 18)
    }

    func testClampsBelowLowerBound() {
        Config.chatFontSize = 4
        XCTAssertEqual(Config.chatFontSize, Config.chatFontSizeRange.lowerBound)
        XCTAssertEqual(Config.chatFontSizeRange.lowerBound, 12)
    }

    func testClampsAboveUpperBound() {
        Config.chatFontSize = 99
        XCTAssertEqual(Config.chatFontSize, Config.chatFontSizeRange.upperBound)
        XCTAssertEqual(Config.chatFontSizeRange.upperBound, 24)
    }

    /// setter가 클램프 후 저장하므로, 범위 밖 값을 넣어도 읽기는 항상 범위 안.
    func testGetterClampsLegacyOutOfRangeStoredValue() {
        UserDefaults.standard.set(Double(40), forKey: key)
        XCTAssertEqual(Config.chatFontSize, Config.chatFontSizeRange.upperBound)
    }
}
