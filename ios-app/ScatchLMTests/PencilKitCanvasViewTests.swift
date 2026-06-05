import XCTest
import SwiftUI
import PencilKit
@testable import ScatchLM

/// Coordinator.renderCard / renderAllCards의 동작을 직접 검증.
/// SwiftUI 렌더 사이클에 의존하지 않고, UIKit 직접 호출로 카드 렌더링을 보장.
final class PencilKitCanvasViewTests: XCTestCase {

    private func makeFeedback(y: Double = 200, content: String = "테스트 피드백") -> FeedbackRecord {
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

    private func cardCount(in canvas: PKCanvasView) -> Int {
        canvas.subviews.filter { $0.tag == 9999 }.count
    }

    private func makeCoordinator() -> PencilKitCanvasView.Coordinator {
        PencilKitCanvasView.Coordinator(onDrawingChanged: {})
    }

    // MARK: - renderCard

    @MainActor
    func testRenderCardAddsSubview() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        let coordinator = makeCoordinator()
        let fb = makeFeedback()

        coordinator.renderCard(on: canvas, feedback: fb)

        XCTAssertEqual(cardCount(in: canvas), 1, "renderCard 호출 후 카드 1개")
    }

    @MainActor
    func testRenderCardPositionMatchesFeedback() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        let coordinator = makeCoordinator()
        let targetY: Double = 450
        let fb = makeFeedback(y: targetY)

        coordinator.renderCard(on: canvas, feedback: fb)

        let card = canvas.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(card)
        XCTAssertEqual(card!.frame.origin.y, CGFloat(targetY), accuracy: 1.0)
    }

    @MainActor
    func testRenderCardUpdatesLastRenderedBottom() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.lastRenderedBottom, 0)

        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 200))

        XCTAssertGreaterThan(coordinator.lastRenderedBottom, 200, "렌더링 후 lastRenderedBottom 갱신")
    }

    @MainActor
    func testRenderCardExpandsContentSize() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        canvas.contentSize = CGSize(width: 800, height: 500)
        let coordinator = makeCoordinator()

        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 400))

        XCTAssertGreaterThan(canvas.contentSize.height, 500, "카드가 contentSize 밖이면 확장")
    }

    // MARK: - renderAllCards

    @MainActor
    func testRenderAllCardsReplacesExisting() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        let coordinator = makeCoordinator()

        // 먼저 2개 렌더
        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 100))
        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 500))
        XCTAssertEqual(cardCount(in: canvas), 2)

        // renderAllCards로 1개만 전달 → 기존 2개 제거, 1개만 렌더
        coordinator.renderAllCards(on: canvas, feedbacks: [makeFeedback(y: 300)])

        XCTAssertEqual(cardCount(in: canvas), 1, "renderAllCards는 기존 카드를 제거하고 새로 렌더")
    }

    @MainActor
    func testRenderAllCardsResetsLastRenderedBottom() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        let coordinator = makeCoordinator()

        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 5000))
        let highBottom = coordinator.lastRenderedBottom

        // 빈 배열로 전체 리렌더 → lastRenderedBottom 리셋
        coordinator.renderAllCards(on: canvas, feedbacks: [])

        XCTAssertEqual(coordinator.lastRenderedBottom, 0, "빈 피드백 시 lastRenderedBottom = 0")
        XCTAssertEqual(cardCount(in: canvas), 0)
    }

    // MARK: - 카드 폭은 논리폭 상수 (bounds 무관) — 네이티브 줌
    // 네이티브 줌 전환 후 카드 폭 = Config.logicalCanvasWidth - 32. bounds.width를 더 이상 추종하지 않으므로
    // PDF 열림으로 bounds가 0이 되거나 회전/divider로 bounds가 바뀌어도 폭이 흔들리지 않는다.

    @MainActor
    func testRenderCardWidthIsLogicalConstantWhenBoundsZero() {
        // PDF 뷰어 열릴 때 SwiftUI가 bounds를 (0,0)으로 만들어도 카드 폭은 논리폭 상수.
        let canvas = PKCanvasView(frame: .zero) // bounds = (0, 0, 0, 0)
        let coordinator = makeCoordinator()

        coordinator.renderCard(on: canvas, feedback: makeFeedback())

        let card = canvas.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(card)
        XCTAssertEqual(card!.frame.width, Config.logicalCanvasWidth - 32, accuracy: 1.0,
            "bounds=0이어도 카드 폭은 논리폭-32 상수")
    }

    @MainActor
    func testRenderAllCardsWidthUnaffectedByBoundsChange() {
        let canvas = PKCanvasView(frame: .zero)
        let coordinator = makeCoordinator()

        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 200))
        let narrowCard = canvas.subviews.first { $0.tag == 9999 }
        let narrowWidth = narrowCard?.frame.width ?? 0

        // bounds가 바뀌어도 폭은 동일(논리폭-32) — 줌이 표시 폭을 흡수하므로 좌표폭은 불변.
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 1200)
        coordinator.renderAllCards(on: canvas, feedbacks: [makeFeedback(y: 200)])

        let restoredCard = canvas.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(restoredCard)
        XCTAssertEqual(restoredCard!.frame.width, Config.logicalCanvasWidth - 32, accuracy: 1.0,
            "bounds 변경과 무관하게 카드 폭은 논리폭-32 상수")
        XCTAssertEqual(narrowWidth, restoredCard!.frame.width, accuracy: 1.0,
            "bounds=0이든 복원 후든 폭이 동일")
    }

    @MainActor
    func testRenderCardWidthStableAcrossBounds() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        let coordinator = makeCoordinator()

        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 100))

        // bounds가 0이 된 상태에서 렌더해도 동일 폭(논리폭-32).
        canvas.frame = .zero
        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 500))

        let cards = canvas.subviews.filter { $0.tag == 9999 }
        XCTAssertEqual(cards.first!.frame.width, cards.last!.frame.width, accuracy: 1.0,
            "bounds가 바뀌어도 카드 폭은 항상 논리폭-32 상수로 동일")
        XCTAssertEqual(cards.last!.frame.width, Config.logicalCanvasWidth - 32, accuracy: 1.0)
    }

    @MainActor
    func testMultipleRenderCardsAccumulate() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 2000))
        let coordinator = makeCoordinator()

        for i in 0..<5 {
            coordinator.renderCard(on: canvas, feedback: makeFeedback(y: Double(100 + i * 300)))
        }

        XCTAssertEqual(cardCount(in: canvas), 5, "renderCard 5번 → 카드 5개 누적")
    }

    // MARK: - 카드 위치 계산 (calculateNextCardY)

    @MainActor
    func testCardPlacedBelowStrokes() {
        // 시나리오: 첫 번째 카드 렌더 후 사용자가 카드 아래에 추가 필기
        // → 두 번째 카드는 필기 아래에 배치되어야 함
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 5000))
        canvas.contentSize = CGSize(width: 800, height: 5000)
        let coordinator = makeCoordinator()

        // 1. 첫 번째 카드를 y=500에 렌더 (lastRenderedBottom ≈ 548)
        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 500))
        let firstCardBottom = coordinator.lastRenderedBottom // ≈ 548
        let nextCardAfterFirst = firstCardBottom + 24

        // 2. 사용자가 y=1500~2300 영역에 추가 필기 (카드 아래)
        var drawing = PKDrawing()
        let ink = PKInkingTool(.pen, color: .black, width: 3).ink
        // y=1500에서 y=2300까지의 스트로크 생성
        let points = [
            PKStrokePoint(location: CGPoint(x: 100, y: 1500), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2),
            PKStrokePoint(location: CGPoint(x: 200, y: 2300), timeOffset: 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)
        canvas.drawing = PKDrawing(strokes: [stroke])

        let strokeMaxY = canvas.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }

        // 3. calculateNextCardY: 카드가 필기 아래에 배치되어야 함
        let nextY = coordinator.calculateNextCardY(on: canvas, currentNextCardY: nextCardAfterFirst)

        XCTAssertGreaterThan(nextY, strokeMaxY,
            "두 번째 카드 Y(\(nextY))는 스트로크 maxY(\(strokeMaxY)) 아래여야 함 — 필기를 덮으면 안 됨")
    }

    @MainActor
    func testBugReproduction_cardOverlapsStrokesWithOldLogic() {
        // 수정 전 로직 재현: lastRenderedBottom만 보고 스트로크 maxY를 무시
        // → 카드가 필기 위에 배치됨
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 5000))
        let coordinator = makeCoordinator()

        // 1. 첫 카드 렌더
        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 500))
        let firstCardBottom = coordinator.lastRenderedBottom

        // 2. 사용자가 카드 아래(y=1500~2300)에 필기
        let ink = PKInk(.pen, color: .black)
        let points = [
            PKStrokePoint(location: CGPoint(x: 100, y: 1500), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2),
            PKStrokePoint(location: CGPoint(x: 200, y: 2300), timeOffset: 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        canvas.drawing = PKDrawing(strokes: [PKStroke(ink: ink, path: path)])

        // 수정 전 로직: lastRenderedBottom + 24만 사용, 스트로크 무시
        let buggyNextY = firstCardBottom + 24

        let strokeMaxY = canvas.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }

        // 버그 재현: 수정 전 로직의 Y가 스트로크 maxY보다 작음 → 카드가 필기를 덮음
        XCTAssertLessThan(buggyNextY, strokeMaxY,
            "수정 전 로직: nextY(\(buggyNextY)) < strokeMaxY(\(strokeMaxY)) — 카드가 필기를 덮는 버그")

        // 수정 후 로직: calculateNextCardY는 스트로크도 체크
        let fixedNextY = coordinator.calculateNextCardY(on: canvas, currentNextCardY: buggyNextY)
        XCTAssertGreaterThan(fixedNextY, strokeMaxY,
            "수정 후 로직: nextY(\(fixedNextY)) > strokeMaxY(\(strokeMaxY)) — 필기 아래 배치")
    }

    // MARK: - 폭 SSOT (currentWidth) — 네이티브 줌(논리폭 상수)
    // 네이티브 줌 전환(canvas-native-zoom-spec §4.2): contentView 폭이 항상 논리폭이므로
    // currentWidth는 bounds.width 추종을 버리고 Config.logicalCanvasWidth 상수를 반환한다.
    // (줌 중 bounds가 흔들려도 카드/오버레이/indicator가 동일 폭을 본다.)

    @MainActor
    func testCurrentWidthIsLogicalConstantForValidBounds() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 640, height: 1000))
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.currentWidth(canvas), Config.logicalCanvasWidth, accuracy: 0.5,
            "bounds.width와 무관하게 논리폭 상수를 폭 SSOT로 사용")
    }

    @MainActor
    func testCurrentWidthIsLogicalConstantWhenBoundsZero() {
        let canvas = PKCanvasView(frame: .zero)
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.currentWidth(canvas), Config.logicalCanvasWidth, accuracy: 0.5,
            "bounds=0이어도 논리폭 상수 — 줌 중 bounds가 흔들려도 안전")
    }

    // MARK: - 논리폭 상수 (Option A)

    func testLogicalCanvasWidthIsDevicePortraitWidth() {
        let screen = UIScreen.main.bounds
        let expected = min(screen.width, screen.height)
        XCTAssertEqual(Config.logicalCanvasWidth, expected, accuracy: 0.5,
            "논리폭은 기기 세로폭(짧은 변)에 고정 — orientation 무관 단일 좌표계")
    }

    // MARK: - 네이티브 줌: zoom-to-fit / 중앙정렬 / 좌표 불변 (canvas-native-zoom-spec §4.3, §6-7)
    // 실기기 전용(펜 선명도·툴피커)이 아닌, host/contentView 좌표·줌 수식 부분을 단위 레벨로 검증.

    /// makeUIView와 동일한 host > contentView > canvas 계층을 구성하고 coordinator에 연결.
    @MainActor
    private func makeWiredCoordinator(panelWidth: CGFloat, panelHeight: CGFloat = 1000)
        -> (PencilKitCanvasView.Coordinator, UIScrollView, UIView, PKCanvasView) {
        let coordinator = makeCoordinator()
        let logical = Config.logicalCanvasWidth
        let host = UIScrollView(frame: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: logical, height: logical * 2))
        host.addSubview(contentView)
        host.contentSize = contentView.bounds.size
        let canvas = PKCanvasView(frame: contentView.bounds)
        canvas.isScrollEnabled = false
        contentView.addSubview(canvas)
        host.delegate = coordinator
        coordinator.host = host
        coordinator.contentView = contentView
        coordinator.canvas = canvas
        return (coordinator, host, contentView, canvas)
    }

    @MainActor
    func testApplyPanelLayoutWidePanelZoom1AndCenters() {
        let logical = Config.logicalCanvasWidth
        let panel = logical + 200
        let (coordinator, host, _, _) = makeWiredCoordinator(panelWidth: panel)

        coordinator.applyPanelLayout(panelWidth: panel)

        XCTAssertEqual(host.zoomScale, 1.0, accuracy: 0.001,
            "패널이 논리폭보다 넓으면 zoom=1 (확대하지 않음)")
        XCTAssertEqual(host.contentInset.left, 100, accuracy: 0.5,
            "남는 폭(200)의 절반(100)을 좌우 인셋으로 — 레터박스 중앙정렬")
        XCTAssertEqual(host.contentInset.right, 100, accuracy: 0.5)
    }

    @MainActor
    func testApplyPanelLayoutNarrowPanelZoomsToFit() {
        let logical = Config.logicalCanvasWidth
        let panel = logical / 2
        let (coordinator, host, _, _) = makeWiredCoordinator(panelWidth: panel)

        coordinator.applyPanelLayout(panelWidth: panel)

        XCTAssertEqual(host.zoomScale, 0.5, accuracy: 0.001,
            "패널이 논리폭의 절반이면 zoom=0.5로 페이지 전체 축소")
        XCTAssertEqual(host.minimumZoomScale, 0.5, accuracy: 0.001,
            "minimumZoomScale = fit")
        XCTAssertEqual(host.contentInset.left, 0, accuracy: 0.5,
            "축소되면 콘텐츠가 패널을 가득 채우므로 가로 인셋 없음")
    }

    @MainActor
    func testCenterUsesPanelWidthNotStaleHostBounds() {
        // divider 드래그 중 host.bounds가 안 줄어드는(stale) 상황 재현 — 인셋은 panelWidth(SSOT)로
        // 계산돼야 줌(panelWidth 기준)과 어긋나지 않는다. (회전 후 divider "망가짐" 진동 버그 회귀 방지.)
        let logical = Config.logicalCanvasWidth
        let panel = logical / 2
        let (coordinator, host, _, _) = makeWiredCoordinator(panelWidth: panel)
        // host.bounds를 panelWidth보다 큰 stale 값으로 (회전 직후 넓은 폭에서 안 줄어든 상태)
        host.frame = CGRect(x: 0, y: 0, width: logical + 108, height: 1000)

        coordinator.applyPanelLayout(panelWidth: panel) // zoom=0.5, lastPanelWidth=panel

        XCTAssertEqual(host.contentInset.left, 0, accuracy: 1.0,
            "인셋은 stale host.bounds(넓음)가 아니라 panelWidth 기준 → 0 (줌/인셋 진동 방지)")
    }

    @MainActor
    func testSetContentHeightExpandsAndPreservesTopLeft() {
        let logical = Config.logicalCanvasWidth
        let (coordinator, host, contentView, canvas) = makeWiredCoordinator(panelWidth: logical)
        // zoom=1 (기본)

        coordinator.setContentHeight(3000)

        XCTAssertEqual(contentView.bounds.height, 3000, accuracy: 0.5,
            "contentView 높이 확장")
        XCTAssertEqual(canvas.frame.height, 3000, accuracy: 0.5,
            "canvas는 contentView.bounds를 추종")
        XCTAssertEqual(host.contentSize.height, 3000, accuracy: 0.5,
            "host.contentSize = 높이 × zoom(1)")
        XCTAssertEqual(contentView.frame.origin.y, 0, accuracy: 0.5,
            "아래로만 확장 — top-left 고정")
    }

    @MainActor
    func testCardPositionInvariantUnderZoom() {
        // 줌은 표시만 — 카드의 contentView 좌표(positionY)는 zoom과 무관하게 그대로.
        let logical = Config.logicalCanvasWidth
        let (coordinator, _, contentView, canvas) = makeWiredCoordinator(panelWidth: logical / 2)
        coordinator.applyPanelLayout(panelWidth: logical / 2) // zoom=0.5

        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 600))

        let card = contentView.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(card)
        XCTAssertEqual(card!.frame.origin.y, 600, accuracy: 1.0,
            "zoom=0.5여도 카드 Y는 contentView 좌표 600 그대로 (줌은 표시만)")
        XCTAssertEqual(card!.frame.width, logical - 32, accuracy: 1.0,
            "카드 폭도 zoom과 무관하게 논리폭-32")
    }

    @MainActor
    func testResetToTopResetsHeightAndOffset() {
        let logical = Config.logicalCanvasWidth
        let (coordinator, host, contentView, _) = makeWiredCoordinator(panelWidth: logical / 2)
        coordinator.applyPanelLayout(panelWidth: logical / 2) // zoom=0.5, inset.left=0
        coordinator.ensureContentHeight(8000)

        coordinator.resetToTop()

        // h = max((vh/zoom)*1.5, logical) = max((1000/0.5)*1.5, logical) = 3000
        XCTAssertEqual(contentView.bounds.height, 3000, accuracy: 1.0,
            "기본 높이((viewport/zoom)*1.5)로 축소")
        XCTAssertEqual(host.contentOffset.y, 0, accuracy: 0.5,
            "최상단으로(-contentInset.top=0)")
    }
}
