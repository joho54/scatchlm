import SwiftUI
import PencilKit
import PDFKit
import UniformTypeIdentifiers

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
    @State private var showPaywall = false
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
    // PDF/캔버스 분할 비율 (PDF 쪽 비율). 드래그 가능한 divider로 조정. 세션 휘발(영속 안 함).
    @State private var pdfFraction: CGFloat = 0.4
    // 드래그 시작 시점의 비율 앵커 — translation은 누적값이라 시작값 기준으로 계산.
    @State private var dragStartFraction: CGFloat?

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
                    // 캔버스 폭/높이를 body에서 명시적으로 계산해 .frame으로 강제한다.
                    // (inner GeometryReader는 panelGeo는 갱신하지만 host(UIScrollView) 프레임 리사이즈를
                    //  divider 드래그 때 전파하지 못해, host가 회전 시점 폭에 고정되는 버그가 있었음.)
                    if isLandscape && pdfOpen {
                        let pdfW = geo.size.width * clampedLandscapeFraction(geo.size.width)
                        let canvasW = max(0, geo.size.width - pdfW - Self.dividerThickness)
                        HStack(spacing: 0) {
                            pdfPanel(note: note)
                                .frame(width: pdfW)
                            dividerHandle(isVertical: true, total: geo.size.width)
                            canvasPanel(note: note, panelWidth: canvasW)
                                .frame(width: canvasW)
                        }
                    } else if pdfOpen {
                        VStack(spacing: 0) {
                            pdfPanel(note: note)
                                .frame(height: geo.size.height * clampedPortraitFraction)
                            dividerHandle(isVertical: false, total: geo.size.height)
                            canvasPanel(note: note, panelWidth: geo.size.width)
                        }
                    } else {
                        canvasPanel(note: note, panelWidth: geo.size.width)
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
                                Text("필기 분석 중…")
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
            .onChange(of: geo.size) { _, s in
                // [diag] 회전/리사이즈 관측 — geo 기준 방향 vs isLandscape(UIScreen 기준) 불일치 추적
                appLog("layoutdiag", "geo changed", [
                    "w": "\(Int(s.width))", "h": "\(Int(s.height))",
                    "geoLandscape": "\(s.width > s.height)",
                    "propLandscape": "\(isLandscape)",
                    "pdfOpen": "\(pdfOpen)",
                    "pdfFraction": String(format: "%.2f", pdfFraction),
                ])
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: .bottom)
        .sheet(isPresented: $showPaywall) {
            PaywallView(reason: String(localized: "오늘 무료 사용량을 모두 사용했어요. Pro로 업그레이드하면 더 많은 피드백을 받을 수 있어요."))
        }
        .sheet(item: $chatFeedback) { fb in
            FeedbackChatSheet(feedback: fb, textbookId: note?.textbookId, currentPage: currentPage, noteId: noteId, subject: note?.language, onPin: { content, responseId in
                pinToCanvas(content: content, serverFeedbackId: responseId)
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

    // MARK: - Split Divider (PDF/캔버스 분할 리사이즈)

    /// 세로 모드 PDF 비율 clamp. 캔버스는 아래로 무한 확장형이라 높이 변경은 폭 좌표계와 무관 → 단순 [0.2,0.7].
    private var clampedPortraitFraction: CGFloat {
        min(max(pdfFraction, 0.2), 0.7)
    }

    /// 가로 모드 PDF 비율 clamp. 네이티브 줌이 좁은 캔버스 폭을 흡수하므로 더 이상 논리폭 상한이
    /// 필요 없다 — 단순 [0.2,0.7]. (캔버스가 논리폭보다 좁아지면 host가 zoom-to-fit으로 페이지 전체를 축소.)
    private func clampedLandscapeFraction(_ totalWidth: CGFloat) -> CGFloat {
        clampLandscape(pdfFraction, totalWidth)
    }

    /// 드래그 가능한 분할 핸들. isVertical=true → 가로 모드(폭 조정), false → 세로 모드(높이 조정).
    @ViewBuilder
    private func dividerHandle(isVertical: Bool, total: CGFloat) -> some View {
        let thickness: CGFloat = 16
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: isVertical ? 4 : 44, height: isVertical ? 44 : 4)
        }
        .frame(width: isVertical ? thickness : nil, height: isVertical ? nil : thickness)
        .frame(maxWidth: isVertical ? nil : .infinity, maxHeight: isVertical ? .infinity : nil)
        .contentShape(Rectangle())
        .background(Color(uiColor: .systemBackground).opacity(0.001))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard total > 0 else { return }
                    let start = dragStartFraction ?? pdfFraction
                    if dragStartFraction == nil {
                        dragStartFraction = start
                        // [diag] 드래그 시작 — 회전 후 핸들이 제스처를 받는지/축(isVertical)이 맞는지 확인
                        appLog("dividerdiag", "drag begin", ["isVertical": "\(isVertical)", "total": "\(Int(total))", "startFraction": String(format: "%.2f", start)])
                    }
                    let delta = (isVertical ? value.translation.width : value.translation.height) / total
                    let raw = start + delta
                    pdfFraction = isVertical ? clampLandscape(raw, total) : min(max(raw, 0.2), 0.7)
                }
                .onEnded { _ in
                    appLog("dividerdiag", "drag end", ["isVertical": "\(isVertical)", "fraction": String(format: "%.2f", pdfFraction)])
                    dragStartFraction = nil
                }
        )
    }

    /// 가로 모드 비율 clamp — 네이티브 줌 도입으로 상한 단순화 [0.2,0.7]. (totalWidth는 시그니처 호환용)
    private func clampLandscape(_ fraction: CGFloat, _ totalWidth: CGFloat) -> CGFloat {
        min(max(fraction, 0.2), 0.7)
    }

    // MARK: - Canvas Panel

    /// 분할 divider 두께(가로=폭, 세로=높이). dividerHandle의 thickness와 일치해야 폭 계산이 맞음.
    private static let dividerThickness: CGFloat = 16

    /// panelWidth는 호출부(body)에서 계산해 명시적으로 전달 — host(UIScrollView)가 이 폭을 갖도록
    /// 호출부에서 .frame(width:)로 강제한다(가로 분할). 세로/PDF닫힘은 전체 폭이라 .frame 불필요.
    @ViewBuilder
    private func canvasPanel(note: Note, panelWidth: CGFloat) -> some View {
        ZStack {
            // 레터박스 여백 — 논리폭보다 넓은 가용 공간에서 종이 양옆 회색 배경.
            // 네이티브 줌 구조에선 host(UIScrollView)가 패널 폭을 가득 채우고 contentInset으로
            // 종이를 가운데 정렬하므로, 이 Color는 host 바깥(투명)으로 비치는 레터박스 배경이다.
            Color(uiColor: .systemGray5)
            canvasContent(note: note, panelWidth: panelWidth)
        }
        .overlay(alignment: .topLeading) { canvasTopControls() }
    }

    @ViewBuilder
    private func canvasContent(note: Note, panelWidth: CGFloat) -> some View {
        PencilKitCanvasView(
            canvasView: $canvasView,
            panelWidth: panelWidth,
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
                showToast(String(localized: "이 영역은 피드백이 완료됐습니다. 되돌리려면 카드의 ↩︎를 누르세요"))
            },
            onFeedbackRate: { fb, rating in
                submitRating(feedback: fb, rating: rating, reasonTags: [], comment: nil)
            },
            onFeedbackRateDetail: { fb in
                ratingSheetFeedback = fb
            }
        )
    }

    @ViewBuilder
    private func canvasTopControls() -> some View {
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
                onPin: { content, responseId in
                    pinToCanvas(content: content, serverFeedbackId: responseId)
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

    /// 카드·오버레이·indicator가 사는 컨테이너. 네이티브 줌 구조에서는 contentView(줌 대상)이며,
    /// coordinator가 아직 연결 전이면 canvasView로 폴백.
    private func cardContainer() -> UIView {
        (canvasView.delegate as? PencilKitCanvasView.Coordinator)?.contentView ?? canvasView
    }

    /// 피드백/스크랩 카드를 캔버스에 추가하는 공통 함수
    private func appendFeedbackCard(content: String, estimatedHeight: CGFloat = 400, strokeRangeStart: Int? = nil, strokeRangeEnd: Int? = nil, serverFeedbackId: String? = nil) {
        // 카드는 가이드라인(SSOT)이 가리키는 위치에 정확히 배치한다.
        // 먼저 인디케이터를 현재 스트로크/카드 기준으로 갱신해 nextCardLineY를 최신화한 뒤 그 값을 읽는다.
        let coordinator = canvasView.delegate as? PencilKitCanvasView.Coordinator
        if let coordinator {
            coordinator.updateNextPositionIndicator(on: canvasView)
            nextCardY = coordinator.nextCardLineY
        }

        let width = Config.logicalCanvasWidth - 32
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
        do {
            try db.saveFeedback(&record)
        } catch {
            // 저장 실패 시 메모리 배열에 추가하지 않음(롤백) + 사용자 알림 (L7/O11)
            appLogError("note", "saveFeedback failed", ["error": "\(error)"])
            showToast(String(localized: "피드백을 저장하지 못했어요."))
            return
        }
        feedbacks.append(record)

        // UIKit 직접 렌더 — SwiftUI updateUIView에 의존하지 않음
        if let coordinator {
            // 이전 "마지막" 카드의 되돌리기 버튼 제거 — revert는 가장 마지막 피드백에서만 허용
            for card in cardContainer().subviews where card.tag == 9999 {
                func stripRevert(_ v: UIView) {
                    for sub in v.subviews {
                        if sub.tag == 8888 { sub.removeFromSuperview() } else { stripRevert(sub) }
                    }
                }
                stripRevert(card)
            }
            coordinator.renderCard(on: canvasView, feedback: record, isLast: true)
            // 실제 렌더 후 bbox 높이 동기화 → frozenBottom 재계산
            if let card = cardContainer().subviews.first(where: { $0.tag == 9999 && $0.accessibilityIdentifier == record.id }) {
                let actualBottom = card.frame.maxY
                record.bboxHeight = max(estimatedHeight, actualBottom - record.bboxY)
                // 높이 동기화 업데이트 — 실패해도 카드는 이미 저장됨, 로깅만.
                do {
                    try db.saveFeedback(&record)
                    if let idx = feedbacks.firstIndex(where: { $0.id == record.id }) {
                        feedbacks[idx] = record
                    }
                } catch {
                    appLogError("note", "saveFeedback (bbox sync) failed", ["error": "\(error)"])
                }
            }
            coordinator.recalculateFrozenBottom(on: canvasView, feedbacks: feedbacks)
            nextCardY = coordinator.lastRenderedBottom + 24

            // 콘텐츠 높이 확장 + 새 카드가 viewport 안에 들어오도록 자동 스크롤(줌 배율 반영)
            coordinator.ensureContentHeight(nextCardY + 200)
            coordinator.scrollCardIntoView(positionY: record.positionY)
        } else {
            nextCardY += estimatedHeight + 24
        }

        appLog("note", "card appended", ["y": "\(record.positionY)", "nextY": "\(nextCardY)", "contentLen": "\(content.count)"])
    }

    private func pinToCanvas(content: String, serverFeedbackId: String? = nil) {
        let jsonContent = "{\"type\":\"feedback\",\"content\":\(String(data: (try? JSONEncoder().encode(content)) ?? Data(), encoding: .utf8) ?? "\"\"")}"
        appendFeedbackCard(content: jsonContent, serverFeedbackId: serverFeedbackId)
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
        do {
            try db.savePageDrawing(pageId: page.id, data: data)
        } catch {
            // 필기 저장 실패 — 사용자에게 알려 손실 인지 (L7/O11)
            appLogError("note", "savePageDrawing failed", ["pageId": page.id, "error": "\(error)"])
            showToast(String(localized: "필기를 저장하지 못했어요. 네트워크/저장 공간을 확인해 주세요."))
            return
        }
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
        // 새 캔버스는 기본 사이즈 + 최상단에서 시작 (이전 페이지의 확장/스크롤 상태 전이 방지)
        resetCanvasToTop()

        // 진단: 새 페이지 진입 시점에 남아 있는 피드백 카드(tag 9999) 수.
        // feedbacks=[] 이후 updateUIView→renderAllCards([])가 안 돌면 0이 안 됨 → "카드 따라옴" 버그.
        let lingeringCards = cardContainer().subviews.filter { $0.tag == 9999 }.count
        appLog("note", "newPage", ["index": "\(newIndex)", "lingeringCards": "\(lingeringCards)"])
    }

    /// 캔버스를 기본 높이로 축소하고 스크롤을 최상단으로 되돌린다.
    /// 네이티브 줌 구조에선 host/contentView 기준으로 리셋 — coordinator에 위임.
    private func resetCanvasToTop() {
        (canvasView.delegate as? PencilKitCanvasView.Coordinator)?.resetToTop()
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

        // 페이지 전환 시에도 최상단·기본 사이즈에서 시작 (이전 페이지 상태 전이 방지)
        resetCanvasToTop()

        let lingeringCards = cardContainer().subviews.filter { $0.tag == 9999 }.count
        appLog("note", "goToPage", ["index": "\(index)", "feedbacks": "\(feedbacks.count)", "lingeringCards": "\(lingeringCards)"])
    }

    private func revertFeedback(_ fb: FeedbackRecord) {
        do {
            try db.deleteFeedback(id: fb.id)
        } catch {
            appLogError("note", "deleteFeedback failed", ["id": fb.id, "error": "\(error)"])
            showToast(String(localized: "피드백을 삭제하지 못했어요."))
            return
        }
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
                // quota 429: 구독 활성 시에만 Paywall 노출(v1 무료라 비활성), 아니면 친화 토스트.
                if Config.subscriptionEnabled, case APIError.quotaExceeded = error, !StoreKitService.shared.isPro {
                    showPaywall = true
                } else {
                    showToast(feedbackErrorMessage(error))
                }
            }
            loading = false
        }
    }

    /// API 에러를 사용자 친화 토스트 문구로 변환 (L8/F-4).
    private func feedbackErrorMessage(_ error: Error) -> String {
        if case APIError.quotaExceeded = error {
            return String(localized: "오늘 사용량을 모두 사용했어요. 내일 다시 시도해 주세요.")
        }
        return (error as? LocalizedError)?.errorDescription ?? String(localized: "피드백을 받지 못했어요. 잠시 후 다시 시도해 주세요.")
    }
}

// MARK: - Host scroll view (native zoom)

/// 줌/팬/세로스크롤 주체. SwiftUI가 frame을 잡아 레이아웃할 때마다 zoom-to-fit·중앙정렬을
/// 재계산해야 하므로(updateUIView가 레이아웃 전에 올 수 있음) layoutSubviews에서 콜백한다.
final class HostScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - PencilKit UIViewRepresentable

struct PencilKitCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    /// 캔버스 패널의 가용 폭(SwiftUI 레이아웃에서 결정). host가 이 폭을 채우고 zoom-to-fit을 계산한다.
    var panelWidth: CGFloat
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

    /// 루트는 host(UIScrollView). 그 안에 contentView(줌 대상, 논리폭) > PKCanvasView(그리기 전용) 중첩.
    /// PencilKit은 스크롤 주체에서 강등되어(`isScrollEnabled=false`) 그리기만 담당하고,
    /// 줌/팬/세로스크롤은 host가 네이티브로 처리한다(GoodNotes식 오버레이 구조).
    func makeUIView(context: Context) -> UIScrollView {
        let coordinator = context.coordinator
        let isDark = colorScheme == .dark
        let logical = Config.logicalCanvasWidth

        // Host scroll view — 줌/팬/세로스크롤 주체
        let host = HostScrollView()
        host.onLayout = { [weak coordinator] in coordinator?.hostDidLayout() }
        host.delegate = coordinator
        host.backgroundColor = .clear          // 바깥은 SwiftUI 레터박스(systemGray5)가 비친다
        host.contentInsetAdjustmentBehavior = .never
        host.bounces = true
        host.alwaysBounceVertical = true
        host.showsVerticalScrollIndicator = true
        host.showsHorizontalScrollIndicator = false
        host.bouncesZoom = true

        // Content view — 줌 대상(viewForZooming). 폭=논리폭 고정, 높이는 동적.
        let contentView = UIView()
        contentView.backgroundColor = isDark ? .black : .white   // 종이
        contentView.frame = CGRect(x: 0, y: 0, width: logical, height: logical * 2)
        host.addSubview(contentView)
        host.contentSize = contentView.bounds.size

        // PencilKit — 그리기 전용 오버레이
        #if targetEnvironment(simulator)
        canvasView.drawingPolicy = .anyInput
        #else
        // 펜 페어링 시 펜 전용(팜 리젝션 자동), 펜 없으면 손가락 필기 허용.
        // App Review G4: 펜 없는 기기에서도 사용 가능해야 함 (.pencilOnly 리젝 → .default)
        canvasView.drawingPolicy = .default
        #endif
        canvasView.isScrollEnabled = false     // 강등: 스크롤/줌은 host가 담당
        canvasView.backgroundColor = .clear     // 종이는 contentView가 그린다
        canvasView.isOpaque = false
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.tool = PKInkingTool(.pen, color: isDark ? .white : .black, width: 3)
        canvasView.delegate = coordinator
        canvasView.frame = contentView.bounds
        contentView.addSubview(canvasView)

        coordinator.host = host
        coordinator.contentView = contentView
        coordinator.canvas = canvasView

        // Load saved drawing — only if canvas is empty (avoid overwriting on rotation)
        if canvasView.drawing.strokes.isEmpty,
           let data = initialDrawingData,
           let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
        }

        appLogDebug("canvas", "makeUIView", [
            "logical": "\(Int(logical))",
            "drawingPolicy": "\(canvasView.drawingPolicy.rawValue)",
            "hasDrawing": "\(initialDrawingData != nil)",
        ])

        // Tool picker setup after view is in window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let toolPicker = PKToolPicker()
            toolPicker.setVisible(true, forFirstResponder: canvasView)
            toolPicker.addObserver(canvasView)
            coordinator.toolPicker = toolPicker
            let became = canvasView.becomeFirstResponder()
            appLogDebug("canvas", "toolPicker setup", [
                "becameFirstResponder": "\(became)",
                "window": "\(canvasView.window != nil)",
                "bounds": "\(canvasView.bounds)",
                "isUserInteractionEnabled": "\(canvasView.isUserInteractionEnabled)",
            ])
        }

        return host
    }

    func updateUIView(_ host: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        let isDark = colorScheme == .dark
        coordinator.isDarkMode = isDark
        coordinator.onFeedbackTapped = onFeedbackTapped
        coordinator.onFeedbackRevert = onFeedbackRevert
        coordinator.onStrokeRejected = onStrokeRejected
        coordinator.contentView?.backgroundColor = isDark ? .black : .white
        // Only update tool color if user hasn't picked a custom color via tool picker
        if let inkTool = canvasView.tool as? PKInkingTool,
           inkTool.color == .black || inkTool.color == .white {
            canvasView.tool = PKInkingTool(inkTool.inkType, color: isDark ? .white : .black, width: inkTool.width)
        }

        // 줌-투-핏 + 레터박스 중앙정렬 (회전·divider로 panelWidth가 바뀌면 zoomScale=fit)
        coordinator.applyPanelLayout(panelWidth: panelWidth)
        // 빈 페이지에서도 종이가 viewport를 채우도록 최소 높이 보장
        coordinator.ensureMinimumContentHeight()

        // Render feedback cards — coordinator에 위임
        // [diag] 회전/리사이즈 후 host 상태가 panelWidth와 일관되는지
        appLog("zoomdiag", "updateUIView", [
            "panelWidth": "\(Int(panelWidth))",
            "hostW": "\(Int(host.bounds.width))",
            "hostH": "\(Int(host.bounds.height))",
            "zoom": String(format: "%.3f", host.zoomScale),
            "minZoom": String(format: "%.3f", host.minimumZoomScale),
            "insetL": "\(Int(host.contentInset.left))",
            "cvW": "\(Int(coordinator.contentView?.bounds.width ?? -1))",
            "cvH": "\(Int(coordinator.contentView?.bounds.height ?? -1))",
            "contentSizeH": "\(Int(host.contentSize.height))",
            "feedbacks": "\(feedbacks.count)",
        ])
        context.coordinator.renderAllCards(on: canvasView, feedbacks: feedbacks)
        context.coordinator.updateFrozenOverlay(on: canvasView)
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

    class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
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

        // MARK: - Native zoom hierarchy (host > contentView > canvas)
        /// 줌/팬/세로스크롤 주체. makeUIView에서 설정.
        weak var host: UIScrollView?
        /// 줌 대상(viewForZooming). 카드·오버레이·indicator가 사는 컨테이너. 폭=논리폭 고정.
        weak var contentView: UIView?
        /// 그리기 전용 PencilKit. contentView의 자식.
        weak var canvas: PKCanvasView?
        /// 마지막으로 적용한 패널 폭 — 변하면 zoom-to-fit 재적용.
        private var lastPanelWidth: CGFloat = 0
        /// renderAllCards 멱등성 가드 — 카드 표시/레이아웃에 영향 주는 입력의 시그니처.
        /// 동일하면 재생성(특히 WKWebView reload)을 건너뛴다. 필기 중 깜빡임 방지.
        private var lastCardsSignature: String?
        var frozenBottom: CGFloat = 0
        var frozenEndIndex: Int = 0
        var previousStrokeCount: Int = 0
        var isDarkMode: Bool = false
        private var saveTimer: Timer?
        private var nextPositionIndicator: UIView?
        /// 다음 카드가 놓일 Y — 가이드라인(점선)이 그려지는 위치이자 배치의 단일 진실(SSOT).
        /// updateNextPositionIndicator에서만 갱신되고, appendFeedbackCard는 이 값을 그대로 사용한다.
        private(set) var nextCardLineY: CGFloat = 100

        init(onDrawingChanged: @escaping () -> Void) {
            self.onDrawingChanged = onDrawingChanged
        }

        /// 폭의 단일 진실(SSOT) = 논리폭 상수. contentView 폭이 항상 논리폭이므로 줌 중 bounds가
        /// 흔들려도 안전하다. frozen 오버레이·카드·indicator가 모두 이 값을 쓴다.
        func currentWidth(_ canvasView: PKCanvasView) -> CGFloat {
            Config.logicalCanvasWidth
        }

        // MARK: - Native zoom helpers

        /// 카드·오버레이·indicator가 사는 컨테이너 — contentView. 폴백으로 canvasView.
        private func container(_ canvasView: PKCanvasView) -> UIView {
            contentView ?? canvasView
        }

        /// 줌-투-핏: 폭이 바뀌면 fit=min(1, 폭/논리폭)으로 zoomScale을 맞춘다.
        /// 패널이 논리폭보다 넓으면 zoom=1 + contentInset으로 가운데 정렬(레터박스).
        private func fitAndCenter(forWidth width: CGFloat, src: String = "?") {
            guard let host, width > 0 else {
                appLog("zoomdiag", "fitAndCenter skip", ["src": src, "width": "\(Int(width))", "hasHost": "\(host != nil)"])
                return
            }
            let logical = Config.logicalCanvasWidth
            let fit = min(1, width / logical)
            host.minimumZoomScale = fit
            host.maximumZoomScale = max(fit, 3.0)   // 핀치 줌 허용
            let willReset = abs(width - lastPanelWidth) > 0.5
            if willReset {
                lastPanelWidth = width
                host.zoomScale = fit
            }
            // [diag] zoom-to-fit 결정 추적 — 회전 시 width 변경이 zoomScale에 반영되는지
            appLog("zoomdiag", "fitAndCenter", [
                "src": src,
                "width": "\(Int(width))",
                "logical": "\(Int(logical))",
                "fit": String(format: "%.3f", fit),
                "didResetZoom": "\(willReset)",
                "zoomAfter": String(format: "%.3f", host.zoomScale),
                "lastPanelW": "\(Int(lastPanelWidth))",
            ])
            centerContent()
        }

        /// SwiftUI(updateUIView)에서 패널 폭 전달 — 회전/divider 변경 시.
        func applyPanelLayout(panelWidth: CGFloat) {
            fitAndCenter(forWidth: panelWidth, src: "applyPanelLayout")
        }

        /// host 레이아웃 완료 시 — 중앙정렬·최소높이만. (줌-fit은 panelWidth(SSOT)로만 결정 →
        /// host.bounds로 재-fit하면 divider 중 host.bounds가 stale이라 zoomScale이 진동했음.)
        func hostDidLayout() {
            centerContent()
            ensureMinimumContentHeight()
        }

        /// 줌 시(scrollViewDidZoom) 및 패널 변경 시 — 콘텐츠가 viewport보다 좁으면 가로 가운데 정렬.
        func centerContent() {
            guard let host, let contentView else { return }
            let scaledW = contentView.bounds.width * host.zoomScale
            // 인셋도 줌과 동일한 폭 SSOT(lastPanelWidth)로 계산 — host.bounds는 divider 중 stale이라
            // 줌(panelWidth 기준)과 기준이 어긋나 콘텐츠가 밀렸음. 폴백으로만 host.bounds.
            let viewportW = lastPanelWidth > 0 ? lastPanelWidth : host.bounds.width
            let insetX = max(0, (viewportW - scaledW) / 2)
            // 세로는 상단 정렬(종이는 위에서 시작) → top inset 0.
            let newInset = UIEdgeInsets(top: 0, left: insetX, bottom: 0, right: insetX)
            if host.contentInset != newInset {
                host.contentInset = newInset
            }
        }

        /// contentView 높이를 h로 설정 — 줌 transform이 걸린 상태에서도 top-left를 고정한 채 아래로 확장.
        func setContentHeight(_ h: CGFloat) {
            guard let host, let contentView else { return }
            let s = host.zoomScale
            let w = contentView.bounds.width
            let origin = contentView.frame.origin
            let oldH = contentView.bounds.height
            contentView.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            contentView.center = CGPoint(x: origin.x + (w * s) / 2, y: origin.y + (h * s) / 2)
            // canvas.frame은 "커질 때만" 재할당 — 같은/작은 높이로 다시 세팅하면 PencilKit이 전체
            // 스트로크를 재래스터화해 깜빡인다(슬라이더 드래그 중 contentView가 1640으로 churn해도
            // 캔버스는 안 건드림). 페이지보다 큰 캔버스는 도달 불가 영역일 뿐 무해.
            let canvasFrameReset = (canvas?.frame.height ?? 0) < h
            if canvasFrameReset {
                canvas?.frame = CGRect(x: 0, y: 0, width: w, height: h)
            }
            host.contentSize = CGSize(width: w * s, height: h * s)
            // [diag] 호출 빈도/캔버스 프레임 재할당 추적 (슬라이더 깜빡임 원인)
            setContentHeightCount += 1
            appLog("flickerdiag", "setContentHeight", [
                "n": "\(setContentHeightCount)",
                "oldH": "\(Int(oldH))", "newH": "\(Int(h))",
                "zoom": String(format: "%.3f", s),
                "canvasFrameReset": "\(canvasFrameReset)",
            ])
        }
        private var setContentHeightCount = 0
        private var drawChangeCount = 0

        /// contentView 높이가 h보다 작으면 확장. host/contentView 미연결(단위 테스트 등) 시엔
        /// fallbackCanvas(또는 self.canvas)의 contentSize로 직접 확장.
        func ensureContentHeight(_ h: CGFloat, fallbackCanvas: PKCanvasView? = nil) {
            if let contentView {
                if contentView.bounds.height < h { setContentHeight(h) }
            } else if let cv = fallbackCanvas ?? canvas {
                if cv.contentSize.height < h { cv.contentSize.height = h }
            }
        }

        /// 빈 페이지에서도 종이가 viewport를 채우도록 최소 높이(현재 줌 기준 1.5화면) 보장.
        func ensureMinimumContentHeight() {
            guard let host else { return }
            let s = max(host.zoomScale, 0.01)
            let minH = max((host.bounds.height / s) * 1.5, Config.logicalCanvasWidth)
            ensureContentHeight(minH)
        }

        /// 페이지 전환 시 — 기본 높이로 축소하고 최상단으로.
        func resetToTop() {
            guard let host else { return }
            let s = max(host.zoomScale, 0.01)
            let h = max((host.bounds.height / s) * 1.5, Config.logicalCanvasWidth)
            setContentHeight(h)
            host.setContentOffset(CGPoint(x: -host.contentInset.left, y: -host.contentInset.top), animated: false)
        }

        /// 새 카드가 viewport 안에 들어오도록 자동 스크롤 — 카드 상단이 화면 1/3 지점에(줌 배율 반영).
        func scrollCardIntoView(positionY: CGFloat) {
            guard let host else { return }
            let s = host.zoomScale
            let vh = host.bounds.height
            guard vh > 0 else { return }
            let targetY = max(-host.contentInset.top, positionY * s - vh / 3)
            let maxY = max(-host.contentInset.top, host.contentSize.height - vh)
            let clamped = min(targetY, maxY)
            host.setContentOffset(CGPoint(x: -host.contentInset.left, y: clamped), animated: true)
            appLog("note", "auto scroll", ["targetY": "\(Int(clamped))", "cardY": "\(Int(positionY))", "zoom": "\(s)"])
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent()
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
            appLogDebug("canvas", "frozen recalc", [
                "bottom": "\(Int(frozenBottom))",
                "endIndex": "\(frozenEndIndex)",
                "strokes": "\(previousStrokeCount)",
            ])
        }

        func removeCard(on canvasView: PKCanvasView, feedbackId: String) {
            let c = container(canvasView)
            c.subviews
                .filter { $0.tag == 9999 && $0.accessibilityIdentifier == feedbackId }
                .forEach { $0.removeFromSuperview() }
            // lastRenderedBottom 재계산 (남은 카드 기준)
            let remaining = c.subviews.filter { $0.tag == 9999 }
            lastRenderedBottom = remaining.map { $0.frame.maxY }.max() ?? 0
        }

        func updateFrozenOverlay(on canvasView: PKCanvasView) {
            let width = currentWidth(canvasView)
            guard width > 0 else { return }
            let c = container(canvasView)

            // 중복 제거
            let existing = c.subviews.filter { $0.tag == 9997 }
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
                c.addSubview(overlay)
                c.sendSubviewToBack(overlay)
            }
            let alpha: CGFloat = isDarkMode ? 0.10 : 0.07
            overlay.backgroundColor = UIColor.systemGray.withAlphaComponent(alpha)
            overlay.frame = CGRect(x: 0, y: 0, width: width, height: max(0, frozenBottom))
            overlay.isHidden = frozenBottom <= 0
        }

        // MARK: - Card Rendering

        /// 전체 카드를 다시 렌더링 (페이지 로드, 다크모드 전환 시)
        func renderAllCards(on canvasView: PKCanvasView, feedbacks: [FeedbackRecord]) {
            // 멱등성 가드: 카드에 영향 주는 입력이 그대로면 재생성 스킵.
            // (필기 중 onStrokeChanged→@State 갱신→updateUIView가 매번 들어와도 WKWebView reload 안 함)
            let effectiveWidth = currentWidth(canvasView)
            let c = container(canvasView)
            let existingCardCount = c.subviews.filter { $0.tag == 9999 }.count
            let signature = "\(Int(effectiveWidth))|" + feedbacks.map {
                "\($0.id):\($0.userRating):\($0.serverFeedbackId ?? "-"):\(Int($0.positionY)):\($0.content.hashValue)"
            }.joined(separator: ";")
            // 카드 수가 시그니처와 일치할 때만 스킵 — 외부에서 카드가 지워진 경우(페이지 전환 등)엔 재생성.
            if signature == lastCardsSignature, existingCardCount == feedbacks.count {
                return
            }
            lastCardsSignature = signature

            c.subviews.filter { $0.tag == 9999 }.forEach { $0.removeFromSuperview() }
            lastRenderedBottom = 0
            for (i, fb) in feedbacks.enumerated() {
                renderCard(on: canvasView, feedback: fb, isLast: i == feedbacks.count - 1)
            }
            updateNextPositionIndicator(on: canvasView)
            recalculateFrozenBottom(on: canvasView, feedbacks: feedbacks)
        }

        /// 단일 카드를 캔버스에 추가 (피드백 수신 시 직접 호출)
        func renderCard(on canvasView: PKCanvasView, feedback fb: FeedbackRecord, isLast: Bool = true) {
            let cardWidth = currentWidth(canvasView) - 32
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

            let rawText = parsed?.displayText ?? fb.content
            let useKaTeX = MarkdownRender.shouldUseKaTeX(rawText)

            // 네이티브 경로의 표시 + (양 경로 공통) 높이 추정용 텍스트뷰.
            // KaTeX 경로에선 측정 전용이고, 표시는 BakedMarkdownUIView(WKWebView)가 한다.
            let textView = UITextView()
            textView.isEditable = false
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            if let attrStr = try? NSAttributedString(
                markdown: rawText,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                let mutable = NSMutableAttributedString(attributedString: attrStr)
                mutable.addAttributes([
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.label,
                ], range: NSRange(location: 0, length: mutable.length))
                textView.attributedText = mutable
            } else {
                textView.text = rawText
                textView.font = .systemFont(ofSize: 14)
                textView.textColor = .label
            }

            // 표시 뷰: 수식이면 WKWebView, 아니면 네이티브 텍스트뷰(측정뷰 재사용).
            let label: UIView = useKaTeX ? BakedMarkdownUIView(content: rawText, fontSize: 14) : textView

            let buttonBar = UIStackView()
            buttonBar.axis = .horizontal
            buttonBar.spacing = 12
            buttonBar.alignment = .center

            let chatBtn = UIButton(type: .system)
            chatBtn.setImage(UIImage(systemName: "bubble.left.fill"), for: .normal)
            chatBtn.setTitle(" " + String(localized: "대화"), for: .normal)
            chatBtn.titleLabel?.font = .systemFont(ofSize: 12)
            chatBtn.tintColor = .secondaryLabel
            let chatGesture = FeedbackTapGesture(target: self, action: #selector(feedbackCardTapped(_:)))
            chatGesture.feedbackRecord = fb
            chatBtn.addGestureRecognizer(chatGesture)

            buttonBar.addArrangedSubview(chatBtn)

            // Rating buttons — 모든 AI 응답 카드에 노출
            let upBtn = UIButton(type: .system)
            let upName = fb.userRating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup"
            upBtn.setImage(UIImage(systemName: upName), for: .normal)
            upBtn.tintColor = fb.userRating == 1 ? UIColor.systemGreen : UIColor.secondaryLabel
            upBtn.isEnabled = fb.serverFeedbackId != nil
            let upGesture = FeedbackTapGesture(target: self, action: #selector(feedbackThumbUpTapped(_:)))
            upGesture.feedbackRecord = fb
            upBtn.addGestureRecognizer(upGesture)
            buttonBar.addArrangedSubview(upBtn)

            let downBtn = UIButton(type: .system)
            let downName = fb.userRating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown"
            downBtn.setImage(UIImage(systemName: downName), for: .normal)
            downBtn.tintColor = fb.userRating == -1 ? UIColor.systemRed : UIColor.secondaryLabel
            downBtn.isEnabled = fb.serverFeedbackId != nil
            let downGesture = FeedbackTapGesture(target: self, action: #selector(feedbackThumbDownTapped(_:)))
            downGesture.feedbackRecord = fb
            downBtn.addGestureRecognizer(downGesture)
            buttonBar.addArrangedSubview(downBtn)

            let detailBtn = UIButton(type: .system)
            detailBtn.setTitle(String(localized: "자세히"), for: .normal)
            detailBtn.titleLabel?.font = .systemFont(ofSize: 12)
            detailBtn.tintColor = .secondaryLabel
            detailBtn.isEnabled = fb.serverFeedbackId != nil
            let detailGesture = FeedbackTapGesture(target: self, action: #selector(feedbackRateDetailTapped(_:)))
            detailGesture.feedbackRecord = fb
            detailBtn.addGestureRecognizer(detailGesture)
            buttonBar.addArrangedSubview(detailBtn)

            buttonBar.addArrangedSubview(UIView())

            if isLast {
                let revertBtn = UIButton(type: .system)
                revertBtn.tag = 8888
                revertBtn.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
                revertBtn.setTitle(" " + String(localized: "되돌리기"), for: .normal)
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

            let labelSize = textView.sizeThatFits(CGSize(width: cardWidth - 24, height: .greatestFiniteMagnitude))
            let cardHeight = labelSize.height + 48

            card.frame = CGRect(x: 16, y: fb.positionY, width: cardWidth, height: cardHeight)
            container(canvasView).addSubview(card)

            let cardBottom = fb.positionY + cardHeight
            ensureContentHeight(cardBottom + 200, fallbackCanvas: canvasView)
            lastRenderedBottom = max(lastRenderedBottom, cardBottom)
            updateNextPositionIndicator(on: canvasView)
        }

        /// 다음 피드백 카드가 들어갈 위치를 dashed line + 라벨로 표시 — 스트로크/카드 변동 시마다 갱신
        func updateNextPositionIndicator(on canvasView: PKCanvasView) {
            let width = currentWidth(canvasView)
            guard width > 0 else {
                appLogDebug("indicator", "skip: width=0", ["bounds": "\(canvasView.bounds)"])
                return
            }

            let y = calculateNextCardY(on: canvasView, currentNextCardY: 100)
            nextCardLineY = y  // SSOT 갱신 — 배치는 이 값을 읽는다
            let strokeMaxY = canvasView.drawing.strokes.isEmpty
                ? CGFloat(0)
                : canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }

            // container(contentView)에서 직접 indicator 조회 — Coordinator 재생성 시에도 안전
            // 중복(stale)이 있으면 첫 번째만 남기고 모두 제거
            let c = container(canvasView)
            let allIndicators = c.subviews.filter { $0.tag == 9998 }
            if allIndicators.count > 1 {
                allIndicators.dropFirst().forEach { $0.removeFromSuperview() }
                appLogDebug("indicator", "stale removed", ["count": "\(allIndicators.count - 1)"])
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
                line.strokeColor = UIColor.separator.withAlphaComponent(0.6).cgColor
                line.fillColor = nil
                line.lineWidth = 1.0
                line.lineDashPattern = [4, 4]
                indicator.layer.addSublayer(line)

                c.addSubview(indicator)
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

            c.bringSubviewToFront(indicator)

            appLogDebug("indicator", isNew ? "created" : "updated", [
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

            // Auto-expand content height (downward only). 버퍼는 viewport를 콘텐츠 좌표로 환산(줌 반영).
            let viewportInContent = host.map { $0.bounds.height / max($0.zoomScale, 0.01) } ?? canvasView.bounds.height
            let drawingBottom = canvasView.drawing.strokes.isEmpty
                ? viewportInContent
                : canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }
            // [diag] 그리기 변경 발화 빈도/목표 높이 추적 — setContentHeight가 매 발화마다 도는지 대조
            drawChangeCount += 1
            let cvH = contentView?.bounds.height ?? -1
            let target = drawingBottom + viewportInContent * 2
            appLog("flickerdiag", "drawDidChange", [
                "n": "\(drawChangeCount)",
                "strokes": "\(strokes.count)",
                "drawBottom": "\(Int(drawingBottom))",
                "target": "\(Int(target))",
                "cvH": "\(Int(cvH))",
                "willGrow": "\(cvH < target)",
            ])
            ensureContentHeight(target, fallbackCanvas: canvasView)

            updateNextPositionIndicator(on: canvasView)

            onStrokeChanged?()

            saveTimer?.invalidate()
            saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.onDrawingChanged()
            }
        }
    }
}
