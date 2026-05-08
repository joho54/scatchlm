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
    @State private var lastFeedbackStrokeCount: Int = 0
    @State private var chatFeedback: FeedbackRecord?
    // Page system
    @State private var notePages: [NotePage] = []
    @State private var currentPageIndex: Int = 0
    @State private var currentNotePage: NotePage?

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

                    // Back button — glass style
                    VStack {
                        HStack {
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
                            .padding(.leading, 12)
                            .padding(.top, 12)
                            Spacer()
                        }
                        Spacer()
                    }

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
                } else {
                    ProgressView()
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: .bottom)
        .sheet(item: $chatFeedback) { fb in
            FeedbackChatSheet(feedback: fb, textbookId: note?.textbookId, currentPage: currentPage)
        }
        .task { await loadNote() }
        .onDisappear { saveDrawing() }
    }

    // MARK: - Canvas Panel

    @ViewBuilder
    private func canvasPanel(note: Note) -> some View {
        PencilKitCanvasView(
            canvasView: $canvasView,
            onDrawingChanged: saveDrawing,
            initialDrawingData: currentNotePage?.drawingData ?? note.drawingData,
            feedbacks: feedbacks,
            onFeedbackTapped: { fb in
                chatFeedback = fb
            }
        )
        .clipped()
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
                }
            )
        }
    }

    // MARK: - FAB Pill

    @ViewBuilder
    private func fabPill(note: Note) -> some View {
        VStack(spacing: 8) {
            // Page navigation
            if notePages.count > 1 {
                HStack(spacing: 4) {
                    Button { goToPage(index: currentPageIndex - 1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .disabled(currentPageIndex <= 0)

                    Text("\(currentPageIndex + 1)/\(notePages.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button { goToPage(index: currentPageIndex + 1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .disabled(currentPageIndex >= notePages.count - 1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }

            // Main FAB
            HStack(spacing: 2) {
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

                // New page
                Button { newPage() } label: {
                    Image(systemName: "plus.rectangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
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

    private func loadPage(index: Int) {
        guard index >= 0, index < notePages.count else { return }
        let page = notePages[index]
        currentNotePage = page
        currentPageIndex = index
        lastFeedbackStrokeCount = 0

        // Load feedbacks for this page
        if let pageId = page.id as String? {
            feedbacks = (try? db.feedbacks(pageId: pageId)) ?? []
        }

        appLog("note", "loadPage", ["index": "\(index)", "feedbacks": "\(feedbacks.count)"])
    }

    private func saveDrawing() {
        guard !canvasView.drawing.strokes.isEmpty, let page = currentNotePage else { return }
        let data = canvasView.drawing.dataRepresentation()
        try? db.savePageDrawing(pageId: page.id, data: data)
    }

    private func newPage() {
        // Save current page
        saveDrawing()

        // Create new page
        let newIndex = notePages.count
        guard let page = try? db.createPage(noteId: noteId, pageIndex: newIndex) else { return }
        notePages.append(page)
        currentPageIndex = newIndex
        try? db.updateCurrentPageIndex(noteId: noteId, index: newIndex)

        // Clear canvas
        canvasView.drawing = PKDrawing()
        loadPage(index: newIndex)

        appLog("note", "newPage", ["index": "\(newIndex)"])
    }

    private func goToPage(index: Int) {
        guard index >= 0, index < notePages.count, index != currentPageIndex else { return }
        // Save current
        saveDrawing()
        try? db.updateCurrentPageIndex(noteId: noteId, index: index)

        // Load target page drawing
        let targetPage = notePages[index]
        if let drawingData = targetPage.drawingData, let drawing = try? PKDrawing(data: drawingData) {
            canvasView.drawing = drawing
        } else {
            canvasView.drawing = PKDrawing()
        }

        loadPage(index: index)
    }

    private func requestFeedback() {
        guard !loading else { return }
        loading = true

        Task {
            do {
                let allStrokes = canvasView.drawing.strokes
                let newStrokes = Array(allStrokes.dropFirst(lastFeedbackStrokeCount))
                guard !newStrokes.isEmpty else {
                    appLog("note", "feedback: no new strokes", ["total": "\(allStrokes.count)", "lastFeedback": "\(lastFeedbackStrokeCount)"])
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
                // 최대 4000px로 리사이즈
                let maxDim: CGFloat = 4000
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
                guard let pngData = finalImage.pngData() else {
                    appLog("note", "feedback: pngData nil")
                    loading = false
                    return
                }

                appLog("note", "feedback: capture", [
                    "newStrokes": "\(newStrokes.count)",
                    "bounds": "\(bounds)",
                    "pngBytes": "\(pngData.count)",
                    "imageSize": "\(finalImage.size)",
                ])

                var fields: [String: String] = [
                    "note_id": noteId,
                    "language": note?.language ?? "en",
                    "response_language": Config.responseLanguage,
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
                    fileName: "canvas.png",
                    mimeType: "image/png"
                )

                let y = bounds.maxY + 24
                let width = canvasView.bounds.width - 32
                let jsonData = try JSONEncoder().encode(response)

                var record = FeedbackRecord(
                    id: UUID().uuidString,
                    noteId: noteId,
                    pageId: currentNotePage?.id,
                    content: String(data: jsonData, encoding: .utf8) ?? "{}",
                    positionX: 16,
                    positionY: y,
                    bboxX: 16,
                    bboxY: y,
                    bboxWidth: width,
                    bboxHeight: 400,
                    createdAt: Date()
                )
                try db.saveFeedback(&record)
                feedbacks.append(record)

                // Mark feedback point
                lastFeedbackStrokeCount = allStrokes.count

                // Extend canvas if needed
                let requiredHeight = y + 400
                if requiredHeight > canvasView.contentSize.height {
                    canvasView.contentSize.height = requiredHeight
                }

                appLog("note", "feedback received", ["content": String((response.content ?? response.displayText).prefix(80))])
            } catch {
                appLogError("note", "feedback failed", ["error": "\(error)"])
            }
            loading = false
        }
    }
}

// MARK: - PencilKit UIViewRepresentable

struct PencilKitCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var onDrawingChanged: () -> Void
    var initialDrawingData: Data?
    var feedbacks: [FeedbackRecord]
    var onFeedbackTapped: ((FeedbackRecord) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> PKCanvasView {
        let isDark = colorScheme == .dark
        canvasView.drawingPolicy = .pencilOnly
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

        // Render feedback cards as subviews
        let existingCards = uiView.subviews.filter { $0.tag == 9999 }.count
        appLog("canvas", "updateUIView", ["feedbacks": "\(feedbacks.count)", "existingCards": "\(existingCards)", "bounds": "\(uiView.bounds)"])
        uiView.subviews.filter { $0.tag == 9999 }.forEach { $0.removeFromSuperview() }

        let cardWidth = uiView.bounds.width - 32
        for fb in feedbacks {
            let parsed = try? JSONDecoder().decode(AIResponse.self, from: fb.content.data(using: .utf8) ?? Data())

            let card = UIView()
            card.tag = 9999
            card.backgroundColor = UIColor.systemBackground
            card.layer.cornerRadius = 12
            card.layer.shadowColor = UIColor.black.cgColor
            card.layer.shadowOpacity = 0.1
            card.layer.shadowRadius = 4
            card.layer.shadowOffset = CGSize(width: 0, height: 2)
            card.isUserInteractionEnabled = true

            let tapGesture = FeedbackTapGesture(target: context.coordinator, action: #selector(Coordinator.feedbackCardTapped(_:)))
            tapGesture.feedbackRecord = fb
            card.addGestureRecognizer(tapGesture)

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

            card.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            ])

            let labelSize = label.sizeThatFits(CGSize(width: cardWidth - 24, height: .greatestFiniteMagnitude))
            let cardHeight = labelSize.height + 24

            card.frame = CGRect(x: 16, y: fb.positionY, width: cardWidth, height: cardHeight)
            uiView.addSubview(card)
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(onDrawingChanged: onDrawingChanged)
        c.onFeedbackTapped = onFeedbackTapped
        return c
    }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        let onDrawingChanged: () -> Void
        var onFeedbackTapped: ((FeedbackRecord) -> Void)?
        var toolPicker: PKToolPicker?
        private var saveTimer: Timer?

        init(onDrawingChanged: @escaping () -> Void) {
            self.onDrawingChanged = onDrawingChanged
        }

        @objc func feedbackCardTapped(_ gesture: FeedbackTapGesture) {
            if let fb = gesture.feedbackRecord {
                onFeedbackTapped?(fb)
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Prevent upward expansion — clamp contentOffset to >= 0
            if canvasView.contentOffset.y < 0 {
                canvasView.contentOffset.y = 0
            }

            // Auto-expand content size (downward only)
            let drawingBottom = canvasView.drawing.strokes.isEmpty
                ? canvasView.bounds.height
                : canvasView.drawing.strokes.reduce(CGFloat(0)) { max($0, $1.renderBounds.maxY) }
            let requiredHeight = drawingBottom + canvasView.bounds.height * 2
            if requiredHeight > canvasView.contentSize.height {
                canvasView.contentSize.height = requiredHeight
            }

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
