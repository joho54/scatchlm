import SwiftUI
import PencilKit
import PDFKit
import UniformTypeIdentifiers
import MarkdownUI

// Custom tap gesture that carries a FeedbackRecord
class FeedbackTapGesture: UITapGestureRecognizer {
    var feedbackRecord: FeedbackRecord?
}

struct NoteView: View {
    let noteId: String

    @Environment(\.dismiss) private var dismiss
    @State private var note: Note?
    @State private var canvasView = PKCanvasView()
    @State private var feedbacks: [FeedbackRecord] = []
    @State private var loading = false
    @State private var pdfOpen = false
    @State private var currentPage: Int = 1
    @State private var chatFeedback: FeedbackRecord?
    @State private var ratingSheetFeedback: FeedbackRecord?
    @State private var toastMessage: String?
    @State private var pendingRevert: FeedbackRecord?
    private static let toastDedupeWindow: TimeInterval = 2.0
    @State private var lastToastShownAt: Date?
    @State private var lastToastMessage: String?
    // Page system
    @State private var notePages: [NotePage] = []
    @State private var currentPageIndex: Int = 0
    @State private var currentNotePage: NotePage?
    // 다음 카드가 배치될 Y 위치 — 모든 카드/피드백 추가 시 갱신
    @State private var nextCardY: CGFloat = 100
    // 시뮬레이터 전용 — 마우스로 스크롤하려면 .pencilOnly로 전환 (true=스크롤 모드)
    @State private var simScrollMode: Bool = false
    @State private var pageNavOpen: Bool = false
    @State private var canUndo: Bool = false
    @State private var canRedo: Bool = false

    private let db = DatabaseService.shared

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    private var isLandscape: Bool {
        vSizeClass == .compact || (hSizeClass == .regular && vSizeClass == .regular && UIScreen.main.bounds.width > UIScreen.main.bounds.height)
    }

    var body: some View {
        GeometryReader { geo in

            ZStack {
                if let note {
                    // Split view: Canvas + PDF
                    if isLandscape && pdfOpen {
                        HStack(spacing: 0) {
                            pdfPanel(note: note)
                                .frame(width: geo.size.width * 0.4)
                            Divider()
                            canvasPanel(note: note)
                        }
                    } else if pdfOpen {
                        VStack(spacing: 0) {
                            pdfPanel(note: note)
                                .frame(height: geo.size.height * 0.4)
                            Divider()
                            canvasPanel(note: note)
                        }
                    } else {
                        canvasPanel(note: note)
                    }

                    // Toast
                    if let msg = toastMessage {
                        VStack {
                            Spacer()
                            Text(msg)
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .padding(.bottom, 160)
                                .transition(.opacity)
                        }
                        .allowsHitTesting(false)
                    }

                    // Loading indicator
                    if loading {
                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Analyzing handwriting...")
                                    .font(.subheadline)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 100)
                        }
                    }

                    // Back + page navigator moved into canvasPanel overlay

                    // FAB
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            fabPill(note: note)
                                .padding(.trailing, 20)
                                .padding(.bottom, 32)
                        }
                    }

                    // Page navigator slide-over (좌측)
                    if pageNavOpen {
                        // Dismiss-on-tap-outside scrim
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                    pageNavOpen = false
                                }
                            }

                        HStack(spacing: 0) {
                            PageNavigatorView(
                                pages: notePages,
                                currentIndex: currentPageIndex,
                                onSelect: { idx in
                                    goToPage(index: idx)
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                        pageNavOpen = false
                                    }
                                },
                                onAdd: {
                                    newPage()
                                },
                                onClose: {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                        pageNavOpen = false
                                    }
                                }
                            )
                            .transition(.move(edge: .leading))
                            Spacer()
                        }
                        .ignoresSafeArea(.container, edges: .bottom)
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: .bottom)
        .sheet(item: $chatFeedback) { fb in
            FeedbackChatSheet(feedback: fb, textbookId: note?.textbookId, currentPage: currentPage, onPin: { content in
                pinToCanvas(content: content)
            })
        }
        .sheet(item: $ratingSheetFeedback) { fb in
            FeedbackRatingSheet(
                feedbackId: fb.serverFeedbackId ?? fb.id,
                initialRating: fb.userRating ?? 1
            ) { rating, tags, comment in
                submitRating(feedback: fb, rating: rating, reasonTags: tags, comment: comment)
            }
        }
        .alert("이 피드백을 되돌리시겠습니까?", isPresented: Binding(
            get: { pendingRevert != nil },
            set: { if !$0 { pendingRevert = nil } }
        )) {
            Button("취소", role: .cancel) { pendingRevert = nil }
            Button("되돌리기", role: .destructive) {
                if let fb = pendingRevert { revertFeedback(fb) }
                pendingRevert = nil
            }
        } message: {
            Text("카드가 사라지고 해당 영역에 다시 필기할 수 있게 됩니다. 필기 자체는 남습니다.")
        }
        .task { await loadNote() }
        .onDisappear { saveDrawing() }
    }

    // MARK: - Canvas Panel

    @ViewBuilder
    private func canvasPanel(note: Note) -> some View {
        PencilKitCanvasView(
            canvasView: $canvasView,
            onDrawingChanged: {
                saveDrawing()
                refreshUndoState()
            },
            onStrokeChanged: {
                refreshUndoState()
            },
            initialDrawingData: currentNotePage?.drawingData ?? note.drawingData,
            feedbacks: feedbacks,
            onFeedbackTapped: { fb in
                chatFeedback = fb
            },
            onFeedbackRevert: { fb in
                pendingRevert = fb
            },
            onStrokeRejected: {
                showToast("이 영역은 피드백이 완료됐습니다. 되돌리려면 카드의 ↩︎를 누르세요")
            },
            onFeedbackRate: { fb, rating in
                submitRating(feedback: fb, rating: rating, reasonTags: [], comment: nil)
            },
            onFeedbackRateDetail: { fb in
                ratingSheetFeedback = fb
            }
        )
        .clipped()
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                Button {
                    saveDrawing()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                }

                Button {
                    if notePages.count <= 1 {
                        newPage()
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            pageNavOpen.toggle()
                        }
                    }
                } label: {
                    Image(systemName: notePages.count <= 1 ? "plus.rectangle" : "sidebar.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                }
            }
            .padding(.leading, 12)
            .padding(.top, 12)
        }
    }

    // MARK: - PDF Panel

    @ViewBuilder
    private func pdfPanel(note: Note) -> some View {
        if let textbookId = note.textbookId {
            PdfViewerView(
                textbookId: textbookId,
                totalPages: note.textbookPages,
                initialPage: currentPage,
                onPageChanged: { page in
                    currentPage = page
                    try? db.updateLastPage(noteId: noteId, page: page)
                },
                onClose: {
                    pdfOpen = false
                    try? db.updatePdfOpen(noteId: noteId, open: false)
                },
                onPin: { content in
                    pinToCanvas(content: content)
                }
            )
        }
    }

    // MARK: - FAB Pill

    @ViewBuilder
    private func fabPill(note: Note) -> some View {
        VStack(spacing: 8) {
            // Main FAB
            HStack(spacing: 2) {
                #if targetEnvironment(simulator)
                // Sim-only: 펜/스크롤 모드 토글
                Button {
                    simScrollMode.toggle()
                    canvasView.drawingPolicy = simScrollMode ? .pencilOnly : .anyInput
                    appLog("note", "sim mode", ["scroll": "\(simScrollMode)"])
                } label: {
                    Image(systemName: simScrollMode ? "hand.draw" : "scribble")
                        .font(.system(size: 18))
                        .foregroundStyle(simScrollMode ? .white : .secondary)
                        .frame(width: 48, height: 48)
                        .background(simScrollMode ? Color.blue.opacity(0.7) : .clear)
                        .clipShape(Circle())
                }
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 24)
                #endif

                // Tool picker toggle
                Button {
                    if let delegate = canvasView.delegate as? PencilKitCanvasView.Coordinator,
                       let picker = delegate.toolPicker {
                        delegate.toolPickerVisible.toggle()
                        picker.setVisible(delegate.toolPickerVisible, forFirstResponder: canvasView)
                        if delegate.toolPickerVisible {
                            canvasView.becomeFirstResponder()
                        }
                    }
                } label: {
                    Image(systemName: "pencil.tip")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                }

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 24)

                // Undo
                Button {
                    canvasView.undoManager?.undo()
                    refreshUndoState()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 18))
                        .foregroundStyle(canUndo ? .secondary : Color.secondary.opacity(0.35))
                        .frame(width: 44, height: 48)
                }
                .disabled(!canUndo)

                // Redo
                Button {
                    canvasView.undoManager?.redo()
                    refreshUndoState()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 18))
                        .foregroundStyle(canRedo ? .secondary : Color.secondary.opacity(0.35))
                        .frame(width: 44, height: 48)
                }
                .disabled(!canRedo)

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 24)

                // PDF toggle
                Button {
                    if note.textbookId != nil {
                        pdfOpen.toggle()
                        try? db.updatePdfOpen(noteId: noteId, open: pdfOpen)
                    }
                } label: {
                    Image(systemName: pdfOpen ? "book.fill" : "book")
                        .font(.system(size: 22))
                        .foregroundStyle(pdfOpen ? .white : .secondary)
                        .frame(width: 48, height: 48)
                        .background(pdfOpen ? Color(white: 0, opacity: 0.7) : .clear)
                        .clipShape(Circle())
                }

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 24)

                // Feedback request
                Button {
                    requestFeedback()
                } label: {
                    if loading {
                        ProgressView()
                            .frame(width: 48, height: 48)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 26))
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                    }
                }
                .disabled(loading)
            }
            .padding(4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        }
    }

    // MARK: - Data

    private func loadNote() async {
        do {
            note = try db.note(id: noteId)

            if let note, note.pdfOpen, note.textbookId != nil {
                pdfOpen = true
            }
            currentPage = note?.lastPage ?? 1
            currentPageIndex = note?.currentPageIndex ?? 0

            // Load pages
            notePages = try db.pages(noteId: noteId)
            if notePages.isEmpty {
                // First time — create page 0
                let page = try db.createPage(noteId: noteId, pageIndex: 0)
                notePages = [page]
            }

            // Load current page
            loadPage(index: currentPageIndex)

            appLog("note", "loaded", [
                "id": noteId,
                "hasPdf": "\(note?.textbookId != nil)",
                "pages": "\(notePages.count)",
                "currentPage": "\(currentPageIndex)",
            ])
        } catch {
            appLogError("note", "load failed", ["error": "\(error)"])
        }
    }

    /// 초기 로드 시 페이지 설정 (loadNote에서 호출)
    private func loadPage(index: Int) {
        guard index >= 0, index < notePages.count else { return }
        let page = notePages[index]
        currentNotePage = page
        currentPageIndex = index

        // coordinator의 렌더링 높이 리셋
        if let delegate = canvasView.delegate as? PencilKitCanvasView.Coordinator {
            delegate.lastRenderedBottom = 0
            delegate.frozenBottom = 0
            delegate.frozenEndIndex = 0
            delegate.previousStrokeCount = 0
        }

        feedbacks = (try? db.feedbacks(pageId: page.id)) ?? []
        nextCardY = 100

        appLog("note", "loadPage", ["index": "\(index)", "feedbacks": "\(feedbacks.count)"])
    }

    /// 피드백/박제 카드를 캔버스에 추가하는 공통 함수
    private func appendFeedbackCard(content: String, estimatedHeight: CGFloat = 400, strokeRangeStart: Int? = nil, strokeRangeEnd: Int? = nil, serverFeedbackId: String? = nil) {
        // Coordinator에게 카드 Y 위치 계산 위임
        let coordinator = canvasView.delegate as? PencilKitCanvasView.Coordinator
        if let coordinator {
            nextCardY = coordinator.calculateNextCardY(
                on: canvasView,
                currentNextCardY: nextCardY
            )
        }

        let width = canvasView.bounds.width - 32
        let totalStrokes = canvasView.drawing.strokes.count
        let rangeStart = strokeRangeStart ?? (coordinator?.frozenEndIndex ?? 0)
        let rangeEnd = strokeRangeEnd ?? totalStrokes
        var record = FeedbackRecord(
            id: UUID().uuidString,
            noteId: noteId,
            pageId: currentNotePage?.id,
            content: content,
            positionX: 16,
            positionY: nextCardY,
            bboxX: 16,
            bboxY: nextCardY,
            bboxWidth: width,
            bboxHeight: estimatedHeight,
            strokeRangeStart: rangeStart,
            strokeRangeEnd: rangeEnd,
            createdAt: Date(),
            serverFeedbackId: serverFeedbackId
        )
        try? db.saveFeedback(&record)
        feedbacks.append(record)

        // UIKit 직접 렌더 — SwiftUI updateUIView에 의존하지 않음
        if let coordinator {
            // 이전 "마지막" 카드의 되돌리기 버튼 제거 — revert는 가장 마지막 피드백에서만 허용
            for card in canvasView.subviews where card.tag == 9999 {
                func stripRevert(_ v: UIView) {
                    for sub in v.subviews {
                        if sub.tag == 8888 { sub.removeFromSuperview() } else { stripRevert(sub) }
                    }
                }
                stripRevert(card)
            }
            coordinator.renderCard(on: canvasView, feedback: record, isLast: true)
            // 실제 렌더 후 bbox 높이 동기화 → frozenBottom 재계산
            if let card = canvasView.subviews.first(where: { $0.tag == 9999 && $0.accessibilityIdentifier == record.id }) {
                let actualBottom = card.frame.maxY
                record.bboxHeight = max(estimatedHeight, actualBottom - record.bboxY)
                try? db.saveFeedback(&record)
                if let idx = feedbacks.firstIndex(where: { $0.id == record.id }) {
                    feedbacks[idx] = record
                }
            }
            coordinator.recalculateFrozenBottom(on: canvasView, feedbacks: feedbacks)
            nextCardY = coordinator.lastRenderedBottom + 24
        } else {
            nextCardY += estimatedHeight + 24
        }

        // 캔버스 확장
        if nextCardY + 200 > canvasView.contentSize.height {
            canvasView.contentSize.height = nextCardY + 200
        }

        // 새 카드가 viewport 안에 들어오도록 자동 스크롤 — 카드 상단이 화면 1/3 지점에 오게
        let visibleHeight = canvasView.bounds.height
        if visibleHeight > 0 {
            let targetOffsetY = max(0, record.positionY - visibleHeight / 3)
            let maxOffsetY = max(0, canvasView.contentSize.height - visibleHeight)
            let clamped = min(targetOffsetY, maxOffsetY)
            canvasView.setContentOffset(CGPoint(x: 0, y: clamped), animated: true)
            appLog("note", "auto scroll", ["targetY": "\(Int(clamped))", "cardY": "\(Int(record.positionY))"])
        }

        appLog("note", "card appended", ["y": "\(record.positionY)", "nextY": "\(nextCardY)", "contentLen": "\(content.count)"])
    }

    private func pinToCanvas(content: String) {
        let jsonContent = "{\"type\":\"feedback\",\"content\":\(String(data: (try? JSONEncoder().encode(content)) ?? Data(), encoding: .utf8) ?? "\"\"")}"
        appendFeedbackCard(content: jsonContent)
    }

    private func refreshUndoState() {
        let um = canvasView.undoManager
        canUndo = um?.canUndo ?? false
        canRedo = um?.canRedo ?? false
    }

    /// 현재 캔버스를 현재 페이지에 저장 — 빈 캔버스도 저장 (이전 필기 유지 방지)
    private func saveDrawing() {
        guard let page = currentNotePage else { return }
        let data = canvasView.drawing.dataRepresentation()
        try? db.savePageDrawing(pageId: page.id, data: data)
        // 메모리 배열도 동기화
        if let idx = notePages.firstIndex(where: { $0.id == page.id }) {
            notePages[idx].drawingData = data
        }
        appLog("note", "saveDrawing", ["pageId": page.id, "strokes": "\(canvasView.drawing.strokes.count)"])
    }

    /// DB에서 특정 페이지의 드로잉을 로드하여 캔버스에 적용
    private func loadDrawingFromDB(pageId: String) {
        if let page = try? db.page(noteId: noteId, pageIndex: currentPageIndex),
           let data = page.drawingData,
           let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
            appLog("note", "loadDrawing", ["pageIndex": "\(currentPageIndex)", "strokes": "\(drawing.strokes.count)"])
        } else {
            canvasView.drawing = PKDrawing()
            appLog("note", "loadDrawing", ["pageIndex": "\(currentPageIndex)", "empty": "true"])
        }
    }

    private func newPage() {
        saveDrawing()

        let newIndex = notePages.count
        guard let page = try? db.createPage(noteId: noteId, pageIndex: newIndex) else { return }
        notePages.append(page)
        currentPageIndex = newIndex
        currentNotePage = page
        try? db.updateCurrentPageIndex(noteId: noteId, index: newIndex)

        canvasView.drawing = PKDrawing()
        feedbacks = []
        nextCardY = 100
        if let delegate = canvasView.delegate as? PencilKitCanvasView.Coordinator {
            delegate.lastRenderedBottom = 0
            delegate.frozenBottom = 0
            delegate.frozenEndIndex = 0
            delegate.previousStrokeCount = 0
        }

        appLog("note", "newPage", ["index": "\(newIndex)"])
    }

    private func goToPage(index: Int) {
        guard index >= 0, index < notePages.count, index != currentPageIndex else { return }

        // 1. 현재 페이지 저장
        saveDrawing()

        // 2. 인덱스 전환
        currentPageIndex = index
        currentNotePage = notePages[index]
        try? db.updateCurrentPageIndex(noteId: noteId, index: index)

        // 3. coordinator 렌더링 높이 리셋
        if let delegate = canvasView.delegate as? PencilKitCanvasView.Coordinator {
            delegate.lastRenderedBottom = 0
            delegate.frozenBottom = 0
            delegate.frozenEndIndex = 0
            delegate.previousStrokeCount = 0
        }

        // 4. DB에서 드로잉 로드 (메모리 배열이 아닌 DB에서 직접)
        loadDrawingFromDB(pageId: notePages[index].id)

        // 5. 피드백 로드
        feedbacks = (try? db.feedbacks(pageId: notePages[index].id)) ?? []
        nextCardY = 100

        appLog("note", "goToPage", ["index": "\(index)", "feedbacks": "\(feedbacks.count)"])
    }

    private func revertFeedback(_ fb: FeedbackRecord) {
        try? db.deleteFeedback(id: fb.id)
        feedbacks.removeAll { $0.id == fb.id }
        if let coordinator = canvasView.delegate as? PencilKitCanvasView.Coordinator {
            coordinator.removeCard(on: canvasView, feedbackId: fb.id)
            coordinator.recalculateFrozenBottom(on: canvasView, feedbacks: feedbacks)
        }
        appLog("note", "feedback reverted", ["id": fb.id])
    }

    private func submitRating(feedback fb: FeedbackRecord, rating: Int, reasonTags: [String], comment: String?) {
        guard let serverId = fb.serverFeedbackId else {
            appLog("rating", "skip: no server id", ["local": fb.id])
            return
        }
        // Optimistic local update + re-render
        if let idx = feedbacks.firstIndex(where: { $0.id == fb.id }) {
            feedbacks[idx].userRating = rating
        }
        try? db.updateFeedbackRating(id: fb.id, rating: rating, syncedAt: nil)
        if let coordinator = canvasView.delegate as? PencilKitCanvasView.Coordinator {
            coordinator.renderAllCards(on: canvasView, feedbacks: feedbacks)
        }

        Task {
            do {
                var body: [String: Any] = ["rating": rating, "reason_tags": reasonTags]
                if let comment { body["comment"] = comment }
                try await APIClient.shared.postJSONNoContent("/feedback/\(serverId)/rate", body: body)
                try? db.updateFeedbackRating(id: fb.id, rating: rating, syncedAt: Date())
                if let idx = feedbacks.firstIndex(where: { $0.id == fb.id }) {
                    feedbacks[idx].userRatingSyncedAt = Date()
                }
                appLog("rating", "synced", ["server": serverId, "rating": "\(rating)", "tags": "\(reasonTags)"])
            } catch {
                appLogError("rating", "sync failed", ["server": serverId, "error": "\(error)"])
            }
        }
    }

    private func showToast(_ message: String) {
        // 2초 이내 같은 메시지 dedupe
        if let last = lastToastMessage,
           last == message,
           let at = lastToastShownAt,
           Date().timeIntervalSince(at) < Self.toastDedupeWindow {
            return
        }
        lastToastMessage = message
        lastToastShownAt = Date()
        withAnimation { toastMessage = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toastMessage == message {
                withAnimation { toastMessage = nil }
            }
        }
    }

    private func requestFeedback() {
        guard !loading else { return }
        loading = true

        let requestId = String(UUID().uuidString.prefix(8))
        appLog("note", "feedback: start", ["requestId": requestId])
        Task { @MainActor in
            do {
                appLog("note", "feedback: task entered", ["requestId": requestId])
                let allStrokes = canvasView.drawing.strokes
                let coordinator = canvasView.delegate as? PencilKitCanvasView.Coordinator
                let frozenEnd = min(coordinator?.frozenEndIndex ?? 0, allStrokes.count)
                appLog("note", "feedback: strokes read", ["requestId": requestId, "count": "\(allStrokes.count)", "frozenEnd": "\(frozenEnd)"])
                let newStrokes = Array(allStrokes.dropFirst(frozenEnd))
                guard !newStrokes.isEmpty else {
                    appLog("note", "feedback: no new strokes", ["total": "\(allStrokes.count)", "frozenEnd": "\(frozenEnd)"])
                    loading = false
                    return
                }

                // 새 스트로크만으로 드로잉 생성하여 캡처
                let newDrawing = PKDrawing(strokes: newStrokes)
                let bounds = newDrawing.bounds
                guard !bounds.isEmpty else {
                    appLog("note", "feedback: empty bounds")
                    loading = false
                    return
                }

                // 캡처 — 항상 흰 배경 + 가시적 잉크
                // Claude API 최대 8000px — 초과 시 리사이즈
                let rawImage = newDrawing.image(from: bounds, scale: 1.0)
                // 최대 2000px로 리사이즈 (API 속도 + 비용 최적화)
                let maxDim: CGFloat = 2000
                let imgSize = rawImage.size
                let ratio = max(imgSize.width, imgSize.height) > maxDim
                    ? maxDim / max(imgSize.width, imgSize.height)
                    : 1.0
                let targetSize = CGSize(width: imgSize.width * ratio, height: imgSize.height * ratio)

                let renderer = UIGraphicsImageRenderer(size: targetSize)
                let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
                let finalImage = renderer.image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: targetSize))
                    if isDarkMode {
                        guard let cgImage = rawImage.cgImage,
                              let ciImage = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: CIImage(cgImage: cgImage)])?.outputImage,
                              let invertedCG = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
                            rawImage.draw(in: CGRect(origin: .zero, size: targetSize))
                            return
                        }
                        UIImage(cgImage: invertedCG).draw(in: CGRect(origin: .zero, size: targetSize))
                    } else {
                        rawImage.draw(in: CGRect(origin: .zero, size: targetSize))
                    }
                }
                guard let pngData = finalImage.jpegData(compressionQuality: 0.8) else {
                    appLog("note", "feedback: pngData nil")
                    loading = false
                    return
                }

                appLog("note", "feedback: capture", [
                    "requestId": "\(requestId)",
                    "newStrokes": "\(newStrokes.count)",
                    "bounds": "\(bounds)",
                    "pngBytes": "\(pngData.count)",
                    "imageSize": "\(finalImage.size)",
                ])

                var fields: [String: String] = [
                    "note_id": noteId,
                    "language": note?.language ?? "en",
                    "response_language": Config.responseLanguage,
                    "request_id": "\(requestId)",
                ]
                if let textbookId = note?.textbookId {
                    fields["textbook_id"] = textbookId
                    fields["current_page"] = "\(currentPage)"
                }

                // Build previous context
                if let lastFeedback = feedbacks.last,
                   let data = lastFeedback.content.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(AIResponse.self, from: data) {
                    let ctx = "Previous feedback:\n\(parsed.displayText)"
                    fields["previous_context"] = String(ctx.prefix(1500))
                }

                let response: AIResponse = try await APIClient.shared.postMultipart(
                    "/feedback",
                    fields: fields,
                    fileField: "image",
                    fileData: pngData,
                    fileName: "canvas.jpg",
                    mimeType: "image/jpeg"
                )

                let jsonData = try JSONEncoder().encode(response)
                let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
                let strokeEnd = canvasView.drawing.strokes.count
                appendFeedbackCard(content: jsonStr, strokeRangeStart: frozenEnd, strokeRangeEnd: strokeEnd, serverFeedbackId: response.feedbackId)

                appLog("note", "feedback received", ["requestId": "\(requestId)", "content": String((response.content ?? response.displayText).prefix(80)), "range": "\(frozenEnd)..\(strokeEnd)"])
            } catch {
                appLogError("note", "feedback failed", ["requestId": "\(requestId)", "error": "\(error)"])
            }
            loading = false
        }
    }
}

// MARK: - PencilKit UIViewRepresentable

struct PencilKitCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var onDrawingChanged: () -> Void
    var onStrokeChanged: (() -> Void)? = nil
    var initialDrawingData: Data?
    var feedbacks: [FeedbackRecord]
    var onFeedbackTapped: ((FeedbackRecord) -> Void)?
    var onFeedbackRevert: ((FeedbackRecord) -> Void)?
    var onStrokeRejected: (() -> Void)?
    var onFeedbackRate: ((FeedbackRecord, Int) -> Void)?
    var onFeedbackRateDetail: ((FeedbackRecord) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> PKCanvasView {
        let isDark = colorScheme == .dark
        #if targetEnvironment(simulator)
        canvasView.drawingPolicy = .anyInput
        #else
        canvasView.drawingPolicy = .pencilOnly
        #endif
        canvasView.backgroundColor = isDark ? .black : .white
        canvasView.isScrollEnabled = true
        canvasView.alwaysBounceVertical = false
        canvasView.bounces = true
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.isOpaque = true
        canvasView.tool = PKInkingTool(.pen, color: isDark ? .white : .black, width: 3)
        canvasView.delegate = context.coordinator

        // Load saved drawing — only if canvas is empty (avoid overwriting on rotation)
        if canvasView.drawing.strokes.isEmpty,
           let data = initialDrawingData,
           let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
        }

        appLog("canvas", "makeUIView", [
            "bounds": "\(canvasView.bounds)",
            "drawingPolicy": "\(canvasView.drawingPolicy.rawValue)",
            "hasDrawing": "\(initialDrawingData != nil)",
        ])

        // Tool picker setup after view is in window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let toolPicker = PKToolPicker()
            toolPicker.setVisible(true, forFirstResponder: canvasView)
            toolPicker.addObserver(canvasView)
            context.coordinator.toolPicker = toolPicker
            let became = canvasView.becomeFirstResponder()
            appLog("canvas", "toolPicker setup", [
                "becameFirstResponder": "\(became)",
                "window": "\(canvasView.window != nil)",
                "bounds": "\(canvasView.bounds)",
                "contentSize": "\(canvasView.contentSize)",
                "isUserInteractionEnabled": "\(canvasView.isUserInteractionEnabled)",
            ])
        }

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Dark mode: update canvas background + default pen color
        let isDark = colorScheme == .dark
        uiView.backgroundColor = isDark ? .black : .white
        context.coordinator.isDarkMode = isDark
        context.coordinator.onFeedbackTapped = onFeedbackTapped
        context.coordinator.onFeedbackRevert = onFeedbackRevert
        context.coordinator.onStrokeRejected = onStrokeRejected
        // Only update tool color if user hasn't picked a custom color via tool picker
        if let inkTool = uiView.tool as? PKInkingTool,
           inkTool.color == .black || inkTool.color == .white {
            uiView.tool = PKInkingTool(inkTool.inkType, color: isDark ? .white : .black, width: inkTool.width)
        }

        if uiView.bounds.width > 0 && uiView.contentSize.width == 0 {
            uiView.contentSize = CGSize(
                width: uiView.bounds.width,
                height: max(uiView.bounds.height * 5, uiView.contentSize.height)
            )
        }
        if uiView.bounds.height > 0 && uiView.contentSize.height <= uiView.bounds.height {
            uiView.contentSize = CGSize(
                width: uiView.bounds.width,
                height: uiView.bounds.height * 5
            )
        }

        // Render feedback cards — coordinator에 위임
        let existingCards = uiView.subviews.filter { $0.tag == 9999 }.count
        appLog("canvas", "updateUIView", ["feedbacks": "\(feedbacks.count)", "existingCards": "\(existingCards)", "bounds": "\(uiView.bounds)"])
        context.coordinator.renderAllCards(on: uiView, feedbacks: feedbacks)
        context.coordinator.updateFrozenOverlay(on: uiView)
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(onDrawingChanged: onDrawingChanged)
        c.onStrokeChanged = onStrokeChanged
        c.onFeedbackTapped = onFeedbackTapped
        c.onFeedbackRevert = onFeedbackRevert
        c.onStrokeRejected = onStrokeRejected
        c.onFeedbackRate = onFeedbackRate
        c.onFeedbackRateDetail = onFeedbackRateDetail
        return c
    }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        let onDrawingChanged: () -> Void
        var onStrokeChanged: (() -> Void)?
        var onFeedbackTapped: ((FeedbackRecord) -> Void)?
        var onFeedbackRevert: ((FeedbackRecord) -> Void)?
        var onStrokeRejected: (() -> Void)?
        var onFeedbackRate: ((FeedbackRecord, Int) -> Void)?
        var onFeedbackRateDetail: ((FeedbackRecord) -> Void)?
        var toolPicker: PKToolPicker?
        var toolPickerVisible: Bool = true
        var lastRenderedBottom: CGFloat = 0
        var lastKnownWidth: CGFloat = 0
        var frozenBottom: CGFloat = 0
        var frozenEndIndex: Int = 0
        var previousStrokeCount: Int = 0
        var isDarkMode: Bool = false
        private var saveTimer: Timer?
        private var nextPositionIndicator: UIView?

        init(onDrawingChanged: @escaping () -> Void) {
            self.onDrawingChanged = onDrawingChanged
        }

        @objc func feedbackCardTapped(_ gesture: FeedbackTapGesture) {
            if let fb = gesture.feedbackRecord {
                onFeedbackTapped?(fb)
            }
        }

        @objc func feedbackRevertTapped(_ gesture: FeedbackTapGesture) {
            if let fb = gesture.feedbackRecord {
                onFeedbackRevert?(fb)
            }
        }

        @objc func feedbackThumbUpTapped(_ gesture: FeedbackTapGesture) {
            if let fb = gesture.feedbackRecord { onFeedbackRate?(fb, 1) }
        }

        @objc func feedbackThumbDownTapped(_ gesture: FeedbackTapGesture) {
            if let fb = gesture.feedbackRecord { onFeedbackRate?(fb, -1) }
        }

        @objc func feedbackRateDetailTapped(_ gesture: FeedbackTapGesture) {
            if let fb = gesture.feedbackRecord { onFeedbackRateDetail?(fb) }
        }

        // MARK: - Frozen state

        func recalculateFrozenBottom(on canvasView: PKCanvasView, feedbacks: [FeedbackRecord]) {
            frozenBottom = feedbacks.map { CGFloat($0.bboxY + $0.bboxHeight) }.max() ?? 0
            frozenEndIndex = feedbacks.map { $0.strokeRangeEnd }.max() ?? 0
            previousStrokeCount = canvasView.drawing.strokes.count
            updateFrozenOverlay(on: canvasView)
            appLog("canvas", "frozen recalc", [
                "bottom": "\(Int(frozenBottom))",
                "endIndex": "\(frozenEndIndex)",
                "strokes": "\(previousStrokeCount)",
            ])
        }

        func removeCard(on canvasView: PKCanvasView, feedbackId: String) {
            canvasView.subviews
                .filter { $0.tag == 9999 && $0.accessibilityIdentifier == feedbackId }
                .forEach { $0.removeFromSuperview() }
            // lastRenderedBottom 재계산 (남은 카드 기준)
            let remaining = canvasView.subviews.filter { $0.tag == 9999 }
            lastRenderedBottom = remaining.map { $0.frame.maxY }.max() ?? 0
        }

        func updateFrozenOverlay(on canvasView: PKCanvasView) {
            if canvasView.bounds.width > 0 {
                lastKnownWidth = canvasView.bounds.width
            }
            let width = max(lastKnownWidth, canvasView.contentSize.width)
            guard width > 0 else { return }

            // 중복 제거
            let existing = canvasView.subviews.filter { $0.tag == 9997 }
            if existing.count > 1 {
                existing.dropFirst().forEach { $0.removeFromSuperview() }
            }
            let overlay: UIView
            if let v = existing.first {
                overlay = v
            } else {
                overlay = UIView()
                overlay.tag = 9997
                overlay.isUserInteractionEnabled = false
                canvasView.addSubview(overlay)
                canvasView.sendSubviewToBack(overlay)
            }
            let alpha: CGFloat = isDarkMode ? 0.10 : 0.07
            overlay.backgroundColor = UIColor.systemGray.withAlphaComponent(alpha)
            overlay.frame = CGRect(x: 0, y: 0, width: width, height: max(0, frozenBottom))
            overlay.isHidden = frozenBottom <= 0
        }

        // MARK: - Card Rendering

        /// 전체 카드를 다시 렌더링 (페이지 로드, 다크모드 전환 시)
        func renderAllCards(on canvasView: PKCanvasView, feedbacks: [FeedbackRecord]) {
            canvasView.subviews.filter { $0.tag == 9999 }.forEach { $0.removeFromSuperview() }
            lastRenderedBottom = 0
            for (i, fb) in feedbacks.enumerated() {
                renderCard(on: canvasView, feedback: fb, isLast: i == feedbacks.count - 1)
            }
            updateNextPositionIndicator(on: canvasView)
            recalculateFrozenBottom(on: canvasView, feedbacks: feedbacks)
        }

        /// 단일 카드를 캔버스에 추가 (피드백 수신 시 직접 호출)
        func renderCard(on canvasView: PKCanvasView, feedback fb: FeedbackRecord, isLast: Bool = true) {
            // bounds.width가 유효하면 저장, 0이면 마지막으로 알려진 값 사용
            if canvasView.bounds.width > 0 {
                lastKnownWidth = canvasView.bounds.width
            }
            let effectiveWidth = lastKnownWidth > 0 ? lastKnownWidth : 800
            let cardWidth = effectiveWidth - 32
            let parsed = try? JSONDecoder().decode(AIResponse.self, from: fb.content.data(using: .utf8) ?? Data())

            let card = UIView()
            card.tag = 9999
            card.accessibilityIdentifier = fb.id
            card.backgroundColor = UIColor.systemBackground
            card.layer.cornerRadius = 12
            card.layer.shadowColor = UIColor.black.cgColor
            card.layer.shadowOpacity = 0.1
            card.layer.shadowRadius = 4
            card.layer.shadowOffset = CGSize(width: 0, height: 2)
            card.isUserInteractionEnabled = true

            let label = UITextView()
            label.isEditable = false
            label.isScrollEnabled = false
            label.backgroundColor = .clear
            label.textContainerInset = .zero
            label.textContainer.lineFragmentPadding = 0

            let rawText = parsed?.displayText ?? fb.content
            if let attrStr = try? NSAttributedString(
                markdown: rawText,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                let mutable = NSMutableAttributedString(attributedString: attrStr)
                mutable.addAttributes([
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.label,
                ], range: NSRange(location: 0, length: mutable.length))
                label.attributedText = mutable
            } else {
                label.text = rawText
                label.font = .systemFont(ofSize: 14)
                label.textColor = .label
            }

            let buttonBar = UIStackView()
            buttonBar.axis = .horizontal
            buttonBar.spacing = 12
            buttonBar.alignment = .center

            let chatBtn = UIButton(type: .system)
            chatBtn.setImage(UIImage(systemName: "bubble.left.fill"), for: .normal)
            chatBtn.setTitle(" 대화", for: .normal)
            chatBtn.titleLabel?.font = .systemFont(ofSize: 12)
            chatBtn.tintColor = .secondaryLabel
            let chatGesture = FeedbackTapGesture(target: self, action: #selector(feedbackCardTapped(_:)))
            chatGesture.feedbackRecord = fb
            chatBtn.addGestureRecognizer(chatGesture)

            buttonBar.addArrangedSubview(chatBtn)

            // Rating buttons — only show once server feedback id is known
            if fb.serverFeedbackId != nil {
                let upBtn = UIButton(type: .system)
                let upName = fb.userRating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup"
                upBtn.setImage(UIImage(systemName: upName), for: .normal)
                upBtn.tintColor = fb.userRating == 1 ? UIColor.systemGreen : UIColor.secondaryLabel
                let upGesture = FeedbackTapGesture(target: self, action: #selector(feedbackThumbUpTapped(_:)))
                upGesture.feedbackRecord = fb
                upBtn.addGestureRecognizer(upGesture)
                buttonBar.addArrangedSubview(upBtn)

                let downBtn = UIButton(type: .system)
                let downName = fb.userRating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown"
                downBtn.setImage(UIImage(systemName: downName), for: .normal)
                downBtn.tintColor = fb.userRating == -1 ? UIColor.systemRed : UIColor.secondaryLabel
                let downGesture = FeedbackTapGesture(target: self, action: #selector(feedbackThumbDownTapped(_:)))
                downGesture.feedbackRecord = fb
                downBtn.addGestureRecognizer(downGesture)
                buttonBar.addArrangedSubview(downBtn)

                let detailBtn = UIButton(type: .system)
                detailBtn.setTitle("자세히", for: .normal)
                detailBtn.titleLabel?.font = .systemFont(ofSize: 12)
                detailBtn.tintColor = .secondaryLabel
                let detailGesture = FeedbackTapGesture(target: self, action: #selector(feedbackRateDetailTapped(_:)))
                detailGesture.feedbackRecord = fb
                detailBtn.addGestureRecognizer(detailGesture)
                buttonBar.addArrangedSubview(detailBtn)
            }

            buttonBar.addArrangedSubview(UIView())

            if isLast {
                let revertBtn = UIButton(type: .system)
                revertBtn.tag = 8888
                revertBtn.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
                revertBtn.setTitle(" 되돌리기", for: .normal)
                revertBtn.titleLabel?.font = .systemFont(ofSize: 12)
                revertBtn.tintColor = UIColor.systemRed.withAlphaComponent(0.7)
                let revertGesture = FeedbackTapGesture(target: self, action: #selector(feedbackRevertTapped(_:)))
                revertGesture.feedbackRecord = fb
                revertBtn.addGestureRecognizer(revertGesture)
                buttonBar.addArrangedSubview(revertBtn)
            }

            card.addSubview(label)
            card.addSubview(buttonBar)
            label.translatesAutoresizingMaskIntoConstraints = false
            buttonBar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                buttonBar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
                buttonBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                buttonBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                buttonBar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
                buttonBar.heightAnchor.constraint(equalToConstant: 28),
            ])

            let labelSize = label.sizeThatFits(CGSize(width: cardWidth - 24, height: .greatestFiniteMagnitude))
            let cardHeight = labelSize.height + 48

            card.frame = CGRect(x: 16, y: fb.positionY, width: cardWidth, height: cardHeight)
            canvasView.addSubview(card)

            let cardBottom = fb.positionY + cardHeight
            if cardBottom + 200 > canvasView.contentSize.height {
                canvasView.contentSize.height = cardBottom + 200
            }
            lastRenderedBottom = max(lastRenderedBottom, cardBottom)
            updateNextPositionIndicator(on: canvasView)
        }

        /// 다음 피드백 카드가 들어갈 위치를 dashed line + 라벨로 표시 — 스트로크/카드 변동 시마다 갱신
        func updateNextPositionIndicator(on canvasView: PKCanvasView) {
            if canvasView.bounds.width > 0 {
                lastKnownWidth = canvasView.bounds.width
            }
            let width = lastKnownWidth
            guard width > 0 else {
                appLog("indicator", "skip: width=0", ["bounds": "\(canvasView.bounds)"])
                return
            }

            let y = calculateNextCardY(on: canvasView, currentNextCardY: 100)
            let strokeMaxY = canvasView.drawing.strokes.isEmpty
                ? CGFloat(0)
                : canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }

            // canvasView에서 직접 indicator 조회 — Coordinator 재생성 시에도 안전
            // 중복(stale)이 있으면 첫 번째만 남기고 모두 제거
            let allIndicators = canvasView.subviews.filter { $0.tag == 9998 }
            if allIndicators.count > 1 {
                allIndicators.dropFirst().forEach { $0.removeFromSuperview() }
                appLog("indicator", "stale removed", ["count": "\(allIndicators.count - 1)"])
            }
            let existingInCanvas = allIndicators.first

            let indicator: UIView
            let isNew: Bool
            if let existing = existingInCanvas {
                indicator = existing
                nextPositionIndicator = existing
                isNew = false
            } else {
                indicator = UIView()
                indicator.tag = 9998
                indicator.isUserInteractionEnabled = false
                indicator.backgroundColor = .clear

                let line = CAShapeLayer()
                line.name = "dashed-line"
                line.strokeColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
                line.fillColor = nil
                line.lineWidth = 1.5
                line.lineDashPattern = [6, 4]
                indicator.layer.addSublayer(line)

                let label = UILabel()
                label.tag = 1
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .white
                label.text = "  ↓ 다음 피드백 위치  "
                label.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
                label.layer.cornerRadius = 6
                label.layer.masksToBounds = true
                label.textAlignment = .center
                indicator.addSubview(label)

                canvasView.addSubview(indicator)
                nextPositionIndicator = indicator
                isNew = true
            }

            let lineInset: CGFloat = 16
            indicator.frame = CGRect(x: 0, y: y - 10, width: width, height: 24)

            if let line = indicator.layer.sublayers?.first(where: { $0.name == "dashed-line" }) as? CAShapeLayer {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: lineInset, y: 6))
                path.addLine(to: CGPoint(x: width - lineInset, y: 6))
                line.path = path.cgPath
            }
            if let label = indicator.subviews.first(where: { $0.tag == 1 }) as? UILabel {
                let fit = label.sizeThatFits(CGSize(width: width, height: 24))
                label.frame = CGRect(x: lineInset, y: 0, width: fit.width, height: 18)
            }

            canvasView.bringSubviewToFront(indicator)

            appLog("indicator", isNew ? "created" : "updated", [
                "y": "\(Int(y))",
                "strokeMaxY": "\(Int(strokeMaxY))",
                "lastCardBottom": "\(Int(lastRenderedBottom))",
                "width": "\(Int(width))",
                "strokes": "\(canvasView.drawing.strokes.count)",
            ])
        }

        /// 다음 카드가 배치될 Y 좌표 계산 — 스트로크 maxY와 마지막 카드 하단 중 큰 값 + 여백
        func calculateNextCardY(on canvasView: PKCanvasView, currentNextCardY: CGFloat) -> CGFloat {
            // 1. 마지막 렌더된 카드 하단
            var y = currentNextCardY
            if lastRenderedBottom + 24 > y {
                y = lastRenderedBottom + 24
            }

            // 2. 스트로크 maxY — 항상 체크 (카드가 필기를 덮지 않도록)
            let drawingBottom = canvasView.drawing.strokes.isEmpty
                ? CGFloat(100)
                : canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }
            if drawingBottom + 24 > y {
                y = drawingBottom + 24
            }

            return y
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Prevent upward expansion — clamp contentOffset to >= 0
            if canvasView.contentOffset.y < 0 {
                canvasView.contentOffset.y = 0
            }

            // Frozen 영역 입력 차단 — 새로 추가된 stroke만 검사
            let strokes = canvasView.drawing.strokes
            if frozenBottom > 0, strokes.count > previousStrokeCount {
                let diff = strokes.count - previousStrokeCount
                let added = Array(strokes.suffix(diff))
                let invalidIdx = added.enumerated().compactMap { (i, s) -> Int? in
                    s.renderBounds.minY < frozenBottom ? (previousStrokeCount + i) : nil
                }
                if !invalidIdx.isEmpty {
                    let invalidSet = Set(invalidIdx)
                    let kept = strokes.enumerated().filter { !invalidSet.contains($0.offset) }.map { $0.element }
                    canvasView.drawing = PKDrawing(strokes: kept)
                    appLog("canvas", "stroke rejected", ["count": "\(invalidIdx.count)", "frozenBottom": "\(Int(frozenBottom))"])
                    onStrokeRejected?()
                }
            }
            previousStrokeCount = canvasView.drawing.strokes.count

            // Auto-expand content size (downward only)
            let drawingBottom = canvasView.drawing.strokes.isEmpty
                ? canvasView.bounds.height
                : canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }
            let requiredHeight = drawingBottom + canvasView.bounds.height * 2
            if requiredHeight > canvasView.contentSize.height {
                canvasView.contentSize.height = requiredHeight
            }

            updateNextPositionIndicator(on: canvasView)

            onStrokeChanged?()

            saveTimer?.invalidate()
            saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.onDrawingChanged()
            }
        }
    }
}

// MARK: - Markdown Feedback Card (SwiftUI, hosted in UIKit)

struct MarkdownFeedbackCard: View {
    let content: String
    let width: CGFloat

    var body: some View {
        Markdown(content)
            .markdownTextStyle {
                FontSize(14)
            }
            .padding(14)
            .frame(width: width, alignment: .leading)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}
