import XCTest
@testable import ScatchLM

/// 위젯 딥링크 계약 회귀 테스트.
///
/// 위젯(`WidgetShared.deepLink`)이 만드는 URL과 앱(`DeepLinkRouter.handle`)이 파싱하는
/// 형식은 한 쌍이다 — 한쪽만 바뀌면 위젯 탭이 조용히 깨진다. 라운드트립으로 둘을 묶어 둔다.
final class WidgetDeepLinkTests: XCTestCase {

    private func cue(session: String?, note: String) -> WidgetCue {
        WidgetCue(id: "c1", keyword: "역전파", sessionId: session, noteId: note,
                  createdAt: Date(timeIntervalSince1970: 0))
    }

    func testSessionCueRoundTrips() {
        let url = WidgetShared.deepLink(for: cue(session: "sess-123", note: "note-9"))
        XCTAssertNotNil(url)

        let router = DeepLinkRouter()
        router.handle(url!)

        XCTAssertEqual(router.pending?.id, "sess-123")
        XCTAssertEqual(router.pending?.noteId, "note-9")
    }

    func testLegacyCueFallsBackToNoteLink() {
        // 세션 없는(레거시/가이드) 단서는 note 링크로 폴백 — 세션 시트는 못 열어도 깨지진 않는다.
        let url = WidgetShared.deepLink(for: cue(session: nil, note: "note-9"))
        XCTAssertEqual(url?.host, "note")

        let router = DeepLinkRouter()
        router.handle(url!)
        // note 링크는 세션 점프 대상이 없으므로 pending은 설정되지 않는다.
        XCTAssertNil(router.pending)
    }

    func testEmptySessionTreatedAsLegacy() {
        let url = WidgetShared.deepLink(for: cue(session: "", note: "note-9"))
        XCTAssertEqual(url?.host, "note")
    }

    func testForeignSchemeIgnored() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "https://example.com/session/x")!)
        XCTAssertNil(router.pending)
    }
}
