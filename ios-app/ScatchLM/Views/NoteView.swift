import SwiftUI
import PencilKit
import PDFKit
import UniformTypeIdentifiers

// Custom tap gesture that carries a FeedbackRecord
class FeedbackTapGesture: UITapGestureRecognizer {
    var feedbackRecord: FeedbackRecord?
}

/// 피드백 카드 복사용 앱 세션 클립보드. 복사 시 카드 content(JSON/텍스트)를 담고,
/// 빈 곳 길게누르기 메뉴로 아무 페이지에나 붙여넣는다.
final class FeedbackClipboard {
    static let shared = FeedbackClipboard()
    var content: String?
    private init() {}
}

/// 세션 채팅 시트 표시 컨텍스트 (chapter-chat-drawer-spec §4.4).
/// `.sheet(item:)`가 요구하는 Identifiable — id는 세션 id.
struct ChatSheetContext: Identifiable {
    var id: String { session.id }
    let session: ChatSessionRecord
    var headerContent: String?
    var headerServerId: String?
}

/// PencilKit 기본 paste: 액션(시스템 클립보드 → 캔버스)을 억제한다. 그래야 길게누르기 시
/// 시스템 "붙여넣기" 버블 대신 우리 커스텀 카드 붙여넣기 메뉴만 노출된다.
final class NoteCanvasView: PKCanvasView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)) { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

struct NoteView: View {
    let noteId: String

    @Environment(\.dismiss) private var dismiss
    @State private var note: Note?
    @State private var canvasView: PKCanvasView = NoteCanvasView()
    @State private var feedbacks: [FeedbackRecord] = []
    @State private var loading = false
    @State private var pdfOpen = false
    @State private var currentPage: Int = 1
    @State private var chatContext: ChatSheetContext?
    @State private var ratingSheetFeedback: FeedbackRecord?
    /// 카드 복사 클립보드(앱 세션 전역) — 복사 후 아무 페이지에서나 붙여넣기.
    private let clipboard = FeedbackClipboard.shared
    @State private var toastMessage: String?
    @State private var pendingRevert: FeedbackRecord?
    @State private var showPaywall = false
    // 노트 정보(제목·주제·교재) 편집 시트. focusTextbook=true면 교재 미연결 상태에서 PDF pill로 진입한 경우.
    @State private var showMetaEditor = false
    @State private var metaFocusTextbook = false
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
    @State private var showChapterDrawer: Bool = false
    @State private var canUndo: Bool = false
    @State private var canRedo: Bool = false
    // PDF/캔버스 분할 비율 (PDF 쪽 비율). 드래그 가능한 divider로 조정. 세션 휘발(영속 안 함).
    @State private var pdfFraction: CGFloat = 0.4
    // 드래그 시작 시점의 비율 앵커 — translation은 누적값이라 시작값 기준으로 계산.
    @State private var dragStartFraction: CGFloat?
    // divider 드래그 중에는 캔버스 zoom-to-fit을 보류(R-3 디바운스). 매 프레임 host.zoomScale을
    // 바꾸면 PencilKit이 매번 재래스터화돼 깜빡인다. 드래그 종료 시 1회만 fit.
    @State private var dividerDragging = false

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
                    // Split view: Canvas + PDF.
                    // 캔버스는 분기와 무관하게 ZStack 첫 자식으로 "항상 같은 위치"에 둔다 → SwiftUI 정체성
                    // 고정 → PDF 토글/회전에도 representable이 재생성되지 않음(makeUIView 1회). PDF/divider는
                    // 프레임+오프셋으로 배치. (이전: 상호배타 if/else 3분기 → 분기 전환마다 캔버스 재생성.)
                    let splitW = geo.size.width
                    let splitH = geo.size.height
                    let dthick = Self.dividerThickness
                    let landscape = isLandscape
                    let pdfW = (pdfOpen && landscape) ? splitW * clampedLandscapeFraction(splitW) : 0
                    let pdfH = (pdfOpen && !landscape) ? splitH * clampedPortraitFraction : 0
                    let canvasRect: CGRect = !pdfOpen
                        ? CGRect(x: 0, y: 0, width: splitW, height: splitH)
                        : (landscape
                            ? CGRect(x: pdfW + dthick, y: 0, width: max(0, splitW - pdfW - dthick), height: splitH)
                            : CGRect(x: 0, y: pdfH + dthick, width: splitW, height: max(0, splitH - pdfH - dthick)))

                    ZStack(alignment: .topLeading) {
                        // 캔버스 — 항상 첫 자식, 정체성 고정 (재생성 방지)
                        canvasPanel(note: note, panelWidth: canvasRect.width)
                            .frame(width: canvasRect.width, height: canvasRect.height)
                            .offset(x: canvasRect.minX, y: canvasRect.minY)

                        if pdfOpen {
                            pdfPanel(note: note)
                                .frame(width: landscape ? pdfW : splitW,
                                       height: landscape ? splitH : pdfH)
                            dividerHandle(isVertical: landscape, total: landscape ? splitW : splitH)
                                .frame(width: landscape ? dthick : splitW,
                                       height: landscape ? splitH : dthick)
                                .offset(x: landscape ? pdfW : 0, y: landscape ? 0 : pdfH)
                        }
                    }
                    .frame(width: splitW, height: splitH, alignment: .topLeading)

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
                                title: noteTitleDisplay,
                                template: NoteTemplate(storage: note.template),
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
                                },
                                onMove: { source, destination in
                                    movePages(from: source, to: destination)
                                },
                                onDelete: { page in
                                    deletePage(page)
                                },
                                onEditMeta: {
                                    metaFocusTextbook = false
                                    showMetaEditor = true
                                },
                                onSelectTemplate: { changeTemplate($0) }
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
        .sheet(isPresented: $showPaywall) {
            PaywallView(reason: String(localized: "오늘 무료 사용량을 모두 사용했어요. Pro로 업그레이드하면 더 많은 피드백을 받을 수 있어요."))
        }
        .sheet(isPresented: $showMetaEditor) {
            if let note {
                NoteMetaSheet(note: note, focusTextbook: metaFocusTextbook) { updated in
                    saveMeta(updated)
                }
            }
        }
        .sheet(item: $chatContext) { ctx in
            SessionChatSheet(
                session: ctx.session,
                headerContent: ctx.headerContent,
                headerServerId: ctx.headerServerId,
                textbookId: note?.textbookId,
                currentPage: currentPage,
                noteId: noteId,
                subject: note?.language,
                onPin: { content, responseId in
                    pinToCanvas(content: content, serverFeedbackId: responseId)
                }
            )
        }
        .sheet(isPresented: $showChapterDrawer) {
            ChapterDrawerView(
                noteId: noteId,
                textbookId: note?.textbookId,
                subject: note?.language,
                onJump: { fb in
                    showChapterDrawer = false
                    jumpToPlacement(fb)
                },
                onPin: { content, responseId in
                    showChapterDrawer = false
                    pinToCanvas(content: content, serverFeedbackId: responseId)
                }
            )
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
                        dividerDragging = true   // 드래그 중 zoom-fit 보류(R-3 디바운스)
                    }
                    let delta = (isVertical ? value.translation.width : value.translation.height) / total
                    let raw = start + delta
                    pdfFraction = isVertical ? clampLandscape(raw, total) : min(max(raw, 0.2), 0.7)
                }
                .onEnded { _ in
                    dragStartFraction = nil
                    dividerDragging = false   // 종료 시 zoom-fit 1회 적용(updateUIView 재호출)
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
            dividerDragging: dividerDragging,
            onDrawingChanged: {
                saveDrawing()
                refreshUndoState()
            },
            onStrokeChanged: {
                refreshUndoState()
            },
            template: NoteTemplate(storage: note.template),
            // 페이지 그림만 로드. note.drawingData(레거시 노트레벨 그림) 폴백은 page 0에만 적용 —
            // 새 페이지(index>0)가 옛 노트 그림을 ghost로 로드하던 경로를 차단.
            initialDrawingData: currentNotePage?.drawingData ?? (currentPageIndex == 0 ? note.drawingData : nil),
            feedbacks: feedbacks,
            onFeedbackTapped: { fb in
                openChat(for: fb)
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
            },
            onFeedbackCopy: { fb in
                clipboard.content = fb.content
                showToast(String(localized: "카드를 복사했어요. 빈 곳을 길게 눌러 붙여넣기 하세요."))
            },
            onPaste: {
                pasteFromClipboard()
            }
        )
        // 페이지가 바뀌면 .id 변경 → SwiftUI가 옛 캔버스를 dismantle하고 새로 makeUIView(언마운트/리마운트).
        // PDF토글·회전은 같은 page id라 재생성 안 함(정체성 안정 유지).
        .id(currentNotePage?.id ?? "no-page")
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

                // 페이지 슬라이드 오버 토글 — 제목 편집·페이지 추가/재정렬/삭제가 모두 그 안에 있어
                // 페이지 수와 무관하게 항상 슬라이드 오버를 연다.
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        pageNavOpen.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                }

                // 챕터 채팅 드로어 — 이 노트·교재에 귀속된 세션을 챕터별로 모아 본다(§4.3).
                Button {
                    showChapterDrawer = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
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

    /// 템플릿 변경 — 같은 값이면 no-op. note 상태 갱신 → SwiftUI가 updateUIView로 레이어 재렌더.
    private func changeTemplate(_ t: NoteTemplate) {
        guard var n = note, NoteTemplate(storage: n.template) != t else { return }
        n.template = t.rawValue
        do {
            try db.saveNote(&n)   // updatedAt/dirty 갱신 (inout)
            note = n
            appLog("note", "template changed", ["template": t.rawValue])
        } catch {
            appLogError("note", "template save failed", ["err": "\(error)"])
        }
    }

    /// 슬라이드 오버 상단에 표시할 제목. 비어 있으면 placeholder.
    private var noteTitleDisplay: String {
        if let t = note?.title, !t.isEmpty { return t }
        return String(localized: "제목 없음")
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
                },
                noteId: noteId
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

                // PDF toggle — 교재가 없으면 교재 설정 시트를 띄운다.
                Button {
                    if note.textbookId != nil {
                        pdfOpen.toggle()
                        try? db.updatePdfOpen(noteId: noteId, open: pdfOpen)
                    } else {
                        metaFocusTextbook = true
                        showMetaEditor = true
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

                // 최초 생성 후 진입: 교재가 연결돼 있으면 PDF 뷰어를 기본으로 연다.
                if note?.textbookId != nil {
                    pdfOpen = true
                    try? db.updatePdfOpen(noteId: noteId, open: true)
                }
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

    /// NoteMetaSheet 저장 — 제목·주제·교재를 영속화하고 화면 상태를 갱신한다.
    private func saveMeta(_ updated: Note) {
        let hadTextbook = note?.textbookId != nil
        var n = updated
        do {
            try db.saveNote(&n)
            note = n
            appLog("note", "meta saved", [
                "id": noteId,
                "hasPdf": "\(n.textbookId != nil)",
            ])
        } catch {
            appLogError("note", "meta save failed", ["error": "\(error)"])
            return
        }

        // 교재를 새로 붙였고 PDF pill을 통해 설정한 경우 → 바로 PDF 뷰어를 연다.
        if !hadTextbook, n.textbookId != nil, metaFocusTextbook {
            pdfOpen = true
            try? db.updatePdfOpen(noteId: noteId, open: true)
        }
        // 교재를 해제했으면 열려 있던 PDF를 닫는다.
        if n.textbookId == nil, pdfOpen {
            pdfOpen = false
            try? db.updatePdfOpen(noteId: noteId, open: false)
        }
        metaFocusTextbook = false
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

    /// 피드백/스크랩 카드를 캔버스에 추가하는 공통 함수.
    /// 카드는 세션을 캔버스에 배치한 placement다(§4.5). `sessionId`가 주어지면 그 세션에 연결하고
    /// (드로어 재스크랩 — 1 session→N cards), 없으면 이 카드용 kind=feedback 세션을 새로 만든다(세션화 통일).
    private func appendFeedbackCard(content: String, estimatedHeight: CGFloat = 400, strokeRangeStart: Int? = nil, strokeRangeEnd: Int? = nil, serverFeedbackId: String? = nil, sessionId: String? = nil) {
        let placementSessionId = sessionId ?? createFeedbackSession(content: content, serverFeedbackId: serverFeedbackId)?.id
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
            serverFeedbackId: serverFeedbackId,
            sessionId: placementSessionId
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
                // 렌더 후엔 실제 카드 높이를 쓴다. max(estimatedHeight, …)로 부풀리면 카드가 400보다
                // 짧을 때 frozen 영역이 카드 하단 아래까지 내려가 "회색 + 필기 불가" 데드존이 생긴다.
                record.bboxHeight = max(actualBottom - record.bboxY, 1)
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

    /// 클립보드의 카드 본문을 현재 페이지의 다음 카드 위치(가이드라인)에 정적 카드로 붙여넣는다.
    /// 현재 캔버스에 추가하는 것이라 위치·높이·frozen 계산은 appendFeedbackCard에 그대로 위임된다.
    private func pasteFromClipboard() {
        guard let content = clipboard.content else { return }
        // serverFeedbackId 없이 본문만 — 평점·자세히는 비활성, 대화는 새 컨텍스트로 시작.
        appendFeedbackCard(content: content)
        appLog("note", "feedback pasted", ["pageIndex": "\(currentPageIndex)", "contentLen": "\(content.count)"])
    }

    // MARK: - 세션 채팅 / 드로어 연동 (chapter-chat-drawer-spec §4.4/§4.5/Track D)

    /// 카드 본문(AIResponse JSON 또는 평문)에서 드로어/세션 제목용 짧은 스니펫을 만든다.
    private func feedbackTitleSnippet(_ content: String) -> String {
        var text = content
        if let data = content.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(AIResponse.self, from: data) {
            text = parsed.displayText
        }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.isEmpty { return String(localized: "피드백 대화") }
        return String(oneLine.prefix(40))
    }

    /// 카드 placement용 kind=feedback 세션을 새로 만든다. 교재 연결 시 anchorPage=현재 페이지.
    private func createFeedbackSession(content: String, serverFeedbackId: String?) -> ChatSessionRecord? {
        var session = ChatSessionRecord(
            kind: ChatSessionRecord.Kind.feedback.rawValue,
            title: feedbackTitleSnippet(content),
            noteId: noteId,
            textbookId: note?.textbookId,
            anchorPage: note?.textbookId != nil ? currentPage : nil,
            sourceFeedbackId: serverFeedbackId
        )
        do {
            try db.saveSession(&session)
            return session
        } catch {
            appLogError("note", "createFeedbackSession failed", ["error": "\(error)"])
            return nil
        }
    }

    /// 카드 탭 → 세션 채팅 열기. 카드에 세션이 없으면(레거시) 새로 만들어 연결한다.
    private func openChat(for fb: FeedbackRecord) {
        let session: ChatSessionRecord?
        if let sid = fb.sessionId, let existing = try? db.session(id: sid) {
            session = existing
        } else {
            // 레거시 단독 카드: 세션 생성 후 카드에 역연결.
            guard let created = createFeedbackSession(content: fb.content, serverFeedbackId: fb.serverFeedbackId) else { return }
            var card = fb
            card.sessionId = created.id
            do {
                try db.saveFeedback(&card)
                if let idx = feedbacks.firstIndex(where: { $0.id == fb.id }) { feedbacks[idx] = card }
            } catch {
                appLogError("note", "link card→session failed", ["error": "\(error)"])
            }
            session = created
        }
        guard let session else { return }
        chatContext = ChatSheetContext(
            session: session,
            headerContent: fb.content,
            headerServerId: fb.serverFeedbackId
        )
    }

    /// 드로어 → 캔버스로 점프. placement 카드의 페이지로 이동 후 해당 위치로 스크롤한다.
    private func jumpToPlacement(_ fb: FeedbackRecord) {
        if let pid = fb.pageId, let idx = notePages.firstIndex(where: { $0.id == pid }), idx != currentPageIndex {
            goToPage(index: idx)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            (canvasView.delegate as? PencilKitCanvasView.Coordinator)?.scrollCardIntoView(positionY: fb.positionY)
        }
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

    private func newPage() {
        saveDrawing()   // 현재(옛) 페이지 저장

        let newIndex = notePages.count
        guard let page = try? db.createPage(noteId: noteId, pageIndex: newIndex) else { return }
        notePages.append(page)
        currentPageIndex = newIndex
        currentNotePage = page
        try? db.updateCurrentPageIndex(noteId: noteId, index: newIndex)

        // 페이지별 새 캔버스 인스턴스로 교체. .id(currentNotePage.id) 변경으로 옛 캔버스가 언마운트되고
        // 새 캔버스가 mount된다 → 공유 인스턴스가 아니므로 이전 페이지 렌더(ghost)가 구조적으로 불가능.
        canvasView = NoteCanvasView()
        feedbacks = []
        nextCardY = 100
        appLog("note", "newPage", ["index": "\(newIndex)"])
    }

    private func goToPage(index: Int) {
        guard index >= 0, index < notePages.count, index != currentPageIndex else { return }

        saveDrawing()   // 현재(옛) 페이지 저장
        currentPageIndex = index
        currentNotePage = notePages[index]
        try? db.updateCurrentPageIndex(noteId: noteId, index: index)

        // 새 캔버스 인스턴스 → 리마운트. 페이지 그림은 makeUIView가 initialDrawingData로 로드한다.
        canvasView = NoteCanvasView()
        feedbacks = (try? db.feedbacks(pageId: notePages[index].id)) ?? []
        nextCardY = 100
        appLog("note", "goToPage", ["index": "\(index)", "feedbacks": "\(feedbacks.count)"])
    }

    /// 페이지 순서 변경(드래그 재정렬). 보고 있던 페이지는 그대로 열어둔다 — 캔버스 재로드 불필요.
    private func movePages(from source: IndexSet, to destination: Int) {
        saveDrawing()   // 현재 페이지 그림 보존
        let currentId = currentNotePage?.id
            ?? (notePages.indices.contains(currentPageIndex) ? notePages[currentPageIndex].id : nil)

        notePages.move(fromOffsets: source, toOffset: destination)
        try? db.reorderPages(noteId: noteId, orderedIds: notePages.map { $0.id })

        if let currentId, let newIdx = notePages.firstIndex(where: { $0.id == currentId }) {
            currentPageIndex = newIdx
            currentNotePage = notePages[newIdx]
            try? db.updateCurrentPageIndex(noteId: noteId, index: newIdx)
        }
        appLog("note", "movePages", ["to": "\(destination)", "current": "\(currentPageIndex)"])
    }

    /// 페이지 삭제(스와이프). 소프트 삭제 + 남은 페이지 재압축. 마지막 한 장은 삭제 불가.
    private func deletePage(_ page: NotePage) {
        guard notePages.count > 1 else {
            showToast(String(localized: "마지막 페이지는 삭제할 수 없어요."))
            return
        }
        guard let removeIdx = notePages.firstIndex(where: { $0.id == page.id }) else { return }
        let wasCurrent = (removeIdx == currentPageIndex)

        // 현재 페이지가 아니면 보고 있던 캔버스를 먼저 저장(삭제 대상 페이지는 버린다)
        if !wasCurrent { saveDrawing() }

        notePages.remove(at: removeIdx)
        do {
            try db.deletePage(noteId: noteId, pageId: page.id, remainingOrderedIds: notePages.map { $0.id })
        } catch {
            appLogError("note", "deletePage failed", ["id": page.id, "error": "\(error)"])
            notePages.insert(page, at: removeIdx)   // 로컬 상태 롤백
            showToast(String(localized: "페이지를 삭제하지 못했어요."))
            return
        }

        if wasCurrent {
            // 삭제된 자리(또는 마지막) 페이지로 전환 — goToPage와 동일하게 캔버스 재마운트
            let newIdx = min(removeIdx, notePages.count - 1)
            currentPageIndex = newIdx
            currentNotePage = notePages[newIdx]
            try? db.updateCurrentPageIndex(noteId: noteId, index: newIdx)
            canvasView = NoteCanvasView()
            feedbacks = (try? db.feedbacks(pageId: notePages[newIdx].id)) ?? []
            nextCardY = 100
        } else if removeIdx < currentPageIndex {
            // 앞쪽 페이지가 빠졌으니 현재 인덱스만 한 칸 당김(보던 페이지는 그대로)
            currentPageIndex -= 1
            currentNotePage = notePages[currentPageIndex]
            try? db.updateCurrentPageIndex(noteId: noteId, index: currentPageIndex)
        }
        appLog("note", "deletePage", ["id": page.id, "remaining": "\(notePages.count)"])
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
                    "language": note?.language ?? "",
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
    /// divider 드래그 중이면 zoom-to-fit 보류(R-3 디바운스) — 매 프레임 줌 변경에 의한 깜빡임 방지.
    var dividerDragging: Bool = false
    var onDrawingChanged: () -> Void
    var onStrokeChanged: (() -> Void)? = nil
    /// 캔버스 배경 템플릿(오선지/줄노트/격자). 노트 단위 속성.
    var template: NoteTemplate = .blank
    var initialDrawingData: Data?
    var feedbacks: [FeedbackRecord]
    var onFeedbackTapped: ((FeedbackRecord) -> Void)?
    var onFeedbackRevert: ((FeedbackRecord) -> Void)?
    var onStrokeRejected: (() -> Void)?
    var onFeedbackRate: ((FeedbackRecord, Int) -> Void)?
    var onFeedbackRateDetail: ((FeedbackRecord) -> Void)?
    var onFeedbackCopy: ((FeedbackRecord) -> Void)?
    var onPaste: (() -> Void)?
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

        // 배경 템플릿 — 종이(contentView 배경색) 위, 잉크(canvas) 아래의 최하위 sublayer.
        // CATiledLayer라 캔버스 높이 확장·줌에도 메모리/선명도 유지(파일 주석 참조).
        let templateLayer = CanvasTemplateLayer()
        templateLayer.frame = contentView.bounds
        templateLayer.contentsScale = UIScreen.main.scale
        templateLayer.template = template
        templateLayer.isDark = isDark
        contentView.layer.insertSublayer(templateLayer, at: 0)
        coordinator.templateLayer = templateLayer

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

        // 붙여넣기: 빈 곳 길게누르기 → 편집 메뉴. 손가락 필기(.default)와 충돌하므로
        // 드로잉 제스처가 이 long-press 실패를 기다리게 해 분리한다(정지 0.5s=메뉴, 이동=필기).
        let pasteLongPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePasteLongPress(_:)))
        pasteLongPress.minimumPressDuration = 0.5
        // 손가락 전용 — 펜 터치는 이 제스처가 즉시 무시하므로 require(toFail:)가 펜 드로잉 시작을
        // 지연시키지 않는다. 지연(0.5s 분리)은 보조 입력인 손가락에만 적용된다.
        pasteLongPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvasView.addGestureRecognizer(pasteLongPress)
        canvasView.drawingGestureRecognizer.require(toFail: pasteLongPress)
        let editMenu = UIEditMenuInteraction(delegate: coordinator)
        canvasView.addInteraction(editMenu)
        coordinator.editMenuInteraction = editMenu

        // Load saved drawing — only if canvas is empty (avoid overwriting on rotation)
        if canvasView.drawing.strokes.isEmpty,
           let data = initialDrawingData,
           let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
        }

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
        coordinator.onFeedbackCopy = onFeedbackCopy
        coordinator.onPaste = onPaste
        coordinator.contentView?.backgroundColor = isDark ? .black : .white
        // 템플릿/다크모드 변경 시 didSet이 setNeedsDisplay 트리거(동일하면 no-op).
        coordinator.templateLayer?.isDark = isDark
        coordinator.templateLayer?.template = template
        // Only update tool color if user hasn't picked a custom color via tool picker
        if let inkTool = canvasView.tool as? PKInkingTool,
           inkTool.color == .black || inkTool.color == .white {
            canvasView.tool = PKInkingTool(inkTool.inkType, color: isDark ? .white : .black, width: inkTool.width)
        }

        // 줌-투-핏 + 레터박스 중앙정렬 (회전·divider로 panelWidth가 바뀌면 zoomScale=fit)
        coordinator.applyPanelLayout(panelWidth: panelWidth, isDragging: dividerDragging)
        // 빈 페이지에서도 종이가 viewport를 채우도록 최소 높이 보장
        coordinator.ensureMinimumContentHeight()

        // Render feedback cards — coordinator에 위임
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
        c.onFeedbackCopy = onFeedbackCopy
        c.onPaste = onPaste
        return c
    }

    class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate, UIEditMenuInteractionDelegate {
        let onDrawingChanged: () -> Void
        var onStrokeChanged: (() -> Void)?
        var onFeedbackTapped: ((FeedbackRecord) -> Void)?
        var onFeedbackRevert: ((FeedbackRecord) -> Void)?
        var onStrokeRejected: (() -> Void)?
        var onFeedbackRate: ((FeedbackRecord, Int) -> Void)?
        var onFeedbackRateDetail: ((FeedbackRecord) -> Void)?
        var onFeedbackCopy: ((FeedbackRecord) -> Void)?
        var onPaste: (() -> Void)?
        var editMenuInteraction: UIEditMenuInteraction?
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
        /// 배경 템플릿 타일 레이어. contentView.layer의 최하위 sublayer(잉크 아래). contentView가 retain.
        weak var templateLayer: CanvasTemplateLayer?
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
        private func fitAndCenter(forWidth width: CGFloat) {
            guard let host, width > 0 else { return }
            let logical = Config.logicalCanvasWidth
            let fit = min(1, width / logical)
            host.minimumZoomScale = fit
            host.maximumZoomScale = max(fit, 3.0)   // 핀치 줌 허용
            if abs(width - lastPanelWidth) > 0.5 {
                lastPanelWidth = width
                host.zoomScale = fit
            }
            centerContent()
        }

        /// SwiftUI(updateUIView)에서 패널 폭 전달 — 회전/divider 변경 시.
        /// divider 드래그 중(isDragging)이면 zoom-fit을 보류해 매 프레임 zoomScale 변경(=PencilKit
        /// 재래스터화·깜빡임)을 막는다. 드래그 종료 시 isDragging=false로 1회 fit(R-3 디바운스).
        func applyPanelLayout(panelWidth: CGFloat, isDragging: Bool = false) {
            guard !isDragging else { return }
            fitAndCenter(forWidth: panelWidth)
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
            // 변환 입력값 — origin/zoomScale이 스크롤 직후 흔들리면 center가 매번 미세하게 달라져 상하 진동.
            appLogDebug("canvas", "setH", [
                "h": "\(Int(h))",
                "zoom": String(format: "%.4f", s),
                "originY": String(format: "%.1f", origin.y),
                "newCenterY": String(format: "%.1f", origin.y + (h * s) / 2),
            ])
            contentView.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            contentView.center = CGPoint(x: origin.x + (w * s) / 2, y: origin.y + (h * s) / 2)
            canvas?.frame = contentView.bounds
            // 템플릿 레이어도 함께 확장. implicit 애니메이션 차단(깜빡임 방지) — 새 타일은
            // CATiledLayer가 fade 없이(fadeDuration=0) 채운다.
            if let templateLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                templateLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)
                CATransaction.commit()
            }
            host.contentSize = CGSize(width: w * s, height: h * s)
        }

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

        @objc func feedbackCopyTapped(_ gesture: FeedbackTapGesture) {
            if let fb = gesture.feedbackRecord { onFeedbackCopy?(fb) }
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

            // 다른 페이지로 복사 — 카드 본문을 그대로 다른 페이지에 정적 카드로 얹는다.
            let copyBtn = UIButton(type: .system)
            copyBtn.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
            copyBtn.tintColor = .secondaryLabel
            let copyGesture = FeedbackTapGesture(target: self, action: #selector(feedbackCopyTapped(_:)))
            copyGesture.feedbackRecord = fb
            copyBtn.addGestureRecognizer(copyGesture)
            buttonBar.addArrangedSubview(copyBtn)

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

        /// 빈 영역 길게누르기 → "붙여넣기" 메뉴. 클립보드가 비어 있으면 메뉴를 띄우지 않는다.
        @objc func handlePasteLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began,
                  FeedbackClipboard.shared.content != nil,
                  let canvas = canvas else { return }
            let loc = g.location(in: canvas)
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: loc)
            editMenuInteraction?.presentEditMenu(with: config)
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                 menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            let paste = UIAction(title: String(localized: "붙여넣기"),
                                 image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.onPaste?()
            }
            return UIMenu(children: [paste])
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
                // 거부 판정의 입력값을 그대로 남긴다 — minY가 frozenBottom 바로 위(오판 의심)인지,
                // 좌표계가 어긋나 정상 영역 입력이 거부되는지(이동/스크롤 후 깜빡임 원인 후보) 구분용.
                appLogDebug("canvas", "stroke check", [
                    "addedMinYs": "\(added.map { Int($0.renderBounds.minY) })",
                    "frozenBottom": "\(Int(frozenBottom))",
                    "rejected": "\(invalidIdx.count)",
                ])
                if !invalidIdx.isEmpty {
                    let invalidSet = Set(invalidIdx)
                    let kept = strokes.enumerated().filter { !invalidSet.contains($0.offset) }.map { $0.element }
                    // PKDrawing 통째 재할당 → PencilKit 전체 재래스터화(큰 깜빡임 후보).
                    canvasView.drawing = PKDrawing(strokes: kept)
                    appLog("canvas", "stroke rejected", ["count": "\(invalidIdx.count)", "frozenBottom": "\(Int(frozenBottom))"])
                    onStrokeRejected?()
                }
            }
            previousStrokeCount = canvasView.drawing.strokes.count

            // Auto-expand content height (downward only). 버퍼는 viewport를 콘텐츠 좌표로 환산(줌 반영).
            let viewportInContent = host.map { $0.bounds.height / max($0.zoomScale, 0.01) } ?? canvasView.bounds.height
            // 빈 드로잉의 bottom은 의미상 0. (과거엔 viewportInContent로 부풀렸으나, 그러면 undo로
            // 마지막 획이 지워질 때 drawingBottom이 0→viewport로 점프 → targetH 증가 → setContentHeight가
            // 캔버스를 reframe → PencilKit '비우기' 렌더를 끊어 마지막 획이 잔상으로 남았다. 빈 캔버스 최소
            // 높이는 ensureMinimumContentHeight(updateUIView)가 별도 보장하므로 여기선 0이 맞다.)
            let drawingBottom = canvasView.drawing.strokes.isEmpty
                ? 0
                : canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }
            // 스트로크마다의 기하 스냅샷 — 진동은 이 값들(특히 zoom/offset/contentSize)이 한 입력 안에서
            // 흔들릴 때 발생한다고 의심. host.bounds/zoomScale이 스크롤 직후 transient면 여기서 드러난다.
            if let h = host {
                appLogDebug("canvas", "geom", [
                    "zoom": String(format: "%.4f", h.zoomScale),
                    "offsetY": "\(Int(h.contentOffset.y))",
                    "insetTop": "\(Int(h.contentInset.top))",
                    "contentH": "\(Int(h.contentSize.height))",
                    "boundsH": "\(Int(h.bounds.height))",
                    "cvBoundsH": "\(Int(contentView?.bounds.height ?? 0))",
                    "drawBottom": "\(Int(drawingBottom))",
                    "targetH": "\(Int(drawingBottom + viewportInContent * 2))",
                ])
            }
            ensureContentHeight(drawingBottom + viewportInContent * 2, fallbackCanvas: canvasView)

            updateNextPositionIndicator(on: canvasView)

            onStrokeChanged?()

            saveTimer?.invalidate()
            saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.onDrawingChanged()
            }
        }
    }
}
