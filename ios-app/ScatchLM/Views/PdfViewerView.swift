import SwiftUI
import PDFKit
import MarkdownUI

struct PdfViewerView: View {
    let textbookId: String
    let totalPages: Int
    let initialPage: Int
    let onPageChanged: (Int) -> Void
    let onClose: () -> Void
    var onPin: ((String) -> Void)?

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

    init(textbookId: String, totalPages: Int, initialPage: Int, onPageChanged: @escaping (Int) -> Void, onClose: @escaping () -> Void, onPin: ((String) -> Void)? = nil) {
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

    // MARK: - TOC Sheet

    private var tocSheet: some View {
        NavigationStack {
            List(chapters) { ch in
                Button {
                    goToPage(ch.pageStart)
                    showToc = false
                } label: {
                    HStack {
                        Text(ch.title)
                            .padding(.leading, CGFloat((ch.level - 1) * 16))
                        Spacer()
                        Text("p.\(ch.pageStart)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if ch.level == 1 {
                            Button {
                                showToc = false
                                loadChapterGuide(chapterId: ch.id)
                            } label: {
                                Image(systemName: "book")
                                    .font(.caption)
                            }
                        }
                    }
                }
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

    @State private var guideChatMessages: [(role: String, content: String)] = []
    @State private var guideChatInput = ""
    @State private var guideChatSending = false

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
                                        Markdown(content)
                                            .markdownTextStyle { FontSize(14) }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.top)

                                if onPin != nil {
                                    Button {
                                        let text = guide.content ?? guide.topic
                                        onPin?(text)
                                        showGuide = false
                                    } label: {
                                        Label("캔버스에 박제", systemImage: "pin.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal)
                                }

                                Divider().padding(.vertical, 8)

                                // Chat messages
                                ForEach(Array(guideChatMessages.enumerated()), id: \.offset) { i, msg in
                                    HStack {
                                        if msg.role == "user" { Spacer(minLength: 60) }
                                        VStack(alignment: .leading, spacing: 4) {
                                            Markdown(msg.content)
                                                .markdownTextStyle { FontSize(14) }
                                            if msg.role != "user", onPin != nil {
                                                Divider()
                                                Button {
                                                    onPin?(msg.content)
                                                    showGuide = false
                                                } label: {
                                                    Label("캔버스에 박제", systemImage: "pin.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .padding(12)
                                        .background(msg.role == "user" ? Color.blue.opacity(0.1) : Color(.systemGray6))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        if msg.role != "user" { Spacer(minLength: 60) }
                                    }
                                    .padding(.horizontal)
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
                HStack(spacing: 8) {
                    TextField("질문하기...", text: $guideChatInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)

                    Button {
                        sendGuideChat()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(guideChatInput.isEmpty || guideChatSending ? .gray : .blue)
                    }
                    .disabled(guideChatInput.isEmpty || guideChatSending)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
        }
        .presentationDetents([.medium, .large])
    }

    private func sendGuideChat() {
        let text = guideChatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guideChatInput = ""
        guideChatSending = true

        guideChatMessages.append((role: "user", content: text))

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
                }
                struct ChatRes: Decodable {
                    let content: String
                }

                let reqBody = ChatReq(
                    message: text,
                    history: history,
                    response_language: Config.responseLanguage,
                    textbook_id: textbookId,
                    current_page: currentPage
                )

                let jsonData = try JSONEncoder().encode(reqBody)
                var request = URLRequest(url: URL(string: "\(Config.apiBaseURL)/feedback/chat")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token = AuthService.shared.accessToken {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = jsonData

                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 45
                config.waitsForConnectivity = true
                let (data, _) = try await URLSession(configuration: config).data(for: request)
                let res = try JSONDecoder().decode(ChatRes.self, from: data)

                await MainActor.run {
                    guideChatMessages.append((role: "assistant", content: res.content))
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
                    }
                    .padding()
                } else {
                    Text("챕터 가이드를 불러올 수 없습니다.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .navigationTitle("챕터 가이드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { showChapterGuide = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
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

        // Check local cache
        if fm.fileExists(atPath: cachedFile.path) {
            appLog("pdf", "cache hit", ["textbookId": textbookId])
            return try? Data(contentsOf: cachedFile)
        }

        // Download from backend
        let token = AuthService.shared.accessToken ?? ""
        let urlString = "\(Config.apiBaseURL)/pdf/\(textbookId)/file?token=\(token)"
        appLog("pdf", "downloading", ["textbookId": textbookId])
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: urlString)!)
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
