import XCTest
@testable import ScatchLM

/// HTML bake 치환 로직 회귀 테스트. WKWebView 렌더는 UI 레벨이라 제외하고,
/// 순수 함수인 `BakedMarkdownHTML.bake`만 검증한다.
final class BakedMarkdownHTMLTests: XCTestCase {

    private let template = "<meta content=\"width=__WIDTH__\"><body style=\"font-size:__FONT_SIZE__px\"><script>var c=\"__CONTENT_B64__\";</script></body>"

    func testFontSizeInjectedAsInteger() {
        let html = BakedMarkdownHTML.bake(template: template, content: "hi", fontSize: 14, width: 300)
        XCTAssertTrue(html.contains("font-size:14px"))
        XCTAssertFalse(html.contains("__FONT_SIZE__"))
    }

    func testContentBase64RoundTrips() {
        let content = "수식: $E = mc^2$ \n**bold** `code` \"quote\""
        let html = BakedMarkdownHTML.bake(template: template, content: content, fontSize: 14, width: 300)

        // 플레이스홀더가 모두 치환됐는지
        XCTAssertFalse(html.contains("__CONTENT_B64__"))

        // 삽입된 base64를 추출해 원문으로 복원되는지
        let b64 = Data(content.utf8).base64EncodedString()
        XCTAssertTrue(html.contains(b64))
        let decoded = String(data: Data(base64Encoded: b64)!, encoding: .utf8)
        XCTAssertEqual(decoded, content)
    }

    func testRawContentNotLeakedUnescaped() {
        // base64로 들어가므로 LaTeX/따옴표/백슬래시가 HTML에 그대로 노출되면 안 됨
        let content = "$\\frac{1}{2}$ </script>"
        let html = BakedMarkdownHTML.bake(template: template, content: content, fontSize: 14, width: 300)
        XCTAssertFalse(html.contains("\\frac"))
        XCTAssertFalse(html.contains("</script> "))
    }

    func testEmptyContentProducesValidSubstitution() {
        let html = BakedMarkdownHTML.bake(template: template, content: "", fontSize: 18, width: 300)
        XCTAssertFalse(html.contains("__CONTENT_B64__"))
        XCTAssertTrue(html.contains("font-size:18px"))
    }

    // 고정 폭 주입 — viewport가 device-width에 휘둘리지 않게(스냅샷 폭 = 콘텐츠 레이아웃 폭). 회귀 방지.
    func testWidthInjectedAsInteger() {
        let html = BakedMarkdownHTML.bake(template: template, content: "hi", fontSize: 14, width: 692.4)
        XCTAssertTrue(html.contains("width=692"))   // 반올림 정수
        XCTAssertFalse(html.contains("__WIDTH__"))
    }

    // width=nil → device-width(라이브 webview용, 프레임 폭에 적응).
    func testNilWidthBecomesDeviceWidth() {
        let html = BakedMarkdownHTML.bake(template: template, content: "hi", fontSize: 14, width: nil)
        XCTAssertTrue(html.contains("width=device-width"))
        XCTAssertFalse(html.contains("__WIDTH__"))
    }
}

/// 수식 감지 휴리스틱 회귀 테스트 — 자동 모드 분기의 핵심.
final class MarkdownMathDetectionTests: XCTestCase {

    func testDisplayMathDetected() {
        XCTAssertTrue(MarkdownRender.containsMath("결과: $$E = mc^2$$ 입니다"))
    }

    func testParenAndBracketDelimitersDetected() {
        XCTAssertTrue(MarkdownRender.containsMath("값은 \\(x^2\\) 또는 \\[y\\]"))
    }

    func testBackslashCommandDetected() {
        XCTAssertTrue(MarkdownRender.containsMath("분수 \\frac{1}{2}"))
    }

    func testInlineMathWithMathCharDetected() {
        XCTAssertTrue(MarkdownRender.containsMath("여기 $x_1$ 항"))
        XCTAssertTrue(MarkdownRender.containsMath("$a^2 + b^2$"))
    }

    func testCurrencyNotDetectedAsMath() {
        // 통화 표기는 수식으로 오인되면 안 됨 (auto 모드에서 네이티브 렌더 유지)
        XCTAssertFalse(MarkdownRender.containsMath("이건 $5에서 $10로 올랐다"))
        XCTAssertFalse(MarkdownRender.containsMath("가격은 $100 입니다"))
    }

    func testPlainMarkdownNotDetected() {
        XCTAssertFalse(MarkdownRender.containsMath("**굵게** 그리고 *기울임* 그리고 `code`"))
        XCTAssertFalse(MarkdownRender.containsMath("- 목록\n- 항목"))
    }
}
