import XCTest
import SwiftUI
import PencilKit
@testable import ScatchLM

/// iPhone 읽기 전용 캔버스(`ReadOnlyNoteCanvas.Coordinator`)의 좌표 정합·줌 수식 검증
/// (iphone-companion-app-spec §4.5·R2). 편집 캔버스와 동일한 좌표계를 보장해야 카드가
/// iPad와 같은 위치에 얹힌다 — SwiftUI 렌더 사이클 없이 UIKit 직접 호출로 회귀 보장.
final class ReadOnlyNoteCanvasTests: XCTestCase {

    private func makeFeedback(y: Double = 200, content: String = "읽기 전용 카드") -> FeedbackRecord {
        FeedbackRecord(
            id: UUID().uuidString,
            noteId: "test-note",
            pageId: "test-page",
            content: "{\"type\":\"feedback\",\"content\":\"\(content)\"}",
            positionX: 16, positionY: y,
            bboxX: 16, bboxY: y, bboxWidth: 768, bboxHeight: 400,
            strokeRangeStart: 0, strokeRangeEnd: 0,
            createdAt: Date()
        )
    }

    /// makeUIView와 동일한 host > contentView > 읽기전용 canvas 계층을 구성해 coordinator에 연결.
    @MainActor
    private func makeWired(panelWidth: CGFloat, panelHeight: CGFloat = 1000)
        -> (ReadOnlyNoteCanvas.Coordinator, UIScrollView, UIView, PKCanvasView) {
        let coordinator = ReadOnlyNoteCanvas.Coordinator()
        let logical = Config.logicalCanvasWidth
        let host = UIScrollView(frame: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: logical, height: logical * 2))
        host.addSubview(contentView)
        let canvas = PKCanvasView(frame: contentView.bounds)
        canvas.isUserInteractionEnabled = false
        canvas.isScrollEnabled = false
        contentView.addSubview(canvas)
        host.delegate = coordinator
        coordinator.host = host
        coordinator.contentView = contentView
        coordinator.canvas = canvas
        return (coordinator, host, contentView, canvas)
    }

    private func cardCount(in view: UIView) -> Int {
        view.subviews.filter { $0.tag == 9999 }.count
    }

    // MARK: - 카드 좌표 정합 (R2)

    @MainActor
    func testRenderCardsPlacesCardAtPositionY() {
        let (coordinator, _, contentView, _) = makeWired(panelWidth: Config.logicalCanvasWidth)
        let targetY: Double = 480

        coordinator.renderCards([makeFeedback(y: targetY)])

        let card = contentView.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(card)
        XCTAssertEqual(card!.frame.origin.y, CGFloat(targetY), accuracy: 1.0,
            "카드 Y는 fb.positionY 콘텐츠 좌표 그대로 — iPad 편집 캔버스와 정합")
    }

    @MainActor
    func testRenderCardsWidthIsLogicalConstant() {
        let (coordinator, _, contentView, _) = makeWired(panelWidth: Config.logicalCanvasWidth / 2)

        coordinator.renderCards([makeFeedback(y: 200)])

        let card = contentView.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(card)
        XCTAssertEqual(card!.frame.width, Config.logicalCanvasWidth - 32, accuracy: 1.0,
            "카드 폭은 논리폭-32 상수 — 패널 폭/줌과 무관")
    }

    @MainActor
    func testRenderCardsReplacesExisting() {
        let (coordinator, _, contentView, _) = makeWired(panelWidth: Config.logicalCanvasWidth)

        coordinator.renderCards([makeFeedback(y: 100), makeFeedback(y: 500)])
        XCTAssertEqual(cardCount(in: contentView), 2)

        coordinator.renderCards([makeFeedback(y: 300)])
        XCTAssertEqual(cardCount(in: contentView), 1, "renderCards는 기존 카드를 제거하고 새로 렌더")
    }

    @MainActor
    func testRenderEmptyClearsCards() {
        let (coordinator, _, contentView, _) = makeWired(panelWidth: Config.logicalCanvasWidth)
        coordinator.renderCards([makeFeedback(y: 200)])
        XCTAssertEqual(cardCount(in: contentView), 1)

        coordinator.renderCards([])
        XCTAssertEqual(cardCount(in: contentView), 0, "빈 피드백 → 카드 0개")
    }

    // MARK: - zoom-to-fit (편집 캔버스와 동일 식)

    @MainActor
    func testLayoutWidePanelZoom1AndCenters() {
        let logical = Config.logicalCanvasWidth
        let panel = logical + 200
        let (coordinator, host, _, _) = makeWired(panelWidth: panel)

        coordinator.layout()

        XCTAssertEqual(host.zoomScale, 1.0, accuracy: 0.001,
            "패널이 논리폭보다 넓으면 zoom=1 (확대 안 함)")
        XCTAssertEqual(host.contentInset.left, 100, accuracy: 0.5,
            "남는 폭(200)의 절반(100)을 좌우 인셋으로 — 레터박스 중앙정렬")
    }

    @MainActor
    func testLayoutNarrowPanelZoomsToFit() {
        let logical = Config.logicalCanvasWidth
        let panel = logical / 2
        let (coordinator, host, _, _) = makeWired(panelWidth: panel)

        coordinator.layout()

        XCTAssertEqual(host.zoomScale, 0.5, accuracy: 0.001,
            "패널이 논리폭의 절반이면 zoom=0.5로 페이지 전체 축소")
        XCTAssertEqual(host.minimumZoomScale, 0.5, accuracy: 0.001, "minimumZoomScale = fit")
    }

    @MainActor
    func testCardPositionInvariantUnderZoom() {
        let logical = Config.logicalCanvasWidth
        let (coordinator, _, contentView, _) = makeWired(panelWidth: logical / 2)
        coordinator.layout() // zoom=0.5

        coordinator.renderCards([makeFeedback(y: 600)])

        let card = contentView.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(card)
        XCTAssertEqual(card!.frame.origin.y, 600, accuracy: 1.0,
            "zoom=0.5여도 카드 Y는 콘텐츠 좌표 600 그대로 (줌은 표시만)")
    }

    // MARK: - 빈 드로잉 크래시 회귀 (PKDrawing().bounds == CGRect.null → maxY 무한대)

    @MainActor
    func testLayoutWithEmptyDrawingProducesFiniteContentSize() {
        // 빈 페이지(스트로크 없음)의 PKDrawing().bounds는 CGRect.null → maxY가 무한대.
        // 무력화하지 않으면 contentSize가 Inf가 돼 스크롤 인디케이터 레이아웃에서 SIGABRT.
        let (coordinator, host, contentView, canvas) = makeWired(panelWidth: Config.logicalCanvasWidth)
        XCTAssertTrue(canvas.drawing.bounds.isNull, "빈 PKDrawing의 bounds는 null (전제)")

        coordinator.layout()

        XCTAssertTrue(host.contentSize.height.isFinite, "빈 드로잉이어도 contentSize는 유한 (크래시 방지)")
        XCTAssertGreaterThan(host.contentSize.height, 0)
        XCTAssertTrue(contentView.bounds.height.isFinite, "contentView 높이도 유한")
    }

    // MARK: - 필기 오버플로 회귀 (#2: iPad 필기 폭 > iPhone 화면 → zoom-fit으로 축소)

    @MainActor
    func testWideContentWidthZoomsToFitViewport() {
        // iPad에서 그린 넓은 필기(예 800폭)는 종이 폭을 800으로 잡고 iPhone 뷰포트(400)에 맞춰
        // 축소돼야 한다(zoom 0.5). 안 그러면 필기가 화면 밖으로 넘침(#2).
        let (coordinator, host, _, _) = makeWired(panelWidth: 400)
        coordinator.contentWidth = 800
        coordinator.layout()
        XCTAssertEqual(host.zoomScale, 0.5, accuracy: 0.001,
            "종이 800폭을 400 뷰포트에 fit → zoom 0.5 (필기 오버플로 방지)")
    }

    @MainActor
    func testCardWidthFollowsContentWidth() {
        // 카드도 같은 종이 폭(contentWidth)에서 렌더 → 필기와 동일 좌표계 유지.
        let (coordinator, _, contentView, _) = makeWired(panelWidth: 400)
        coordinator.contentWidth = 800
        coordinator.renderCards([makeFeedback(y: 100)])
        let card = contentView.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(card)
        XCTAssertEqual(card!.frame.width, 800 - 32, accuracy: 1.0,
            "카드 폭은 종이 폭(contentWidth)-32 → 필기와 동일 좌표계")
    }
}
