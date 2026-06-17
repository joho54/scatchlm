import SwiftUI
import PencilKit

/// iPhone 읽기 전용 노트 뷰어 (iphone-companion-app-spec §4.5·Track E).
///
/// 편집용 `NoteView`를 직접 재사용하지 않는다(§R3: frozen/툴바/paste/좌표 로직이 compact에서
/// 회귀 위험). 대신 **카드 좌표 정합을 보장**하기 위해 편집 캔버스와 동일한 좌표계
/// (논리폭 `Config.logicalCanvasWidth` + zoom-to-fit + 카드를 `fb.positionY` 콘텐츠 좌표에 배치)를
/// 쓰는 경량 읽기 전용 캔버스(`ReadOnlyNoteCanvas`)를 신설한다. 입력은 차단(필기·편집 불가),
/// 피드백 카드는 "대화"만 노출한다.
struct PhoneNoteReaderView: View {
    let noteId: String

    @State private var note: Note?
    @State private var pages: [ReaderPage] = []
    @State private var pageIndex: Int = 0
    @State private var chatContext: ChatSheetContext?
    @State private var showDrawer = false
    @State private var showPages = false
    @State private var showTextbook = false
    /// 페이지별 읽기 전용 캔버스 Coordinator 레지스트리(점프용). @State라 재렌더에도 동일 인스턴스 유지.
    @State private var canvasRegistry = ReaderCanvasRegistry()

    private let db = DatabaseService.shared

    /// 한 페이지의 읽기 전용 스냅샷 — 드로잉 blob + 그 페이지에 묶인 피드백 카드.
    struct ReaderPage: Identifiable {
        let id: String
        let drawingData: Data?
        let feedbacks: [FeedbackRecord]
    }

    var body: some View {
        Group {
            if pages.isEmpty {
                ContentUnavailableView(
                    "내용이 없어요",
                    systemImage: "note.text",
                    description: Text("이 노트에는 아직 필기가 없어요.")
                )
            } else {
                // 좌우 손가락 스와이프로 페이지 전환(§4.5 TabView .page). 인디케이터 점은 끈다.
                // 각 페이지는 독립 ReadOnlyNoteCanvas — 네비게이터/스와이프 모두 pageIndex로 동기화.
                TabView(selection: $pageIndex) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { idx, page in
                        ReadOnlyNoteCanvas(
                            pageId: page.id,
                            drawingData: page.drawingData,
                            feedbacks: page.feedbacks,
                            onChat: { openChat(for: $0) },
                            registry: canvasRegistry
                        )
                        .ignoresSafeArea(edges: .bottom)
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle(note?.title ?? "노트")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 페이지 네비게이터(슬라이드 오버) — 썸네일로 한 번에 점프(#1).
            if pages.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showPages = true
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                }
            }
            // 교재 진입(노트 종속). 연결 교재가 있을 때만 노출 → 읽기 전용 PDF를 full-screen push.
            // noteId를 넘겨 그 노트의 PDF 필기(pdfAnnotation, noteId+page 키)를 함께 렌더한다.
            if note?.textbookId != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTextbook = true
                    } label: {
                        Image(systemName: "book")
                    }
                }
            }
            // 챗 서랍 진입(§4.3·C-1, §6.x-3 결정: 노트 내부 버튼). 노트의 저장된 세션을
            // 챕터별로 열람하고 대화를 이어간다. 점프/스크랩은 iPhone에서 비노출(드로어 C-1).
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDrawer = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
            }
        }
        .navigationDestination(isPresented: $showTextbook) {
            if let note, let tbId = note.textbookId {
                // 읽기 전용 PDF(§4.4). inkMode 기본 false → PdfInkInputView 미부착으로 입력 차단.
                // 표시 overlay는 noteId로 노트별 필기를 렌더한다(PdfViewerView.swift:1085).
                PdfViewerView(
                    textbookId: tbId,
                    totalPages: note.textbookPages,
                    initialPage: note.lastPage,
                    onPageChanged: { _ in },   // 읽기 전용 — 교재 페이지 영속 안 함
                    onClose: { showTextbook = false },
                    noteId: noteId,
                    readOnly: true             // 필기 표시는 하되 편집(필기 버튼)은 가림
                )
                .navigationTitle(note.textbookName ?? "교재")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showPages) {
            PhonePageNavigator(pages: pages, currentIndex: pageIndex) { idx in
                pageIndex = idx
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDrawer) {
            ChapterDrawerView(
                noteId: noteId,
                textbookId: note?.textbookId,
                subject: note?.language,
                onJump: { fb in
                    showDrawer = false
                    jumpToCard(fb)
                }
            )
        }
        .sheet(item: $chatContext) { ctx in
            // 카드 "대화" → 세션 채팅(§4.5 E-3). 채팅은 읽기 전용 앱에서도 허용되는 학습 행위(§4.3).
            SessionChatSheet(
                session: ctx.session,
                headerContent: ctx.headerContent,
                headerServerId: ctx.headerServerId,
                textbookId: ctx.session.textbookId ?? note?.textbookId,
                currentPage: ctx.session.anchorPage ?? note?.lastPage,
                noteId: note?.id,
                subject: note?.language
            )
        }
        .onAppear { load() }
    }


    private func load() {
        do {
            note = try db.note(id: noteId)
            let notePages = try db.pages(noteId: noteId)
            if notePages.isEmpty {
                // 레거시 노트(페이지 행 없음) — note.drawingData를 단일 페이지로 표시.
                // 읽기 전용이므로 NotePage 행을 생성(쓰기)하지 않는다(§R4 읽기 전용 누수 방지).
                let legacy = try? db.feedbacks(noteId: noteId)
                pages = [ReaderPage(
                    id: "legacy-\(noteId)",
                    drawingData: note?.drawingData,
                    feedbacks: (legacy ?? []).filter { $0.pageId == nil }
                )]
            } else {
                pages = notePages.map { p in
                    ReaderPage(
                        id: p.id,
                        drawingData: p.drawingData,
                        feedbacks: (try? db.feedbacks(pageId: p.id)) ?? []
                    )
                }
            }
            pageIndex = min(note?.currentPageIndex ?? 0, max(0, pages.count - 1))
            appLog("phoneReader", "loaded", [
                "id": noteId,
                "pages": "\(pages.count)",
                "feedbacks": "\(pages.reduce(0) { $0 + $1.feedbacks.count })",
            ])
        } catch {
            appLogError("phoneReader", "load failed", ["error": "\(error)"])
        }
    }

    /// 드로어 "점프" → 카드가 있는 페이지로 전환 후 해당 페이지 캔버스를 fb.positionY로 스크롤.
    /// iPad의 jumpToPlacement/scrollCardIntoView와 동일한 방식(콘텐츠 좌표 setContentOffset).
    /// TabView는 페이지마다 독립 캔버스라 레지스트리로 대상 페이지 Coordinator를 찾아 호출한다.
    private func jumpToCard(_ fb: FeedbackRecord) {
        let targetIdx = pages.firstIndex { page in
            if let pid = fb.pageId { return page.id == pid }
            // 레거시(pageId 없는 단독 카드)는 카드 id 소속으로 페이지를 찾는다.
            return page.feedbacks.contains { $0.id == fb.id }
        }
        guard let idx = targetIdx else {
            appLogError("phoneReader", "jump: page not found", ["fb": fb.id])
            return
        }
        let pageId = pages[idx].id
        if idx != pageIndex {
            withAnimation { pageIndex = idx }
        }
        // 페이지 전환 애니메이션 대기 후 스크롤 요청. 대상 캔버스의 레이아웃이 아직이면
        // Coordinator가 pending으로 보관했다가 layout 완료 시 소비한다(타이밍 견고화).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            canvasRegistry.coordinator(for: pageId)?.scrollCardIntoView(positionY: fb.positionY)
        }
        appLog("phoneReader", "jump", ["fb": fb.id, "page": "\(idx)", "y": "\(Int(fb.positionY))"])
    }

    /// 카드 "대화" → 세션 채팅 열기(§4.3·§4.5 E-3). 카드에 세션이 있으면 그대로 열고,
    /// 레거시 단독 카드는 세션을 만들어 역연결한다 — 세션/메시지 생성은 읽기 전용 앱에서도
    /// 허용되는 학습 행위(§4.3). NoteView.openChat(for:)와 동일 로직.
    private func openChat(for fb: FeedbackRecord) {
        let session: ChatSessionRecord?
        if let sid = fb.sessionId, let existing = try? db.session(id: sid) {
            session = existing
        } else {
            guard let created = createFeedbackSession(content: fb.content, serverFeedbackId: fb.serverFeedbackId) else { return }
            var card = fb
            card.sessionId = created.id
            do {
                try db.saveFeedback(&card)
                // 메모리상 페이지 캐시에도 역연결 반영(같은 카드 재탭 시 세션 재생성 방지).
                if let pi = pages.firstIndex(where: { $0.feedbacks.contains(where: { $0.id == fb.id }) }) {
                    var fbs = pages[pi].feedbacks
                    if let fi = fbs.firstIndex(where: { $0.id == fb.id }) {
                        fbs[fi] = card
                        pages[pi] = ReaderPage(id: pages[pi].id, drawingData: pages[pi].drawingData, feedbacks: fbs)
                    }
                }
            } catch {
                appLogError("phoneReader", "link card→session failed", ["error": "\(error)"])
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

    /// 카드 placement용 kind=feedback 세션 생성. 교재 연결 시 anchorPage=노트 마지막 페이지.
    private func createFeedbackSession(content: String, serverFeedbackId: String?) -> ChatSessionRecord? {
        var text = content
        if let data = content.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(AIResponse.self, from: data) {
            text = parsed.displayText
        }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = oneLine.isEmpty ? String(localized: "피드백 대화") : String(oneLine.prefix(40))

        var session = ChatSessionRecord(
            kind: ChatSessionRecord.Kind.feedback.rawValue,
            title: title,
            noteId: noteId,
            textbookId: note?.textbookId,
            anchorPage: note?.textbookId != nil ? note?.lastPage : nil,
            sourceFeedbackId: serverFeedbackId
        )
        do {
            try db.saveSession(&session)
            return session
        } catch {
            appLogError("phoneReader", "createFeedbackSession failed", ["error": "\(error)"])
            return nil
        }
    }
}

// MARK: - 페이지 네비게이터 (읽기 전용 슬라이드 오버, #1)

/// 페이지 썸네일 그리드. 탭 한 번으로 해당 페이지로 점프(편집용 PageNavigatorView의
/// 추가/삭제/순서변경/템플릿은 제외 — 읽기 전용).
private struct PhonePageNavigator: View {
    let pages: [PhoneNoteReaderView.ReaderPage]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { idx, page in
                        Button {
                            onSelect(idx)
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                PhonePageThumbnail(drawingData: page.drawingData)
                                    .frame(height: 150)
                                    .frame(maxWidth: .infinity)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(idx == currentIndex ? Color.blue : Color.clear, lineWidth: 2)
                                    )
                                Text("\(idx + 1)페이지")
                                    .font(.caption)
                                    .foregroundStyle(idx == currentIndex ? .blue : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("페이지")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

/// 페이지 드로잉 썸네일 (NoteCardView/PageThumbnail과 동일 렌더 패턴).
private struct PhonePageThumbnail: View {
    let drawingData: Data?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color(white: 0.12) : Color.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { await render() }
    }

    private func render() async {
        let data = drawingData
        let img: UIImage? = await Task.detached(priority: .utility) {
            guard let data,
                  let drawing = try? PKDrawing(data: data),
                  !drawing.strokes.isEmpty else { return nil }
            let sourceWidth: CGFloat = 800
            let aspect: CGFloat = 150.0 / 110.0
            let rect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceWidth * aspect)
            let scale = 240.0 / sourceWidth
            return drawing.image(from: rect, scale: scale)
        }.value
        await MainActor.run { self.image = img }
    }
}

// MARK: - 점프용 캔버스 레지스트리

/// 페이지 id → 해당 페이지 `ReadOnlyNoteCanvas.Coordinator`(weak) 매핑. 드로어 점프 시
/// 부모가 대상 페이지 Coordinator를 찾아 `scrollCardIntoView`를 호출하는 데 쓴다.
/// TabView가 페이지마다 독립 캔버스를 만들기 때문에 단일 delegate 핸들로는 도달 불가 → 레지스트리.
final class ReaderCanvasRegistry {
    private let table = NSMapTable<NSString, ReadOnlyNoteCanvas.Coordinator>(
        keyOptions: .copyIn, valueOptions: .weakMemory
    )
    func register(_ pageId: String, _ coordinator: ReadOnlyNoteCanvas.Coordinator) {
        table.setObject(coordinator, forKey: pageId as NSString)
    }
    func coordinator(for pageId: String) -> ReadOnlyNoteCanvas.Coordinator? {
        table.object(forKey: pageId as NSString)
    }
}

// MARK: - 읽기 전용 캔버스 (좌표 정합 보장)

/// host(UIScrollView) > contentView(논리폭 종이) > PKCanvasView(읽기 전용) 구조를 편집 캔버스와
/// 동일하게 구성한다(§4.5·§6.3). 입력만 차단(`isUserInteractionEnabled=false`)하고, 줌/세로 스크롤은
/// host가 담당한다. 카드는 `fb.positionY` 콘텐츠 좌표에 그대로 얹혀 위치 정합이 유지된다.
struct ReadOnlyNoteCanvas: UIViewRepresentable {
    let pageId: String
    let drawingData: Data?
    let feedbacks: [FeedbackRecord]
    let onChat: (FeedbackRecord) -> Void
    /// 점프용 — 부모(PhoneNoteReaderView)가 페이지 id로 이 캔버스 Coordinator를 찾기 위한 레지스트리.
    var registry: ReaderCanvasRegistry?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> UIScrollView {
        let coordinator = context.coordinator
        let isDark = colorScheme == .dark
        let logical = Config.logicalCanvasWidth

        let host = ReadOnlyHostScrollView()
        host.onLayout = { [weak coordinator] in coordinator?.layout() }
        host.delegate = coordinator
        host.backgroundColor = .clear
        host.contentInsetAdjustmentBehavior = .never
        host.showsHorizontalScrollIndicator = false
        host.alwaysBounceVertical = true

        // 드로잉을 먼저 파싱해 "종이 폭"을 정한다(#2). iPad에서 그린 필기는 iPad 논리폭(예 ~820)
        // 좌표를 가지므로, iPhone 논리폭(~390)짜리 종이에 fit=1로 두면 필기가 화면을 넘친다.
        // 종이를 필기 실제 폭까지 넓힌 뒤 zoom-to-fit으로 화면에 맞춰 축소 → 카드도 같은 폭에서
        // 렌더돼 좌표 정합 유지(카드는 화면상 거의 iPhone 폭으로 보임).
        let parsedDrawing: PKDrawing? = drawingData.flatMap { try? PKDrawing(data: $0) }
        var paperWidth = logical
        if let b = parsedDrawing?.bounds, !b.isNull, b.maxX.isFinite {
            paperWidth = max(logical, ceil(b.maxX) + 8)
        }
        coordinator.contentWidth = paperWidth

        // 종이(줌 대상)
        let contentView = UIView()
        contentView.backgroundColor = isDark ? .black : .white
        contentView.frame = CGRect(x: 0, y: 0, width: paperWidth, height: paperWidth * 2)
        host.addSubview(contentView)
        host.contentSize = contentView.bounds.size

        // 읽기 전용 PencilKit — 입력 차단(필기/지우개/툴피커 없음).
        let canvas = PKCanvasView()
        canvas.isUserInteractionEnabled = false          // §4.3·R4: 입력 OFF
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false                   // 스크롤/줌은 host
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.frame = contentView.bounds
        if let drawing = parsedDrawing { canvas.drawing = drawing }
        contentView.addSubview(canvas)

        coordinator.host = host
        coordinator.contentView = contentView
        coordinator.canvas = canvas
        coordinator.isDark = isDark
        coordinator.onChat = onChat
        coordinator.renderCards(feedbacks)

        // 점프용 — 이 페이지의 Coordinator를 레지스트리에 등록(weak 보관).
        registry?.register(pageId, coordinator)

        return host
    }

    func updateUIView(_ host: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isDark = colorScheme == .dark
        coordinator.onChat = onChat
        coordinator.contentView?.backgroundColor = coordinator.isDark ? .black : .white
        coordinator.layout()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var host: UIScrollView?
        weak var contentView: UIView?
        weak var canvas: PKCanvasView?
        var isDark = false
        var onChat: ((FeedbackRecord) -> Void)?
        /// 종이(콘텐츠) 폭 — 필기 실제 폭까지 확장된 값(#2). fit/카드 폭의 SSOT.
        var contentWidth: CGFloat = Config.logicalCanvasWidth
        private var lastWidth: CGFloat = 0
        private var maxCardBottom: CGFloat = 0
        /// 레이아웃 완료 전에 도착한 점프 요청을 보관했다가 layout()에서 소비한다.
        private var pendingScrollY: CGFloat?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

        /// 드로어 점프 진입점. 카드의 콘텐츠 좌표(positionY)로 host를 스크롤.
        /// host가 아직 레이아웃 전(bounds 0)이면 pending으로 보관 → layout 완료 시 flush.
        func scrollCardIntoView(positionY: CGFloat) {
            pendingScrollY = positionY
            flushPendingScroll()
        }

        /// 편집 캔버스 NoteView.scrollCardIntoView와 동일 식 — 카드 상단을 화면 1/3 지점에 배치.
        private func flushPendingScroll() {
            guard let host, let y = pendingScrollY else { return }
            let vh = host.bounds.height
            guard vh > 0 else { return }   // 레이아웃 전 — pending 유지
            let s = host.zoomScale
            let targetY = max(-host.contentInset.top, y * s - vh / 3)
            let maxY = max(-host.contentInset.top, host.contentSize.height - vh)
            let clamped = min(targetY, maxY)
            host.setContentOffset(CGPoint(x: -host.contentInset.left, y: clamped), animated: true)
            pendingScrollY = nil
            appLog("phoneReader", "scroll card", ["targetY": "\(Int(clamped))", "cardY": "\(Int(y))", "zoom": "\(s)"])
        }

        /// zoom-to-fit + 가운데 정렬 + 콘텐츠 높이 보장. 편집 캔버스 `fitAndCenter`와 동일 식.
        func layout() {
            guard let host, let contentView else { return }
            let width = host.bounds.width
            guard width > 0 else { return }
            let logical = contentWidth   // 필기 폭까지 확장된 종이 폭(#2)
            let fit = min(1, width / logical)
            host.minimumZoomScale = fit
            host.maximumZoomScale = max(fit, 3.0)
            if abs(width - lastWidth) > 0.5 {
                lastWidth = width
                host.zoomScale = fit
            }
            // 콘텐츠 높이 = max(드로잉 끝, 마지막 카드 끝, 뷰포트) + 여유.
            // 빈 페이지의 PKDrawing().bounds는 CGRect.null → maxY가 무한대다. 그대로 쓰면
            // contentSize가 Inf가 돼 스크롤 인디케이터 레이아웃에서 SIGABRT(즉시 크래시).
            // null/비유한 값은 0으로 무력화한다.
            let s = max(host.zoomScale, 0.01)
            let dBounds = canvas?.drawing.bounds ?? .zero
            let drawingMaxY = (dBounds.isNull || !dBounds.maxY.isFinite) ? 0 : dBounds.maxY
            let viewportH = host.bounds.height / s
            var needed = max(drawingMaxY, maxCardBottom, viewportH) + 80
            if !needed.isFinite { needed = viewportH + 80 }
            if abs(contentView.bounds.height - needed) > 1 {
                contentView.bounds = CGRect(x: 0, y: 0, width: logical, height: needed)
                contentView.frame.origin = .zero
                canvas?.frame = contentView.bounds
            }
            host.contentSize = CGSize(width: logical * s, height: needed * s)
            center()
            // 레이아웃 전 도착한 점프 요청이 있으면 이제 소비(페이지 전환 직후 경로).
            flushPendingScroll()
        }

        /// 콘텐츠가 뷰포트보다 좁으면 가로 가운데 정렬(레터박스).
        private func center() {
            guard let host, let contentView else { return }
            let scaledW = contentView.bounds.width * host.zoomScale
            let insetX = max(0, (host.bounds.width - scaledW) / 2)
            let inset = UIEdgeInsets(top: 0, left: insetX, bottom: 0, right: insetX)
            if host.contentInset != inset { host.contentInset = inset }
        }

        /// 피드백 카드를 콘텐츠 좌표(`fb.positionY`)에 렌더. NoteView.renderCard의 읽기 부분만 차용 —
        /// 버튼바는 "대화" 단일(§4.5: 되돌리기·스크랩 숨김).
        func renderCards(_ feedbacks: [FeedbackRecord]) {
            guard let contentView else { return }
            contentView.subviews.filter { $0.tag == 9999 }.forEach { $0.removeFromSuperview() }
            maxCardBottom = 0
            // 종이는 화면에 맞춰 fit(≈logical/contentWidth)으로 축소된다. 카드 텍스트가 그만큼 작아져
            // 읽기 힘드므로, 카드를 그 역수 k배로 키워(content 좌표) 화면상 원래 크기로 보이게 한다.
            // (필기는 좌표 그대로 축소, 카드만 counter-scale — 사용자 요청.)
            let k = max(1, contentWidth / Config.logicalCanvasWidth)
            // 카드 counter-scale(k)이 후속 필기를 덮는지 진단하기 위해 stroke 경계를 미리 수집.
            // (콘텐츠 좌표 = iPad 논리 좌표 그대로. 카드만 k배 확대돼 세로로 더 내려간다.)
            let strokeBounds = canvas?.drawing.strokes.map { $0.renderBounds } ?? []
            let drawingMaxY = strokeBounds.reduce(CGFloat(0)) { max($0, $1.maxY) }
            appLogDebug("cardGeom", "renderCards begin", [
                "cards": "\(feedbacks.count)",
                "k": String(format: "%.3f", k),
                "contentWidth": "\(Int(contentWidth))",
                "logicalWidth": "\(Int(Config.logicalCanvasWidth))",
                "strokes": "\(strokeBounds.count)",
                "drawingMaxY": "\(Int(drawingMaxY))",
            ])
            let margin: CGFloat = 12 * k
            var runningBottom: CGFloat = 0
            for (idx, fb) in feedbacks.enumerated() {
                // 1. 카드 상단 — 원 위치 우선, 직전 카드와 겹치면 아래로(카드-카드 분리).
                let y = max(fb.positionY, runningBottom + 12 * k)
                // 2. 이 카드 아래에서 시작하는 첫 stroke까지의 거리 = iPad에서 카드가 쓰던 공백.
                //    그 공백 이하로 카드를 capping하면 후속 필기 위로 흘러내리지 않는다(겹침 0).
                //    아래에 stroke가 없으면(마지막 영역) cap 없음 → 자연 높이.
                let nextStrokeTop = strokeBounds.compactMap { $0.minY > y + 1 ? $0.minY : nil }.min()
                let cap: CGFloat? = nextStrokeTop.map { $0 - y - margin }

                let card = makeCard(fb: fb, scale: k, maxHeight: cap)
                card.frame.origin.y = y
                let cardBottom = card.frame.maxY
                // 검증용: 카드 세로 구간에 걸치는 stroke = 잔여 겹침(목표 0).
                let overlapping = strokeBounds.filter { $0.maxY > y && $0.minY < cardBottom }
                appLogDebug("cardGeom", "card placed", [
                    "idx": "\(idx)",
                    "fbId": String(fb.id.prefix(8)),
                    "positionY": "\(Int(fb.positionY))",
                    "placedY": "\(Int(y))",
                    "bumped": "\(y > fb.positionY)",
                    "cap": cap.map { "\(Int($0))" } ?? "nil",
                    "nextStrokeTop": nextStrokeTop.map { "\(Int($0))" } ?? "nil",
                    "cardH": "\(Int(cardBottom - y))",
                    "cardBottom": "\(Int(cardBottom))",
                    "scrolls": "\((card.subviews.compactMap { $0 as? UIScrollView }.first?.isScrollEnabled) ?? false)",
                    "overlapStrokes": "\(overlapping.count)",
                ])
                runningBottom = cardBottom
                contentView.addSubview(card)
                maxCardBottom = max(maxCardBottom, cardBottom)
            }
        }

        /// maxHeight: 카드가 차지할 수 있는 콘텐츠 높이 상한(공백 기반). nil이면 자연 높이.
        /// 상한을 넘는 본문은 내부 스크롤로 본다 → 카드가 후속 필기 위로 흘러내리지 않음.
        private func makeCard(fb: FeedbackRecord, scale k: CGFloat, maxHeight: CGFloat?) -> UIView {
            let cardWidth = (Config.logicalCanvasWidth - 32) * k
            let fontSize = 14 * k
            let parsed = try? JSONDecoder().decode(AIResponse.self, from: fb.content.data(using: .utf8) ?? Data())
            let rawText = parsed?.displayText ?? fb.content
            let useKaTeX = MarkdownRender.shouldUseKaTeX(rawText)

            let card = UIView()
            card.tag = 9999
            card.accessibilityIdentifier = fb.id
            card.backgroundColor = .systemBackground
            card.layer.cornerRadius = 12
            card.layer.shadowColor = UIColor.black.cgColor
            card.layer.shadowOpacity = 0.1
            card.layer.shadowRadius = 4
            card.layer.shadowOffset = CGSize(width: 0, height: 2)

            // 측정/표시용 텍스트뷰(편집 NoteView와 동일 경로)
            let textView = UITextView()
            textView.isEditable = false
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            if let attr = try? NSAttributedString(
                markdown: rawText,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                let m = NSMutableAttributedString(attributedString: attr)
                m.addAttributes([
                    .font: UIFont.systemFont(ofSize: fontSize),
                    .foregroundColor: UIColor.label,
                ], range: NSRange(location: 0, length: m.length))
                textView.attributedText = m
            } else {
                textView.text = rawText
                textView.font = .systemFont(ofSize: fontSize)
                textView.textColor = .label
            }

            let label: UIView = useKaTeX ? BakedMarkdownUIView(content: rawText, fontSize: fontSize) : textView

            // 버튼바 — "대화"만(읽기 전용)
            let chatBtn = UIButton(type: .system)
            chatBtn.setImage(UIImage(systemName: "bubble.left.fill"), for: .normal)
            chatBtn.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 12 * k), forImageIn: .normal)
            chatBtn.setTitle(" " + String(localized: "대화"), for: .normal)
            chatBtn.titleLabel?.font = .systemFont(ofSize: 12 * k)
            chatBtn.tintColor = .secondaryLabel
            let gesture = FeedbackTapGesture(target: self, action: #selector(chatTapped(_:)))
            gesture.feedbackRecord = fb
            chatBtn.addGestureRecognizer(gesture)

            let buttonBar = UIStackView(arrangedSubviews: [chatBtn, UIView()])
            buttonBar.axis = .horizontal
            buttonBar.alignment = .center

            // 본문 자연 높이 측정(스크롤 콘텐츠 높이). KaTeX 경로도 textView 측정값으로 근사.
            let naturalLabelHeight = textView.sizeThatFits(
                CGSize(width: cardWidth - 24 * k, height: .greatestFiniteMagnitude)
            ).height

            // 본문을 내부 스크롤뷰에 담는다 → 카드 높이를 cap해도 넘치는 부분은 스크롤로 본다.
            let scroll = UIScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.showsVerticalScrollIndicator = true
            scroll.alwaysBounceVertical = false
            scroll.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(label)
            card.addSubview(scroll)
            card.addSubview(buttonBar)
            buttonBar.translatesAutoresizingMaskIntoConstraints = false

            // chrome = top inset + label↔button gap + button + bottom inset
            let chrome: CGFloat = (12 + 8 + 28 + 8) * k
            let minCardHeight: CGFloat = 120 * k   // 너무 작아 못 읽는 카드 방지(최소 가독 높이)
            let naturalCardHeight = naturalLabelHeight + chrome
            let finalCardHeight = maxHeight.map { max(minCardHeight, min(naturalCardHeight, $0)) } ?? naturalCardHeight
            // cap이 자연 높이보다 작을 때만 스크롤 활성(여유 0.5 마진).
            scroll.isScrollEnabled = finalCardHeight + 0.5 < naturalCardHeight

            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 12 * k),
                scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12 * k),
                scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12 * k),
                scroll.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -8 * k),

                buttonBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12 * k),
                buttonBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12 * k),
                buttonBar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8 * k),
                buttonBar.heightAnchor.constraint(equalToConstant: 28 * k),

                // label = 스크롤 콘텐츠. 폭은 뷰포트에 고정, 높이는 자연 높이(고정) → 넘치면 스크롤.
                label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                label.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                label.heightAnchor.constraint(equalToConstant: naturalLabelHeight),
            ])

            // x는 makeCard에서, y는 renderCards가 순차 배치로 설정.
            card.frame = CGRect(x: 16 * k, y: 0, width: cardWidth, height: finalCardHeight)
            return card
        }

        @objc private func chatTapped(_ gesture: FeedbackTapGesture) {
            if let fb = gesture.feedbackRecord { onChat?(fb) }
        }
    }
}

/// 레이아웃 완료 콜백을 노출하는 host scroll view (편집 캔버스 HostScrollView와 동일 역할).
private final class ReadOnlyHostScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
