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

    // MARK: - bounds=0 재현 (PDF 열기 시)

    @MainActor
    func testRenderCardWithZeroBoundsUsesMinWidth() {
        // PDF 뷰어 열릴 때 SwiftUI가 bounds를 (0,0)으로 만드는 상황 재현
        let canvas = PKCanvasView(frame: .zero) // bounds = (0, 0, 0, 0)
        let coordinator = makeCoordinator()

        coordinator.renderCard(on: canvas, feedback: makeFeedback())

        let card = canvas.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(card)
        // 최소 300 이상이어야 함 — 0이나 -32가 되면 안 됨
        XCTAssertGreaterThanOrEqual(card!.frame.width, 300,
            "bounds=0일 때도 카드 width는 최소값 이상이어야 함")
    }

    @MainActor
    func testRenderAllCardsAfterBoundsRestore() {
        let canvas = PKCanvasView(frame: .zero)
        let coordinator = makeCoordinator()

        // bounds=0 상태에서 렌더
        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 200))
        let narrowCard = canvas.subviews.first { $0.tag == 9999 }
        let narrowWidth = narrowCard?.frame.width ?? 0

        // bounds 복원 후 renderAllCards
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 1200)
        coordinator.renderAllCards(on: canvas, feedbacks: [makeFeedback(y: 200)])

        let restoredCard = canvas.subviews.first { $0.tag == 9999 }
        XCTAssertNotNil(restoredCard)
        XCTAssertEqual(restoredCard!.frame.width, 768, accuracy: 1.0,
            "bounds 복원 후 renderAllCards는 정상 width(800-32)로 렌더")
    }

    @MainActor
    func testRenderCardPreservesLastKnownWidth() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        let coordinator = makeCoordinator()

        // 정상 bounds에서 먼저 렌더 → lastKnownWidth 저장
        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 100))

        // bounds가 0이 된 상태에서 렌더
        canvas.frame = .zero
        coordinator.renderCard(on: canvas, feedback: makeFeedback(y: 500))

        let cards = canvas.subviews.filter { $0.tag == 9999 }
        let secondCard = cards.last!
        // 이전에 알고 있던 width(768)를 사용해야 함
        XCTAssertEqual(secondCard.frame.width, 768, accuracy: 1.0,
            "bounds=0이어도 마지막으로 알려진 width로 렌더")
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

    // MARK: - 폭 SSOT (currentWidth) — Track P

    @MainActor
    func testCurrentWidthUsesBoundsWidth() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 640, height: 1000))
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.currentWidth(canvas), 640, accuracy: 0.5,
            "bounds.width가 유효하면 그 값을 폭 SSOT로 사용")
    }

    @MainActor
    func testCurrentWidthFallsBackToLastKnownWhenBoundsZero() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 640, height: 1000))
        let coordinator = makeCoordinator()

        // 유효 bounds에서 한 번 읽어 lastKnownWidth 기억
        _ = coordinator.currentWidth(canvas)

        // bounds가 0이 되어도 마지막으로 알려진 폭으로 폴백
        canvas.frame = .zero
        XCTAssertEqual(coordinator.currentWidth(canvas), 640, accuracy: 0.5,
            "bounds=0이면 마지막으로 알려진 폭으로 폴백")
    }

    @MainActor
    func testCurrentWidthDefaultsWhenNeverKnown() {
        let canvas = PKCanvasView(frame: .zero)
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.currentWidth(canvas), 800, accuracy: 0.5,
            "유효 폭을 한 번도 못 본 상태에선 기본값 800으로 폴백")
    }

    // MARK: - 논리폭 상수 (Option A)

    func testLogicalCanvasWidthIsDevicePortraitWidth() {
        let screen = UIScreen.main.bounds
        let expected = min(screen.width, screen.height)
        XCTAssertEqual(Config.logicalCanvasWidth, expected, accuracy: 0.5,
            "논리폭은 기기 세로폭(짧은 변)에 고정 — orientation 무관 단일 좌표계")
    }
}
