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
    @State private var chatFeedback: FeedbackRecord?

    private let db = DatabaseService.shared

    /// 한 페이지의 읽기 전용 스냅샷 — 드로잉 blob + 그 페이지에 묶인 피드백 카드.
    struct ReaderPage: Identifiable {
        let id: String
        let drawingData: Data?
        let feedbacks: [FeedbackRecord]
    }

    private var currentPage: ReaderPage? {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : nil
    }

    var body: some View {
        Group {
            if let page = currentPage {
                ReadOnlyNoteCanvas(
                    drawingData: page.drawingData,
                    feedbacks: page.feedbacks,
                    onChat: { chatFeedback = $0 }
                )
                // 페이지 전환 시 캔버스 리마운트 — 드로잉/카드를 새로 로드(편집 NoteView의 .id 패턴과 동일).
                .id(page.id)
                .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView(
                    "내용이 없어요",
                    systemImage: "note.text",
                    description: Text("이 노트에는 아직 필기가 없어요.")
                )
            }
        }
        .navigationTitle(note?.title ?? "노트")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if pages.count > 1 {
                pageBar
            }
        }
        .sheet(item: $chatFeedback) { fb in
            // 카드 "대화" → 세션 채팅(§4.5 E-3). 채팅은 읽기 전용 앱에서도 허용되는 학습 행위(§4.3).
            FeedbackChatSheet(
                feedback: fb,
                textbookId: note?.textbookId,
                currentPage: note?.lastPage,
                noteId: note?.id,
                subject: note?.language
            )
        }
        .onAppear { load() }
    }

    private var pageBar: some View {
        HStack(spacing: 24) {
            Button {
                if pageIndex > 0 { pageIndex -= 1 }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(pageIndex == 0)

            Text("\(pageIndex + 1) / \(pages.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                if pageIndex < pages.count - 1 { pageIndex += 1 }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(pageIndex >= pages.count - 1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 6)
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
}

// MARK: - 읽기 전용 캔버스 (좌표 정합 보장)

/// host(UIScrollView) > contentView(논리폭 종이) > PKCanvasView(읽기 전용) 구조를 편집 캔버스와
/// 동일하게 구성한다(§4.5·§6.3). 입력만 차단(`isUserInteractionEnabled=false`)하고, 줌/세로 스크롤은
/// host가 담당한다. 카드는 `fb.positionY` 콘텐츠 좌표에 그대로 얹혀 위치 정합이 유지된다.
struct ReadOnlyNoteCanvas: UIViewRepresentable {
    let drawingData: Data?
    let feedbacks: [FeedbackRecord]
    let onChat: (FeedbackRecord) -> Void
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

        // 종이(줌 대상)
        let contentView = UIView()
        contentView.backgroundColor = isDark ? .black : .white
        contentView.frame = CGRect(x: 0, y: 0, width: logical, height: logical * 2)
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
        if let data = drawingData, let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }
        contentView.addSubview(canvas)

        coordinator.host = host
        coordinator.contentView = contentView
        coordinator.canvas = canvas
        coordinator.isDark = isDark
        coordinator.onChat = onChat
        coordinator.renderCards(feedbacks)

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
        private var lastWidth: CGFloat = 0
        private var maxCardBottom: CGFloat = 0

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

        /// zoom-to-fit + 가운데 정렬 + 콘텐츠 높이 보장. 편집 캔버스 `fitAndCenter`와 동일 식.
        func layout() {
            guard let host, let contentView else { return }
            let width = host.bounds.width
            guard width > 0 else { return }
            let logical = Config.logicalCanvasWidth
            let fit = min(1, width / logical)
            host.minimumZoomScale = fit
            host.maximumZoomScale = max(fit, 3.0)
            if abs(width - lastWidth) > 0.5 {
                lastWidth = width
                host.zoomScale = fit
            }
            // 콘텐츠 높이 = max(드로잉 끝, 마지막 카드 끝, 뷰포트) + 여유
            let s = max(host.zoomScale, 0.01)
            let drawingMaxY = (canvas?.drawing.bounds.maxY ?? 0)
            let viewportH = host.bounds.height / s
            let needed = max(drawingMaxY, maxCardBottom, viewportH) + 80
            if abs(contentView.bounds.height - needed) > 1 {
                contentView.bounds = CGRect(x: 0, y: 0, width: logical, height: needed)
                contentView.frame.origin = .zero
                canvas?.frame = contentView.bounds
            }
            host.contentSize = CGSize(width: logical * s, height: needed * s)
            center()
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
            let cardWidth = Config.logicalCanvasWidth - 32

            for fb in feedbacks {
                let card = makeCard(fb: fb, cardWidth: cardWidth)
                contentView.addSubview(card)
                maxCardBottom = max(maxCardBottom, card.frame.maxY)
            }
        }

        private func makeCard(fb: FeedbackRecord, cardWidth: CGFloat) -> UIView {
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
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.label,
                ], range: NSRange(location: 0, length: m.length))
                textView.attributedText = m
            } else {
                textView.text = rawText
                textView.font = .systemFont(ofSize: 14)
                textView.textColor = .label
            }

            let label: UIView = useKaTeX ? BakedMarkdownUIView(content: rawText, fontSize: 14) : textView

            // 버튼바 — "대화"만(읽기 전용)
            let chatBtn = UIButton(type: .system)
            chatBtn.setImage(UIImage(systemName: "bubble.left.fill"), for: .normal)
            chatBtn.setTitle(" " + String(localized: "대화"), for: .normal)
            chatBtn.titleLabel?.font = .systemFont(ofSize: 12)
            chatBtn.tintColor = .secondaryLabel
            let gesture = FeedbackTapGesture(target: self, action: #selector(chatTapped(_:)))
            gesture.feedbackRecord = fb
            chatBtn.addGestureRecognizer(gesture)

            let buttonBar = UIStackView(arrangedSubviews: [chatBtn, UIView()])
            buttonBar.axis = .horizontal
            buttonBar.alignment = .center

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
