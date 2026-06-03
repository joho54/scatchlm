import SwiftUI
import PDFKit

struct PdfViewerView: View {
    let textbookId: String
    let totalPages: Int
    let initialPage: Int
    let onPageChanged: (Int) -> Void
    let onClose: () -> Void
    var onPin: ((String, String?) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var currentPage: Int
    @State private var pdfView: PDFView?
    @State private var showToc = false
    @State private var showGuide = false
    @State private var showChapterGuide = false
    @State private var chapters: [ChapterItem] = []
    @State private var pageGuide: PageGuide?
    @State private var chapterGuide: ChapterGuide?
    @State private var guideLoading = false
    @State private var chapterGuideLoading = false
    @State private var pageGuideRating: Int? = nil
    @State private var chapterGuideRating: Int? = nil
    @State private var pageGuideRatingDetail = false
    @State private var chapterGuideRatingDetail = false

    init(textbookId: String, totalPages: Int, initialPage: Int, onPageChanged: @escaping (Int) -> Void, onClose: @escaping () -> Void, onPin: ((String, String?) -> Void)? = nil) {
        self.textbookId = textbookId
        self.totalPages = totalPages
        self.initialPage = initialPage
        self.onPageChanged = onPageChanged
        self.onClose = onClose
        self.onPin = onPin
        self._currentPage = State(initialValue: initialPage)
    }

    var body: some View {
        ZStack {
            // PDF content — full area, inverted in dark mode
            pdfContentView

            // Floating top bar — page indicator + close
            VStack {
                HStack {
                    Text("\(currentPage) / \(totalPages)")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                Spacer()

                // Floating bottom bar — toc + guide
                HStack(spacing: 10) {
                    Button { loadToc() } label: {
                        Label("목차", systemImage: "list.bullet")
                            .font(.caption)
                    }
                    Button { loadPageGuide() } label: {
                        Label("가이드", systemImage: "book")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showToc) { tocSheet }
        .sheet(isPresented: $showGuide) { guideSheet }
        .sheet(isPresented: $showChapterGuide) { chapterGuideSheet }
    }

    private func submitGuideRatingDetail(serverId: String, rating: Int, tags: [String], comment: String?, isPage: Bool) {
        if isPage { pageGuideRating = rating } else { chapterGuideRating = rating }
        Task {
            do {
                var body: [String: Any] = ["rating": rating, "reason_tags": tags]
                if let comment { body["comment"] = comment }
                try await APIClient.shared.postJSONNoContent("/feedback/\(serverId)/rate", body: body)
            } catch {
                appLogError("rating", "guide detail sync failed", ["server": serverId, "error": "\(error)"])
            }
        }
    }

    // MARK: - TOC Sheet

    private var tocSheet: some View {
        NavigationStack {
            List(chapters) { ch in
                Button {
                    goToPage(ch.pageStart)
                    showToc = false
                } label: {
                    HStack(spacing: 8) {
                        Text(ch.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("p.\(ch.pageStart)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        if ch.level == 1 {
                            Button {
                                showToc = false
                                loadChapterGuide(chapterId: ch.id)
                            } label: {
                                Image(systemName: "book")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                // 들여쓰기는 행 전체에 적용 — 제목이 트레일링(p.X·아이콘)을 밀어내지 않도록
                .listRowInsets(EdgeInsets(
                    top: 8, leading: 16 + CGFloat((ch.level - 1) * 16), bottom: 8, trailing: 16))
            }
            .navigationTitle("목차")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { showToc = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Page Guide Sheet (content explanation + chat)

    struct GuideChatMessage: Identifiable {
        let id = UUID()
        let role: String
        let content: String
        var serverId: String?
        var rating: Int?
    }
    @State private var guideChatMessages: [GuideChatMessage] = []
    @State private var guideChatInput = ""
    @State private var guideChatSending = false

    @State private var chapterChatMessages: [GuideChatMessage] = []
    @State private var chapterChatInput = ""
    @State private var chapterChatSending = false

    // MARK: - Shared chat UI (page guide + chapter guide)

    @ViewBuilder
    private func chatBubble(_ msg: GuideChatMessage, onRate: @escaping (Int) -> Void, onPinTap: @escaping () -> Void) -> some View {
        HStack {
            if msg.role == "user" { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                MarkdownContentView(content: msg.content)
                if msg.role != "user" {
                    Divider()
                    HStack(spacing: 12) {
                        if onPin != nil {
                            Button {
                                onPin?(msg.content, msg.serverId)
                                onPinTap()
                            } label: {
                                Label("스크랩", systemImage: "pin.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ratingButtons(
                            serverId: msg.serverId,
                            currentRating: msg.rating,
                            onRate: onRate,
                            onDetail: nil
                        )
                    }
                }
            }
            .padding(12)
            .background(msg.role == "user" ? Color.blue.opacity(0.1) : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if msg.role != "user" { Spacer(minLength: 60) }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func chatInputBar(text: Binding<String>, sending: Bool, onSend: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField("질문하기...", text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(text.wrappedValue.isEmpty || sending ? .gray : .blue)
            }
            .disabled(text.wrappedValue.isEmpty || sending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var guideSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if guideLoading {
                                ProgressView().padding(.top, 40)
                            } else if let guide = pageGuide {
                                // Page content explanation — long press to pin
                                VStack(alignment: .leading, spacing: 8) {
                                    if !guide.topic.isEmpty {
                                        Text(guide.topic)
                                            .font(.headline)
                                    }

                                    if let content = guide.content, !content.isEmpty {
                                        MarkdownContentView(content: content)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.top)

                                HStack(spacing: 12) {
                                    if onPin != nil {
                                        Button {
                                            let text = guide.content ?? guide.topic
                                            onPin?(text, guide.feedbackId)
                                            showGuide = false
                                        } label: {
                                            Label("스크랩", systemImage: "pin.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    ratingButtons(
                                        serverId: guide.feedbackId,
                                        currentRating: pageGuideRating,
                                        onRate: { r in submitGuideRating(serverId: guide.feedbackId, rating: r, isPage: true) },
                                        onDetail: {
                                            appLog("guide-detail", "page detail tapped", ["serverId": guide.feedbackId ?? "nil"])
                                            pageGuideRatingDetail = true
                                        }
                                    )
                                }
                                .padding(.horizontal)

                                Divider().padding(.vertical, 8)

                                // Chat messages
                                ForEach(Array(guideChatMessages.enumerated()), id: \.element.id) { i, msg in
                                    chatBubble(
                                        msg,
                                        onRate: { r in
                                            guideChatMessages[i].rating = r
                                            submitGuideRating(serverId: msg.serverId, rating: r, isPage: false)
                                        },
                                        onPinTap: { showGuide = false }
                                    )
                                    .id(i)
                                }

                                if guideChatSending {
                                    HStack {
                                        ProgressView().padding(.leading, 16)
                                        Spacer()
                                    }
                                    .id("loading")
                                }
                            } else {
                                Text("가이드를 불러올 수 없습니다.")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 40)
                            }
                        }
                    }
                    .onChange(of: guideChatMessages.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(guideChatMessages.count - 1, anchor: .bottom)
                        }
                    }
                }

                Divider()

                // Chat input
                chatInputBar(text: $guideChatInput, sending: guideChatSending, onSend: sendGuideChat)
            }
            .navigationTitle("p.\(currentPage) 가이드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        showGuide = false
                        guideChatMessages = []
                    }
                }
            }
            .navigationDestination(isPresented: $pageGuideRatingDetail) {
                if let serverId = pageGuide?.feedbackId {
                    RatingFormView(
                        feedbackId: serverId,
                        initialRating: pageGuideRating ?? 1
                    ) { rating, tags, comment in
                        submitGuideRatingDetail(serverId: serverId, rating: rating, tags: tags, comment: comment, isPage: true)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(!guideChatMessages.isEmpty)
    }

    private func sendGuideChat() {
        let text = guideChatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guideChatInput = ""
        guideChatSending = true

        guideChatMessages.append(GuideChatMessage(role: "user", content: text))

        // Build history: guide content as first assistant message
        var history: [[String: String]] = []
        if let guide = pageGuide {
            let guideText = guide.content ?? guide.topic
            history.append(["role": "assistant", "content": guideText])
        }
        for msg in guideChatMessages.dropLast() {
            history.append(["role": msg.role, "content": msg.content])
        }

        Task {
            do {
                struct ChatReq: Encodable {
                    let message: String
                    let history: [[String: String]]
                    let response_language: String
                    let textbook_id: String?
                    let current_page: Int?
                    let parent_feedback_id: String?
                }
                struct ChatRes: Decodable {
                    let content: String
                    let feedback_id: String?
                }

                let reqBody = ChatReq(
                    message: text,
                    history: history,
                    response_language: Config.responseLanguage,
                    textbook_id: textbookId,
                    current_page: currentPage,
                    parent_feedback_id: pageGuide?.feedbackId
                )

                let res: ChatRes = try await APIClient.shared.postCodable("/feedback/chat", body: reqBody)

                await MainActor.run {
                    guideChatMessages.append(GuideChatMessage(role: "assistant", content: res.content, serverId: res.feedback_id))
                    guideChatSending = false
                }
            } catch {
                appLogError("guide-chat", "send failed", ["error": "\(error)"])
                await MainActor.run { guideChatSending = false }
            }
        }
    }

    // MARK: - Chapter Guide Sheet

    private var chapterGuideSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        if chapterGuideLoading {
                            ProgressView().padding(.top, 40)
                        } else if let guide = chapterGuide {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(guide.title).font(.headline)
                                Text(guide.topic).font(.subheadline)

                                Section {
                                    ForEach(guide.keyConcepts, id: \.self) { item in
                                        Text("• \(item)").font(.subheadline)
                                    }
                                } header: { Text("📌 핵심 개념").font(.subheadline.bold()) }

                                Section {
                                    ForEach(Array(guide.studyOrder.enumerated()), id: \.offset) { i, item in
                                        Text("\(i+1). \(item)").font(.subheadline)
                                    }
                                } header: { Text("📋 학습 순서").font(.subheadline.bold()) }

                                Section {
                                    ForEach(guide.commonMistakes, id: \.self) { item in
                                        Text("• \(item)").font(.subheadline)
                                    }
                                } header: { Text("⚠️ 자주 하는 실수").font(.subheadline.bold()) }

                                Section {
                                    Text(guide.summary).font(.subheadline)
                                } header: { Text("요약").font(.subheadline.bold()) }

                                Divider()
                                HStack(spacing: 12) {
                                    if onPin != nil {
                                        Button {
                                            onPin?(chapterGuideText(guide), guide.feedbackId)
                                            showChapterGuide = false
                                        } label: {
                                            Label("스크랩", systemImage: "pin.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    ratingButtons(
                                        serverId: guide.feedbackId,
                                        currentRating: chapterGuideRating,
                                        onRate: { r in submitGuideRating(serverId: guide.feedbackId, rating: r, isPage: false, isChapter: true) },
                                        onDetail: {
                                            appLog("guide-detail", "chapter detail tapped", ["serverId": guide.feedbackId ?? "nil"])
                                            chapterGuideRatingDetail = true
                                        }
                                    )
                                }

                                Divider().padding(.vertical, 8)

                                // Chat messages
                                ForEach(Array(chapterChatMessages.enumerated()), id: \.element.id) { i, msg in
                                    chatBubble(
                                        msg,
                                        onRate: { r in
                                            chapterChatMessages[i].rating = r
                                            submitGuideRating(serverId: msg.serverId, rating: r, isPage: false)
                                        },
                                        onPinTap: { showChapterGuide = false }
                                    )
                                    .id(i)
                                }

                                if chapterChatSending {
                                    HStack {
                                        ProgressView().padding(.leading, 16)
                                        Spacer()
                                    }
                                    .id("loading")
                                }
                            }
                            .padding()
                        } else {
                            Text("챕터 가이드를 불러올 수 없습니다.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        }
                    }
                    .onChange(of: chapterChatMessages.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(chapterChatMessages.count - 1, anchor: .bottom)
                        }
                    }
                }

                Divider()

                // Chat input
                chatInputBar(text: $chapterChatInput, sending: chapterChatSending, onSend: sendChapterChat)
            }
            .navigationTitle("챕터 가이드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        showChapterGuide = false
                        chapterChatMessages = []
                    }
                }
            }
            .navigationDestination(isPresented: $chapterGuideRatingDetail) {
                if let serverId = chapterGuide?.feedbackId {
                    RatingFormView(
                        feedbackId: serverId,
                        initialRating: chapterGuideRating ?? 1
                    ) { rating, tags, comment in
                        submitGuideRatingDetail(serverId: serverId, rating: rating, tags: tags, comment: comment, isPage: false)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(!chapterChatMessages.isEmpty)
    }

    /// 챕터 가이드를 스크랩용 마크다운 텍스트로 직렬화
    private func chapterGuideText(_ guide: ChapterGuide) -> String {
        var parts: [String] = ["## \(guide.title)", guide.topic]
        if !guide.keyConcepts.isEmpty {
            parts.append("**" + String(localized: "📌 핵심 개념") + "**\n" + guide.keyConcepts.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !guide.studyOrder.isEmpty {
            parts.append("**" + String(localized: "📋 학습 순서") + "**\n" + guide.studyOrder.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }
        if !guide.commonMistakes.isEmpty {
            parts.append("**" + String(localized: "⚠️ 자주 하는 실수") + "**\n" + guide.commonMistakes.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !guide.summary.isEmpty {
            parts.append("**" + String(localized: "요약") + "**\n" + guide.summary)
        }
        return parts.joined(separator: "\n\n")
    }

    private func sendChapterChat() {
        let text = chapterChatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chapterChatInput = ""
        chapterChatSending = true

        chapterChatMessages.append(GuideChatMessage(role: "user", content: text))

        // Build history: chapter guide content as first assistant message
        var history: [[String: String]] = []
        if let guide = chapterGuide {
            history.append(["role": "assistant", "content": chapterGuideText(guide)])
        }
        for msg in chapterChatMessages.dropLast() {
            history.append(["role": msg.role, "content": msg.content])
        }

        Task {
            do {
                struct ChatReq: Encodable {
                    let message: String
                    let history: [[String: String]]
                    let response_language: String
                    let textbook_id: String?
                    let current_page: Int?
                    let parent_feedback_id: String?
                }
                struct ChatRes: Decodable {
                    let content: String
                    let feedback_id: String?
                }

                let reqBody = ChatReq(
                    message: text,
                    history: history,
                    response_language: Config.responseLanguage,
                    textbook_id: textbookId,
                    current_page: chapterGuide?.pageStart,
                    parent_feedback_id: chapterGuide?.feedbackId
                )

                let res: ChatRes = try await APIClient.shared.postCodable("/feedback/chat", body: reqBody)

                await MainActor.run {
                    chapterChatMessages.append(GuideChatMessage(role: "assistant", content: res.content, serverId: res.feedback_id))
                    chapterChatSending = false
                }
            } catch {
                appLogError("chapter-chat", "send failed", ["error": "\(error)"])
                await MainActor.run { chapterChatSending = false }
            }
        }
    }

    // MARK: - PDF Content

    @ViewBuilder
    private var pdfContentView: some View {
        let pdf = NativePdfView(
            textbookId: textbookId,
            initialPage: initialPage,
            onPageChanged: { page in
                currentPage = page
                onPageChanged(page)
            },
            onPdfViewReady: { view in
                pdfView = view
            }
        )

        if colorScheme == .dark {
            pdf.colorInvert()
        } else {
            pdf
        }
    }

    // MARK: - Navigation

    private func goToPage(_ page: Int) {
        guard let pdfView, let document = pdfView.document,
              page >= 1, page <= document.pageCount,
              let pdfPage = document.page(at: page - 1) else { return }
        pdfView.go(to: pdfPage)
    }

    // MARK: - Rating

    @ViewBuilder
    private func ratingButtons(serverId: String?, currentRating: Int?, onRate: @escaping (Int) -> Void, onDetail: (() -> Void)?) -> some View {
        Button {
            onRate(1)
        } label: {
            Image(systemName: currentRating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                .foregroundStyle(currentRating == 1 ? Color.green : Color.secondary)
                .font(.caption)
        }
        .disabled(serverId == nil)

        Button {
            onRate(-1)
        } label: {
            Image(systemName: currentRating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                .foregroundStyle(currentRating == -1 ? Color.red : Color.secondary)
                .font(.caption)
        }
        .disabled(serverId == nil)

        if let onDetail {
            Button {
                onDetail()
            } label: {
                Text("자세히")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(serverId == nil)
        }
    }

    private func submitGuideRating(serverId: String?, rating: Int, isPage: Bool, isChapter: Bool = false) {
        guard let serverId else { return }
        if isPage { pageGuideRating = rating }
        if isChapter { chapterGuideRating = rating }
        Task {
            do {
                let body: [String: Any] = ["rating": rating, "reason_tags": []]
                try await APIClient.shared.postJSONNoContent("/feedback/\(serverId)/rate", body: body)
                appLog("rating", "guide synced", ["server": serverId, "rating": "\(rating)"])
            } catch {
                appLogError("rating", "guide sync failed", ["server": serverId, "error": "\(error)"])
            }
        }
    }

    // MARK: - API Calls

    private func loadToc() {
        showToc = true
        guard chapters.isEmpty else { return }
        Task {
            do {
                chapters = try await APIClient.shared.get("/pdf/\(textbookId)/chapters")
            } catch {
                appLogError("pdf", "loadToc failed", ["error": "\(error)"])
            }
        }
    }

    private func loadPageGuide() {
        showGuide = true
        guideLoading = true
        pageGuide = nil
        pageGuideRating = nil
        guideChatMessages = []
        appLog("pdf", "loadGuide start", ["page": "\(currentPage)", "textbookId": textbookId])
        Task {
            do {
                let guide: PageGuide = try await APIClient.shared.get(
                    "/pdf/\(textbookId)/guide",
                    query: ["page": "\(currentPage)", "response_language": Config.responseLanguage]
                )
                appLog("pdf", "guide loaded", [
                    "topic": guide.topic,
                    "hasContent": "\(guide.content?.isEmpty == false)",
                    "contentLen": "\(guide.content?.count ?? 0)",
                ])
                pageGuide = guide
            } catch {
                appLogError("pdf", "loadGuide failed", ["error": "\(error)"])
            }
            guideLoading = false
        }
    }

    private func loadChapterGuide(chapterId: String) {
        showChapterGuide = true
        chapterGuideLoading = true
        chapterGuide = nil
        chapterGuideRating = nil
        chapterChatMessages = []
        Task {
            do {
                chapterGuide = try await APIClient.shared.get(
                    "/pdf/\(textbookId)/chapter-guide",
                    query: ["chapter_id": chapterId, "response_language": Config.responseLanguage]
                )
            } catch {
                appLogError("pdf", "loadChapterGuide failed", ["error": "\(error)"])
            }
            chapterGuideLoading = false
        }
    }
}

// MARK: - Native PDFView wrapper

struct NativePdfView: UIViewRepresentable {
    let textbookId: String
    let initialPage: Int
    let onPageChanged: (Int) -> Void
    var onPdfViewReady: ((PDFView) -> Void)?

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)])
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .systemGray6

        DispatchQueue.main.async {
            onPdfViewReady?(pdfView)
        }

        let coordinator = context.coordinator

        // Reuse cached document if available (survives rotation/app switch)
        if let cachedDoc = coordinator.cachedDocument {
            pdfView.document = cachedDoc
            let targetPage = coordinator.lastPage
            if targetPage > 0, let page = cachedDoc.page(at: targetPage - 1) {
                pdfView.go(to: page)
            }
        } else {
            let startTime = CFAbsoluteTimeGetCurrent()
            let page = initialPage
            Task {
                let data = await Self.loadPdfData(textbookId: textbookId)
                guard let data else { return }
                await MainActor.run {
                    if let document = PDFDocument(data: data) {
                        pdfView.document = document
                        coordinator.cachedDocument = document
                        coordinator.lastPage = page
                        if page > 1, let p = document.page(at: page - 1) {
                            pdfView.go(to: p)
                        }
                        let totalTime = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                        appLog("pdf", "ready", ["pages": "\(document.pageCount)", "ms": "\(totalTime)"])
                    }
                }
            }
        }

        // Page change notification
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // In dark mode, colorInvert() is applied at SwiftUI level,
        // so set white bg here → gets inverted to black visually
        let isDark = uiView.traitCollection.userInterfaceStyle == .dark
        uiView.backgroundColor = isDark ? .white : .systemGray6
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged)
    }

    static func loadPdfData(textbookId: String) async -> Data? {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cachedFile = cacheDir.appendingPathComponent("pdf_\(textbookId).pdf")

        // Check local cache — but validate it actually parses as a PDF.
        // 과거 버그(서버 /file 500/401 등)로 에러 응답 본문이 PDF로 캐시되면 영구히
        // cache hit → 빈 화면이 됐다. 파싱 안 되는 캐시는 오염된 것으로 보고 제거 후 재다운로드.
        if fm.fileExists(atPath: cachedFile.path) {
            if let data = try? Data(contentsOf: cachedFile), PDFDocument(data: data) != nil {
                appLog("pdf", "cache hit", ["textbookId": textbookId])
                return data
            }
            appLog("pdf", "cache invalid, evicting", ["textbookId": textbookId])
            try? fm.removeItem(at: cachedFile)
        }

        // APIClient 경유로 다운로드 — 공용 status 가드(비-2xx면 throw)와 Authorization 헤더를
        // 상속받는다. (과거엔 ?token= 쿼리 + 손수 짠 URLSession이라 status를 안 보고 에러 본문을
        // 캐시했다. 토큰을 URL에 싣지 않으니 access 로그 JWT 누출도 사라진다.)
        appLog("pdf", "downloading", ["textbookId": textbookId])
        do {
            let data = try await APIClient.shared.getData("/pdf/\(textbookId)/file")
            // status는 통과했어도 본문이 유효 PDF일 때만 캐시 (S3 stream 깨짐 등 방어).
            guard PDFDocument(data: data) != nil else {
                appLogError("pdf", "download not a valid PDF", ["bytes": "\(data.count)", "textbookId": textbookId])
                return nil
            }
            try data.write(to: cachedFile)
            appLog("pdf", "downloaded & cached", ["bytes": "\(data.count)"])
            return data
        } catch {
            appLogError("pdf", "download failed", ["error": "\(error)"])
            return nil
        }
    }

    class Coordinator: NSObject {
        let onPageChanged: (Int) -> Void
        var cachedDocument: PDFDocument?
        var lastPage: Int = 1

        init(onPageChanged: @escaping (Int) -> Void) {
            self.onPageChanged = onPageChanged
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let pageIndex = document.index(for: currentPage)
            let page = pageIndex + 1
            lastPage = page
            onPageChanged(page)
        }
    }
}
