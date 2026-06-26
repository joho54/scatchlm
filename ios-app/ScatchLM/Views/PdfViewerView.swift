import SwiftUI
import PDFKit
import PencilKit

struct PdfViewerView: View {
    let textbookId: String
    let totalPages: Int
    let initialPage: Int
    let onPageChanged: (Int) -> Void
    let onClose: () -> Void
    /// 카드를 캔버스에 스크랩. 3번째 인자 float=true면 스크랩한 카드를 플로팅 문제 창으로 띄운다(연습문제).
    var onPin: ((String, String?, Bool) -> Void)?
    /// 가이드 채팅 세션을 귀속시킬 노트(있으면). 드로어가 노트 단위로 세션을 모은다(§4.6).
    var noteId: String?
    /// 읽기 전용(iPhone 컴패니언). noteId는 필기 *표시*를 위해 받지만 *편집*(필기 버튼)은 가린다.
    var readOnly: Bool = false
    /// 전체화면 상태(부모 소유) — 상단 확장/축소 버튼 아이콘 분기에만 쓴다. nil이면 버튼을 감춘다.
    var isFullscreen: Bool = false
    /// 전체화면 토글 콜백(부모). 길게 누르기 단축키와 동일한 동작을 눈에 보이는 버튼에도 노출.
    var onToggleFullscreen: (() -> Void)?

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
    // 스캔본 OCR 진행 상태 (scanned-pdf-ocr-spec Track D)
    @State private var pdfStatus: PdfStatus?
    @State private var showOcrStartAlert = false
    @State private var ocrStarting = false
    @State private var ocrError: String?   // OCR 시작 실패(월 건수 초과 등) 사용자 안내
    @State private var guideError: String?
    @State private var chapterGuideError: String?
    @State private var showPaywall = false   // 가이드 quota(429) 도달 시 비-pro 업그레이드 유도
    /// PDF 필기 모드. 부모(NoteView)가 소유 — 노트 캔버스 필기 시도 시 부모가 자동으로 끌 수 있게 바인딩.
    @Binding var inkMode: Bool
    /// 부모의 undo 버튼이 PDF 입력 캔버스로 분기할 수 있게 하는 브리지(있으면). 읽기 전용에선 nil.
    var inkController: PdfInkController?

    init(textbookId: String, totalPages: Int, initialPage: Int, onPageChanged: @escaping (Int) -> Void, onClose: @escaping () -> Void, onPin: ((String, String?, Bool) -> Void)? = nil, noteId: String? = nil, readOnly: Bool = false, isFullscreen: Bool = false, onToggleFullscreen: (() -> Void)? = nil, inkMode: Binding<Bool> = .constant(false), inkController: PdfInkController? = nil) {
        self.textbookId = textbookId
        self.totalPages = totalPages
        self.initialPage = initialPage
        self.onPageChanged = onPageChanged
        self.onClose = onClose
        self.onPin = onPin
        self.noteId = noteId
        self.readOnly = readOnly
        self.isFullscreen = isFullscreen
        self.onToggleFullscreen = onToggleFullscreen
        self._inkMode = inkMode
        self.inkController = inkController
        self._currentPage = State(initialValue: initialPage)
    }

    var body: some View {
        ZStack {
            // PDF content — full area, inverted in dark mode
            pdfContentView

            // Floating top bar — page indicator + close
            VStack {
                // alignment .top + 자식별 top 패딩으로 두 칩을 서로 다른 행에 둔다.
                // 페이지칩: 노트 컨트롤 한 줄 아래(56). 전체화면칩: 노트 컨트롤 행과 같은 높이(16).
                HStack(alignment: .top) {
                    Text("\(currentPage) / \(totalPages)")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        // 노트 컨트롤(좌상단)과 겹치지 않게 한 줄 아래(=12 + 36 + 8).
                        .padding(.top, 56)

                    Spacer()

                    // 확장/축소 — split↔전체화면을 눈에 보이는 버튼으로 노출(길게 누르기 단축키와 동일 동작).
                    if let onToggleFullscreen {
                        Button(action: onToggleFullscreen) {
                            Image(systemName: isFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                                .frame(width: 32, height: 28)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel(isFullscreen ? "PDF 화면 축소" : "PDF 전체화면")
                        // 좌상단 노트 컨트롤 행(36pt 원, top 12, center 30)과 수직 정렬: 28pt 칩 → top 16.
                        .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 10)

                if let status = pdfStatus, status.isScanned, status.ocrStatus != "complete" {
                    ocrStatusBanner(status)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                }

                Spacer()

                // Floating bottom bar — toc + guide + 필기
                // 라벨 폰트는 작게 유지하되 각 버튼에 44pt 히트 영역을 줘 오탭을 막는다(시각 면적 ≈ 유지).
                HStack(spacing: 4) {
                    // 필기 모드일 때만 이전 페이지 화살표 — 첫 페이지에선 비활성.
                    if inkMode {
                        pdfBarButton(title: "이전 페이지", systemImage: "chevron.left", tint: .primary) { stepPage(-1) }
                            .disabled(currentPage <= 1)
                            .opacity(currentPage <= 1 ? 0.35 : 1)
                    }
                    pdfBarButton(title: "목차", systemImage: "list.bullet", tint: .primary) { loadToc() }
                    pdfBarButton(title: "가이드", systemImage: "book", tint: .primary) { loadPageGuide() }
                    // 필기 모드 토글 — 노트에 연결된 PDF에서만 노출. 읽기 전용(iPhone)은 가린다.
                    if noteId != nil, !readOnly {
                        pdfBarButton(
                            title: "필기",
                            systemImage: inkMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                            tint: inkMode ? Color.accentColor : Color.primary
                        ) { inkMode.toggle() }
                    }
                    // 필기 모드일 때만 다음 페이지 화살표 — 마지막 페이지에선 비활성.
                    if inkMode {
                        pdfBarButton(title: "다음 페이지", systemImage: "chevron.right", tint: .primary) { stepPage(1) }
                            .disabled(currentPage >= totalPages)
                            .opacity(currentPage >= totalPages ? 0.35 : 1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showToc) { tocSheet }
        .sheet(isPresented: $showGuide) { guideSheet }
        .sheet(isPresented: $showChapterGuide) { chapterGuideSheet }
        .sheet(isPresented: $showPaywall) {
            PaywallView(reason: String(localized: "오늘 무료 사용량을 모두 사용했어요. Pro로 업그레이드하면 더 많은 학습 가이드를 받을 수 있어요."))
        }
        .alert("이미지 인식 시작", isPresented: $showOcrStartAlert) {
            Button("취소", role: .cancel) {}
            Button("시작") { startOcr() }
        } message: {
            Text("이 교재는 텍스트가 인식되지 않습니다. 이미지 인식(OCR)을 시작하면 챕터·가이드를 쓸 수 있어요. 이번 달 이미지 인식 가능 건수에서 1건이 차감되며, 한 번 시작하면 끝까지 인식합니다.")
        }
        .alert("이미지 인식을 시작할 수 없어요", isPresented: Binding(get: { ocrError != nil }, set: { if !$0 { ocrError = nil } })) {
            Button("확인", role: .cancel) { ocrError = nil }
        } message: {
            Text(ocrError ?? "")
        }
        .task { await pollOcrStatus() }
        .onDisappear { if inkMode { inkMode = false } }   // PDF 닫히면 노트 캔버스 그리기 복구
    }

    /// 하단 플로팅 바 버튼 — 아이콘 전용. 최소 44pt 정사각 히트 영역 + contentShape으로
    /// 빈 여백까지 탭 가능하게 한다. 텍스트 라벨은 접근성용으로만 유지(시각 노이즈 최소).
    @ViewBuilder
    private func pdfBarButton(
        title: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(minWidth: 48, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PdfBarButtonStyle())
        .accessibilityLabel(title)
    }

    /// 하단 바 버튼 탭 피드백 — 누르면 원형 하이라이트가 뜨고 살짝 줄어드는 버블 느낌.
    private struct PdfBarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background {
                    Circle()
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0))
                        .frame(width: 40, height: 40)
                }
                .scaleEffect(configuration.isPressed ? 0.82 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
        }
    }

    /// 스캔본 OCR 진행 배너. 상태별 문구 + 진행 중이면 결정형 프로그레스 바.
    @ViewBuilder
    private func ocrStatusBanner(_ status: PdfStatus) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                switch status.ocrStatus {
                case "available":
                    // 텍스트 레이어가 없는 스캔본 — OCR은 자동 시작하지 않고 명시적 동의를 받는다.
                    Image(systemName: "doc.viewfinder")
                    Text("텍스트가 인식되지 않는 교재예요")
                    Button("이미지 인식 시작") { showOcrStartAlert = true }
                        .font(.caption2.bold())
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                case "paused":
                    Image(systemName: "pause.circle")
                    Text("인식을 잠시 멈췄어요 · 곧 자동으로 이어집니다")
                case "error":
                    Image(systemName: "exclamationmark.triangle")
                    Text("인식 중 문제가 생겼어요 · 곧 자동으로 다시 시도합니다")
                default:  // pending / running
                    ProgressView().scaleEffect(0.7)
                    Text("교재 인식 중… \(status.ocrPagesDone)/\(status.ocrPagesTotal)")
                }
            }
            if status.isProcessing, status.ocrPagesTotal > 0 {
                ProgressView(value: Double(status.ocrPagesDone), total: Double(status.ocrPagesTotal))
                    .frame(maxWidth: 220)
            }
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    /// 유저가 명시적으로 OCR을 시작(쿼터 소진 동의). available/paused/error → pending 후 폴링 재개.
    private func startOcr() {
        guard !ocrStarting else { return }
        ocrStarting = true
        Task {
            defer { ocrStarting = false }
            do {
                let status = try await APIClient.shared.startOcr(textbookId)
                await MainActor.run { pdfStatus = status }
                appLog("pdf", "ocr start requested", ["textbookId": textbookId])
                await pollOcrStatus()  // pending/running 진행률 폴링 재개
            } catch {
                appLogError("pdf", "ocr start failed", ["textbookId": textbookId, "error": "\(error)"])
                // 월 건수 초과 등은 사용자에게 안내(침묵 금지). 그 외도 일반 메시지로 노출.
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? "이미지 인식을 시작하지 못했어요. 잠시 후 다시 시도해 주세요."
                await MainActor.run { ocrError = msg }
            }
        }
    }

    /// is_scanned면 status를 폴링해 진행률을 갱신한다. 스스로 더 진행되지 않는 상태면 종료
    /// (complete/capped/paused/error/available/텍스트PDF). paused·error는 백엔드 스위퍼가 자동 재개한다.
    private func pollOcrStatus() async {
        while !Task.isCancelled {
            do {
                let status = try await APIClient.shared.getPdfStatus(textbookId)
                await MainActor.run { pdfStatus = status }
                if !status.isProcessing { return }  // pending/running 외에는 폴링 종료
            } catch {
                appLogError("pdf", "ocr status poll failed", ["textbookId": textbookId, "error": "\(error)"])
                return
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)  // 4초 간격 폴링
        }
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
        /// 전송 실패한 user 메시지 — 버블에 실패 표시 + 롱홀드 재시도/수정.
        var failed = false
        /// feedback_chats에 영속된 row id(수정 시 soft-delete용). 미영속이면 nil.
        var persistedId: String? = nil
    }
    @State private var guideChatMessages: [GuideChatMessage] = []
    @State private var guideChatInput = ""
    @State private var guideChatSending = false
    /// 현재 페이지 가이드 채팅 세션 id (영속화, §4.6). 첫 메시지 전송 시 생성.
    @State private var guideSessionId: String?

    @State private var chapterChatMessages: [GuideChatMessage] = []
    @State private var chapterChatInput = ""
    @State private var chapterChatSending = false
    @State private var chapterSessionId: String?
    /// '연습문제' 퀵액션으로 전송한 응답을, 도착 시 자동으로 캔버스에 스크랩(onPin)하기 위한 플래그.
    /// page/chapter 가이드 채팅이 한 번에 하나만 열리므로 공용 플래그로 충분하다.
    @State private var pendingPracticeScrap = false

    private let db = DatabaseService.shared

    // MARK: - Shared chat UI (page guide + chapter guide)


    private var guideSheet: some View {
        NavigationStack {
            ChatThreadView(
                turns: guideChatMessages.map {
                    ChatTurn(id: $0.id.uuidString, role: $0.role, content: $0.content,
                             serverId: $0.serverId, rating: $0.rating, failed: $0.failed)
                },
                input: $guideChatInput,
                sending: guideChatSending,
                placeholder: "질문하기...",
                onSend: { sendGuideChat() },
                onScrap: onPin != nil ? { turn in onPin?(turn.content, turn.serverId, false); showGuide = false } : nil,
                onRate: { turn, r in
                    if let i = guideChatMessages.firstIndex(where: { $0.id.uuidString == turn.id }) {
                        guideChatMessages[i].rating = r
                    }
                    submitGuideRating(serverId: turn.serverId, rating: r, isPage: false)
                },
                onRetry: { turn in retryGuideChat(turnId: turn.id, isChapter: false) },
                onEdit: { turn in editGuideChat(turnId: turn.id, isChapter: false) },
                onQuickPractice: onPin != nil ? { requestPractice(isChapter: false) } : nil
            ) { fontSize in
                // 헤더 — 페이지 가이드 설명 + 스크랩/평가
                if guideLoading {
                    ProgressView().padding(.top, 40)
                } else if let guide = pageGuide {
                    VStack(alignment: .leading, spacing: 8) {
                        if !guide.topic.isEmpty {
                            Text(guide.topic).font(.headline)
                        }
                        if let content = guide.content, !content.isEmpty {
                            MarkdownContentView(content: content, fontSize: fontSize, preferBake: true)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top)

                    HStack(spacing: 12) {
                        if onPin != nil {
                            Button {
                                onPin?(guide.content ?? guide.topic, guide.feedbackId, false)
                                showGuide = false
                            } label: {
                                Label("스크랩", systemImage: "pin.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ratingButtons(
                            serverId: guide.feedbackId,
                            currentRating: pageGuideRating,
                            onRate: { r in submitGuideRating(serverId: guide.feedbackId, rating: r, isPage: true) },
                            onDetail: { pageGuideRatingDetail = true }
                        )
                    }
                    .padding(.horizontal)

                    Divider().padding(.vertical, 8)
                } else {
                    Text(guideError ?? "가이드를 불러올 수 없습니다.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 40)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("p.\(currentPage) 가이드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        showGuide = false
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
        // 명시적 '닫기' 버튼으로만 닫는다 — 스와이프/바깥 탭 비활성화.
        .interactiveDismissDisabled(true)
    }

    /// '연습문제' 퀵액션 — 고정 프롬프트를 전송하고 응답을 자동으로 캔버스에 스크랩한다.
    private func requestPractice(isChapter: Bool) {
        guard onPin != nil, !(isChapter ? chapterChatSending : guideChatSending) else { return }
        pendingPracticeScrap = true
        if isChapter { sendChapterChat(overrideText: ChatQuickAction.practicePrompt) }
        else { sendGuideChat(overrideText: ChatQuickAction.practicePrompt) }
    }

    /// 현재 페이지 + 그 위 사용자 필기를 하나의 JPEG로 합성해 base64로 반환 (가이드 채팅 비전 컨텍스트, 길 B).
    /// 필기가 없는 페이지면 nil — 채팅은 이미지 없이 정상 진행하고, 잉크 없는 페이지엔 헛 토큰을 안 쓴다.
    /// 좌표 정합: 입력 레이어(`applyLayout`)와 동일하게 cropBox·page-point 공간에서 그린다.
    private func renderPageWithInkBase64() -> String? {
        guard let nid = noteId,
              let ann = try? db.pdfAnnotation(noteId: nid, page: currentPage),
              let data = ann.drawingData,
              let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        guard let doc = pdfView?.document, currentPage >= 1, currentPage <= doc.pageCount,
              let page = doc.page(at: currentPage - 1) else { return nil }
        let pb = page.bounds(for: .cropBox)
        guard pb.width > 1, pb.height > 1 else { return nil }
        // Vision 입력 상한(~1568px)에 맞춰 긴 변 ~1600 목표로 스케일 산정(최대 2x).
        let scale = min(2.0, 1600 / max(pb.width, pb.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let full = CGRect(origin: .zero, size: pb.size)
        let img = UIGraphicsImageRenderer(size: pb.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(full)
            page.thumbnail(of: CGSize(width: pb.width * scale, height: pb.height * scale), for: .cropBox).draw(in: full)
            drawing.image(from: full, scale: scale).draw(in: full)
        }
        guard let jpeg = img.jpegData(compressionQuality: 0.6) else { return nil }
        appLog("guide-chat", "annotation image attached", ["page": "\(currentPage)", "bytes": "\(jpeg.count)"])
        return jpeg.base64EncodedString()
    }

    private func sendGuideChat(overrideText: String? = nil) {
        let text = (overrideText ?? guideChatInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 퀵액션 전송은 입력창을 비우지 않는다(유저가 치던 내용 보존).
        if overrideText == nil { guideChatInput = "" }

        var userMsg = GuideChatMessage(role: "user", content: text)
        // 세션 보장 + user 메시지 영속화 (§4.6). 가이드 본문은 세션 첫 assistant 메시지로 저장된다.
        let guideBody = pageGuide.map { $0.content ?? $0.topic }
        let sid = ensureGuideSession(kind: .pageGuide, anchorPage: currentPage,
                                     chapterTitle: pageGuide?.topic, bodyText: guideBody,
                                     bodyServerId: pageGuide?.feedbackId)
        if let sid {
            try? db.setSessionTitleIfEmpty(sessionId: sid, title: text)
            userMsg.persistedId = persistGuideMessage(sessionId: sid, role: "user", content: text, serverId: nil)
        }
        guideChatMessages.append(userMsg)
        deliverGuideChat(turnId: userMsg.id, isChapter: false)
    }

    /// 페이지/챕터 가이드 채팅 공용 전송 경로(첫 전송·재시도). 실패 시 일시 장애(502/500/529 등)는
    /// 해당 user 버블을 failed로 표시해 롱홀드 재시도/수정을 노출하고, quota 초과는 Paywall로 안내.
    private func deliverGuideChat(turnId: UUID, isChapter: Bool) {
        let msgs = isChapter ? chapterChatMessages : guideChatMessages
        guard let userMsg = msgs.first(where: { $0.id == turnId }) else { return }
        setGuideSending(isChapter, true)
        setGuideFailed(isChapter, turnId: turnId, false)

        // history: 가이드 본문(헤더) + 이 메시지 '이전'의 전달된 메시지. 실패 메시지는 컨텍스트에서 제외.
        var history: [[String: String]] = []
        if isChapter {
            if let g = chapterGuide { history.append(["role": "assistant", "content": chapterGuideText(g)]) }
        } else {
            if let g = pageGuide { history.append(["role": "assistant", "content": g.content ?? g.topic]) }
        }
        for msg in msgs {
            if msg.id == turnId { break }
            if msg.failed { continue }
            history.append(["role": msg.role, "content": msg.content])
        }

        let sid = isChapter ? chapterSessionId : guideSessionId
        let pageParam = isChapter ? chapterGuide?.pageStart : currentPage
        let parentId = isChapter ? chapterGuide?.feedbackId : pageGuide?.feedbackId
        let tag = isChapter ? "chapter-chat" : "guide-chat"
        let messageText = userMsg.content
        // 현재 페이지에 필기가 있으면 페이지+잉크 합성 이미지를 첨부(길 B). main에서 합성(UIKit/db 접근).
        let annotationImage = renderPageWithInkBase64()

        Task {
            do {
                struct ChatReq: Encodable {
                    let message: String
                    let history: [[String: String]]
                    let response_language: String
                    let textbook_id: String?
                    let current_page: Int?
                    let note_id: String?
                    let parent_feedback_id: String?
                    let annotation_image: String?
                }
                struct ChatRes: Decodable {
                    let content: String
                    let feedback_id: String?
                    let keywords: [String]?   // DMN 인출 단서 (구버전 서버는 미포함 → nil)
                }

                let reqBody = ChatReq(
                    message: messageText,
                    history: history,
                    response_language: Config.responseLanguage,
                    textbook_id: textbookId,
                    current_page: pageParam,
                    note_id: noteId,
                    parent_feedback_id: parentId,
                    annotation_image: annotationImage
                )

                let res: ChatRes = try await APIClient.shared.postCodable("/feedback/chat", body: reqBody)

                // DMN 인출 단서 적재 — 노트 scope. 가이드 채팅(교재 읽기)은 사용자 최고 가치 경로라
                // 캔버스 피드백 채팅과 동일하게 단서를 모은다. PDF 뷰어가 노트 밖이면 noteId=nil → 스킵.
                let kwCount = res.keywords?.count ?? 0
                if let nid = noteId, let kws = res.keywords, !kws.isEmpty {
                    // 가이드 채팅 세션(sid)을 함께 링크 — 위젯 단서가 해당 세션 시트로 점프하도록.
                    // 누락 시 note 폴백 링크가 되어 위젯 탭이 "앱만 켜지고 점프 안 됨"이 된다.
                    try? db.insertDMNCues(noteId: nid, keywords: kws, source: "guide-chat", sessionId: sid)
                    appLog("dmn", "cues inserted (guide-chat)", ["note": nid, "n": "\(kws.count)"])
                } else {
                    appLog("dmn", "cues skipped (guide-chat)", ["hasNote": "\(noteId != nil)", "kw": "\(kwCount)"])
                }

                await MainActor.run {
                    appendGuideAssistant(isChapter, content: res.content, serverId: res.feedback_id)
                    if let sid { persistGuideMessage(sessionId: sid, role: "assistant", content: res.content, serverId: res.feedback_id) }
                    setGuideSending(isChapter, false)
                    // 퀵액션('연습문제')으로 보낸 응답이면 자동 스크랩 후 가이드 시트를 닫아 캔버스로 내보낸다.
                    if pendingPracticeScrap {
                        pendingPracticeScrap = false
                        onPin?(res.content, res.feedback_id, true)
                        if isChapter { showChapterGuide = false } else { showGuide = false }
                    }
                }
            } catch {
                appLogError(tag, "send failed", ["error": "\(error)"])
                await MainActor.run {
                    pendingPracticeScrap = false
                    if case APIError.quotaExceeded = error {
                        // 재시도해도 quota는 안 풀림 — 비-pro는 Paywall, pro는 시트 유지.
                        _ = quotaGuideMessage { if isChapter { showChapterGuide = false } else { showGuide = false } }
                    } else {
                        setGuideFailed(isChapter, turnId: turnId, true)
                    }
                    setGuideSending(isChapter, false)
                }
            }
        }
    }

    /// 실패한 가이드 채팅 메시지를 같은 내용으로 재전송.
    private func retryGuideChat(turnId: String, isChapter: Bool) {
        let msgs = isChapter ? chapterChatMessages : guideChatMessages
        guard let m = msgs.first(where: { $0.id.uuidString == turnId }) else { return }
        appLog(isChapter ? "chapter-chat" : "guide-chat", "retry failed message")
        deliverGuideChat(turnId: m.id, isChapter: isChapter)
    }

    /// 실패한 가이드 채팅 메시지를 입력창으로 되돌리고 버블 제거(영속분은 soft-delete) — 수정 후 재전송.
    private func editGuideChat(turnId: String, isChapter: Bool) {
        let msgs = isChapter ? chapterChatMessages : guideChatMessages
        guard let m = msgs.first(where: { $0.id.uuidString == turnId }) else { return }
        if isChapter {
            chapterChatInput = m.content
            chapterChatMessages.removeAll { $0.id == m.id }
        } else {
            guideChatInput = m.content
            guideChatMessages.removeAll { $0.id == m.id }
        }
        if let pid = m.persistedId { try? db.softDeleteChatMessage(id: pid) }
        appLog(isChapter ? "chapter-chat" : "guide-chat", "edit failed message")
    }

    // 가이드 채팅 @State 접근 헬퍼(page/chapter 분기) — deliver/retry/edit 공용.
    private func setGuideSending(_ isChapter: Bool, _ value: Bool) {
        if isChapter { chapterChatSending = value } else { guideChatSending = value }
    }

    private func setGuideFailed(_ isChapter: Bool, turnId: UUID, _ value: Bool) {
        if isChapter {
            if let i = chapterChatMessages.firstIndex(where: { $0.id == turnId }) { chapterChatMessages[i].failed = value }
        } else {
            if let i = guideChatMessages.firstIndex(where: { $0.id == turnId }) { guideChatMessages[i].failed = value }
        }
    }

    private func appendGuideAssistant(_ isChapter: Bool, content: String, serverId: String?) {
        let msg = GuideChatMessage(role: "assistant", content: content, serverId: serverId)
        if isChapter { chapterChatMessages.append(msg) } else { guideChatMessages.append(msg) }
    }

    // MARK: - Chapter Guide Sheet

    private var chapterGuideSheet: some View {
        NavigationStack {
            ChatThreadView(
                turns: chapterChatMessages.map {
                    ChatTurn(id: $0.id.uuidString, role: $0.role, content: $0.content,
                             serverId: $0.serverId, rating: $0.rating, failed: $0.failed)
                },
                input: $chapterChatInput,
                sending: chapterChatSending,
                placeholder: "질문하기...",
                onSend: { sendChapterChat() },
                onScrap: onPin != nil ? { turn in onPin?(turn.content, turn.serverId, false); showChapterGuide = false } : nil,
                onRate: { turn, r in
                    if let i = chapterChatMessages.firstIndex(where: { $0.id.uuidString == turn.id }) {
                        chapterChatMessages[i].rating = r
                    }
                    submitGuideRating(serverId: turn.serverId, rating: r, isPage: false)
                },
                onRetry: { turn in retryGuideChat(turnId: turn.id, isChapter: true) },
                onEdit: { turn in editGuideChat(turnId: turn.id, isChapter: true) },
                onQuickPractice: onPin != nil ? { requestPractice(isChapter: true) } : nil
            ) { _ in
                // 헤더 — 챕터 가이드 요약 + 스크랩/평가
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
                                    onPin?(chapterGuideText(guide), guide.feedbackId, false)
                                    showChapterGuide = false
                                } label: {
                                    Label("스크랩", systemImage: "pin.fill")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ratingButtons(
                                serverId: guide.feedbackId,
                                currentRating: chapterGuideRating,
                                onRate: { r in submitGuideRating(serverId: guide.feedbackId, rating: r, isPage: false, isChapter: true) },
                                onDetail: { chapterGuideRatingDetail = true }
                            )
                        }

                        Divider().padding(.vertical, 8)
                    }
                    .padding(.horizontal)
                } else {
                    Text(chapterGuideError ?? "챕터 가이드를 불러올 수 없습니다.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 40)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("챕터 가이드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        showChapterGuide = false
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
        // 명시적 '닫기' 버튼으로만 닫는다 — 스와이프/바깥 탭 비활성화.
        .interactiveDismissDisabled(true)
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

    private func sendChapterChat(overrideText: String? = nil) {
        let text = (overrideText ?? chapterChatInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 퀵액션 전송은 입력창을 비우지 않는다(유저가 치던 내용 보존).
        if overrideText == nil { chapterChatInput = "" }

        var userMsg = GuideChatMessage(role: "user", content: text)
        // 세션 보장 + user 메시지 영속화 (§4.6). 챕터 본문은 세션 첫 assistant 메시지로 저장된다.
        let chapterBody = chapterGuide.map { chapterGuideText($0) }
        let sid = ensureGuideSession(kind: .chapterGuide, anchorPage: chapterGuide?.pageStart ?? currentPage,
                                     chapterTitle: chapterGuide?.title, bodyText: chapterBody,
                                     bodyServerId: chapterGuide?.feedbackId)
        if let sid {
            try? db.setSessionTitleIfEmpty(sessionId: sid, title: text)
            userMsg.persistedId = persistGuideMessage(sessionId: sid, role: "user", content: text, serverId: nil)
        }
        chapterChatMessages.append(userMsg)
        deliverGuideChat(turnId: userMsg.id, isChapter: true)
    }

    // MARK: - PDF Content

    @ViewBuilder
    private var pdfContentView: some View {
        ZStack {
            let pdf = NativePdfView(
                textbookId: textbookId,
                noteId: noteId,
                inkMode: inkMode,
                initialPage: initialPage,
                onPageChanged: { page in
                    currentPage = page
                    onPageChanged(page)
                },
                onPdfViewReady: { view in
                    pdfView = view
                }
            )
            if colorScheme == .dark { pdf.colorInvert() } else { pdf }

            // 잉크 모드 입력 레이어 — 노트 연결 + pdfView 준비 시에만 PDFView 위 형제로 얹는다.
            // 다크모드에선 표시 오버레이(PDF와 함께 반전)와 색을 맞추려 입력도 동일 반전.
            if inkMode, let noteId, let pdfView {
                let input = PdfInkInputView(pdfView: pdfView, noteId: noteId, pdfPage: currentPage, inkController: inkController)
                if colorScheme == .dark { input.colorInvert() } else { input }
            }
        }
    }

    // MARK: - Navigation

    private func goToPage(_ page: Int) {
        guard let pdfView, let document = pdfView.document,
              page >= 1, page <= document.pageCount,
              let pdfPage = document.page(at: page - 1) else { return }
        pdfView.go(to: pdfPage)
    }

    /// 필기 모드용 명시적 페이지 이동(±1). 라이브 PDFView를 이동시키면 `.PDFViewPageChanged` →
    /// onPageChanged → currentPage 갱신이 흐르고, currentPage 변화가 입력 레이어(PdfInkInputView)의
    /// `update(page:)`를 태워 현재 필기 commit → 새 페이지 정적 렌더·필기 로드를 자동 처리한다.
    /// (필기 모드에선 불투명 입력 레이어가 라이브 PDFView를 덮어 스와이프 페이징이 불가하므로 버튼으로 노출.)
    private func stepPage(_ delta: Int) {
        let target = currentPage + delta
        guard target >= 1, target <= totalPages else { return }
        goToPage(target)
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

    // MARK: - 가이드 채팅 세션 영속화 (chapter-chat-drawer-spec §4.6 / Track C)

    /// 같은 페이지·교재의 기존 가이드 세션을 찾아 메시지를 로드한다(이어가기).
    /// 세션의 message[0]는 가이드 본문(assistant)이므로 turn 리스트엔 dropFirst로 제외(헤더가 본문 표시).
    private func loadGuideSession(kind: ChatSessionRecord.Kind, anchorPage: Int) {
        guard let session = try? db.guideSession(kind: kind, textbookId: textbookId, anchorPage: anchorPage, noteId: noteId) else {
            if kind == .pageGuide { guideSessionId = nil; guideChatMessages = [] }
            else { chapterSessionId = nil; chapterChatMessages = [] }
            return
        }
        let msgs = (try? db.messages(sessionId: session.id)) ?? []
        let turns = msgs.dropFirst().map {
            GuideChatMessage(role: $0.role, content: $0.content, serverId: $0.serverMessageId, rating: $0.userRating)
        }
        if kind == .pageGuide { guideSessionId = session.id; guideChatMessages = turns }
        else { chapterSessionId = session.id; chapterChatMessages = turns }
    }

    /// 가이드 세션을 보장한다. 없으면 생성 + 가이드 본문을 첫 assistant 메시지로 영속화(결정 2/R4).
    private func ensureGuideSession(kind: ChatSessionRecord.Kind, anchorPage: Int, chapterTitle: String?, bodyText: String?, bodyServerId: String?) -> String? {
        if kind == .pageGuide, let sid = guideSessionId { return sid }
        if kind == .chapterGuide, let sid = chapterSessionId { return sid }
        var session = ChatSessionRecord(
            kind: kind.rawValue, title: "", noteId: noteId, textbookId: textbookId,
            anchorPage: anchorPage, chapterTitle: chapterTitle
        )
        do {
            try db.saveSession(&session)
        } catch {
            appLogError("guide-chat", "create session failed", ["error": "\(error)"])
            return nil
        }
        if let bodyText, !bodyText.isEmpty {
            persistGuideMessage(sessionId: session.id, role: "assistant", content: bodyText, serverId: bodyServerId)
        }
        if kind == .pageGuide { guideSessionId = session.id } else { chapterSessionId = session.id }
        return session.id
    }

    @discardableResult
    private func persistGuideMessage(sessionId: String, role: String, content: String, serverId: String?) -> String? {
        var msg = ChatMessageRecord(
            id: UUID().uuidString, sessionId: sessionId, role: role, content: content,
            createdAt: Date(), serverMessageId: serverId
        )
        do { try db.saveChatMessage(&msg); return msg.id }
        catch { appLogError("guide-chat", "persist message failed", ["error": "\(error)"]); return nil }
    }

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

    /// 가이드 quota(429) 도달 시 공통 처리. 비-pro(구독 활성)면 가이드 시트를 닫고 Paywall을
    /// 올린다(시트 동시 표시 충돌 회피 위해 닫힘 애니메이션 후 제시) — feedback 경로와 동작 일치.
    /// 어느 경우든 친화 문구를 반환해 시트가 닫히기 전/pro 유저에게 표시되도록 한다.
    private func quotaGuideMessage(dismissSheet: @escaping () -> Void) -> String {
        let message = String(localized: "오늘 사용량을 모두 사용했어요. 내일 다시 시도해 주세요.")
        if Config.subscriptionEnabled, !StoreKitService.shared.isPro {
            dismissSheet()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showPaywall = true }
        }
        return message
    }

    private func loadPageGuide() {
        showGuide = true
        guideLoading = true
        pageGuide = nil
        pageGuideRating = nil
        guideError = nil
        loadGuideSession(kind: .pageGuide, anchorPage: currentPage)
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
            } catch let APIError.ocrIncomplete(info) {
                appLog("pdf", "loadGuide ocr_incomplete", ["capped": "\(info.capped)"])
                guideError = APIError.ocrIncomplete(info).errorDescription
            } catch APIError.quotaExceeded(_) {
                appLog("pdf", "loadGuide quota_exceeded", [:])
                guideError = quotaGuideMessage(dismissSheet: { showGuide = false })
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
        chapterGuideError = nil
        chapterSessionId = nil
        chapterChatMessages = []
        Task {
            do {
                let guide: ChapterGuide = try await APIClient.shared.get(
                    "/pdf/\(textbookId)/chapter-guide",
                    query: ["chapter_id": chapterId, "response_language": Config.responseLanguage]
                )
                chapterGuide = guide
                // 챕터 가이드는 pageStart를 anchor로 잡아 기존 세션을 이어간다(§4.6).
                loadGuideSession(kind: .chapterGuide, anchorPage: guide.pageStart)
            } catch let APIError.ocrIncomplete(info) {
                appLog("pdf", "loadChapterGuide ocr_incomplete", ["capped": "\(info.capped)"])
                chapterGuideError = APIError.ocrIncomplete(info).errorDescription
            } catch APIError.quotaExceeded(_) {
                appLog("pdf", "loadChapterGuide quota_exceeded", [:])
                chapterGuideError = quotaGuideMessage(dismissSheet: { showChapterGuide = false })
            } catch {
                appLogError("pdf", "loadChapterGuide failed", ["error": "\(error)"])
            }
            chapterGuideLoading = false
        }
    }
}

// MARK: - Native PDFView wrapper (렌더링 + 표시 전용 잉크 오버레이)

struct NativePdfView: UIViewRepresentable {
    let textbookId: String
    /// 필기 귀속 노트. nil이면 필기 오버레이 비활성(읽기 전용).
    var noteId: String?
    /// 필기 모드. ON이면 오버레이 캔버스가 입력을 받고 툴 팔레트가 뜬다.
    var inkMode: Bool = false
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
        coordinator.pdfView = pdfView

        // 표시 전용 잉크 오버레이: 저장된 필기를 페이지 좌표에 정렬해 "보여주기만" 한다.
        // 입력은 별도 PdfInkInputView(형제 레이어)가 받는다 — pageVC에서 overlay가 터치를 못 받는
        // PDFKit 비호환 우회. 표시는 overlay가 받아도 무방하므로 PDFKit의 페이징/줌 정렬을 그대로 활용.
        if coordinator.noteId != nil {
            pdfView.pageOverlayViewProvider = coordinator
            appLogDebug("ink", "overlay provider set (display)", ["noteId": coordinator.noteId ?? "nil"])
        }

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
        context.coordinator.setInkMode(inkMode)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(noteId: noteId, onPageChanged: onPageChanged)
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

    /// 표시 전용 오버레이 + 페이지 추적 Coordinator. 입력/저장은 PdfInkInputView가 담당한다.
    /// 여기 캔버스는 항상 비대화형이라 pageVC의 overlay-touch 비호환과 무관하다.
    class Coordinator: NSObject, PDFPageOverlayViewProvider {
        let noteId: String?
        let onPageChanged: (Int) -> Void
        var cachedDocument: PDFDocument?
        var lastPage: Int = 1

        weak var pdfView: PDFView?
        private let db = DatabaseService.shared
        /// 표시 중인 페이지별 표시 캔버스(pdf_page 1-based → canvas).
        private var displayCanvases: [Int: PKCanvasView] = [:]
        private var inkMode = false

        init(noteId: String?, onPageChanged: @escaping (Int) -> Void) {
            self.noteId = noteId
            self.onPageChanged = onPageChanged
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let page = document.index(for: currentPage) + 1
            lastPage = page
            onPageChanged(page)
        }

        private func pageNumber(for page: PDFPage) -> Int {
            (page.document?.index(for: page) ?? 0) + 1
        }

        private func loadDrawing(page: Int) -> PKDrawing {
            guard let noteId,
                  let ann = try? db.pdfAnnotation(noteId: noteId, page: page),
                  let data = ann.drawingData,
                  let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
            return drawing
        }

        // MARK: - 표시 오버레이 (비대화형 — 저장된 필기 표시만)

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard noteId != nil else { return nil }
            let pageNum = pageNumber(for: page)
            let canvas = PKCanvasView()
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isUserInteractionEnabled = false       // 표시 전용 — 입력은 PdfInkInputView
            canvas.drawing = loadDrawing(page: pageNum)
            canvas.alpha = inkMode ? 0 : 1                 // 잉크 모드 중엔 입력 레이어가 대신 표시
            displayCanvases[pageNum] = canvas
            return canvas
        }

        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = overlayView as? PKCanvasView else { return }
            let pageNum = pageNumber(for: page)
            displayCanvases[pageNum] = canvas
            canvas.drawing = loadDrawing(page: pageNum)    // 표시 시점 최신 DB 반영
            canvas.alpha = inkMode ? 0 : 1
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            displayCanvases.removeValue(forKey: pageNumber(for: page))
        }

        // MARK: - 잉크 모드 표시 토글

        func setInkMode(_ on: Bool) {
            guard on != inkMode else { return }
            inkMode = on
            // 토글 시 리사이즈 진단: 라이브 PDFView가 그리는 페이지 표시 크기(scaleFactor 반영)와
            // 패널 bounds를 찍는다. 입력 레이어의 fit-zoom 표시 크기(아래 ink "input zoom")와 비교해
            // 두 사이징이 어긋나면(=토글 시 페이지가 커지거나 작아지면) 그 차이가 원인.
            if let pv = pdfView, let pg = pv.currentPage {
                let box = pg.bounds(for: pv.displayBox).size
                let disp = CGSize(width: box.width * pv.scaleFactor, height: box.height * pv.scaleFactor)
                appLogDebug("ink", "live pdf at toggle", [
                    "on": "\(on)", "scaleFactor": "\(pv.scaleFactor)",
                    "pageDisp": "\(disp)", "bounds": "\(pv.bounds.size)",
                    "displayBox": "\(pv.displayBox.rawValue)",
                ])
            }
            appLogDebug("ink", "display setInkMode", ["on": "\(on)"])
            if on {
                // 진입: 표시 오버레이 숨김(입력 레이어가 표시·편집을 가져감).
                for canvas in displayCanvases.values { canvas.alpha = 0 }
            } else {
                // 종료: 입력 레이어(dismantle)가 DB 커밋을 끝낸 뒤 리로드되도록 다음 런루프에 반영.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    for (pageNum, canvas) in self.displayCanvases {
                        canvas.drawing = self.loadDrawing(page: pageNum)
                        canvas.alpha = 1
                    }
                }
            }
        }
    }
}

// MARK: - PDF 필기 입력 레이어 (ink 모드 전용 형제 레이어, 입력·저장을 우리가 100% 통제)

/// PDF 입력 캔버스의 undo/redo 브리지. 부모(NoteView)가 소유하고, 입력 레이어가 살아있는 동안
/// 캔버스 weak 참조를 주입한다. NoteView의 단일 undo 버튼이 `pdfInkActive`에 따라 노트 캔버스 ↔
/// 이 컨트롤러로 분기 — 새 버튼/상태 없이 기존 토글의 배타성에 무임승차한다.
/// 주의: 페이지 전환 시 입력 캔버스가 `drawing`을 재할당하므로 undo 스택은 페이지 단위로 초기화된다.
@Observable
final class PdfInkController {
    weak var canvas: PKCanvasView?
    var canUndo = false
    var canRedo = false

    func attach(_ canvas: PKCanvasView?) {
        self.canvas = canvas
        refresh()
    }

    func refresh() {
        canUndo = canvas?.undoManager?.canUndo ?? false
        canRedo = canvas?.undoManager?.canRedo ?? false
    }

    func undo() { canvas?.undoManager?.undo(); refresh() }
    func redo() { canvas?.undoManager?.redo(); refresh() }
}

/// inkMode일 때만 PDFView 위에 형제로 얹히는 입력 레이어. 라이브 PDFView 대신 **현재 페이지를
/// 정적 이미지로 렌더**해 host(UIScrollView) > contentView > [페이지이미지, 캔버스] 구조에 올린다
/// (GoodNotes식). 1손가락=그리기(.anyInput), 2손가락=핀치 줌/팬(host). 라이브 PDFView 제스처와
/// 완전히 분리돼 pageVC/overlay-touch 비호환과 무관. 드로잉 좌표는 페이지 point 공간(표시 오버레이와
/// 동일)으로 저장돼 1:1 정렬된다.
struct PdfInkInputView: UIViewRepresentable {
    let pdfView: PDFView
    let noteId: String
    let pdfPage: Int
    var inkController: PdfInkController?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> InkHostScrollView {
        let coord = context.coordinator
        coord.noteId = noteId
        coord.pageNum = pdfPage
        coord.pdfDocument = pdfView.document
        coord.controller = inkController

        // host: 줌/팬 주체. 펜=그리기, 2손가락=팬/핀치줌 (pan 최소 2터치).
        // 배경을 불투명으로 — 뒤의 라이브 PDFView(읽기 모드 줌 상태)를 완전히 덮어 겹침 방지.
        let host = InkHostScrollView()
        host.backgroundColor = colorScheme == .dark ? .white : .systemGray6
        host.delegate = coord
        host.contentInsetAdjustmentBehavior = .never
        host.showsVerticalScrollIndicator = false
        host.showsHorizontalScrollIndicator = false
        host.bouncesZoom = true
        // 실기기: .pencilOnly라 손가락은 그리기 안 함 → 1손가락 이동 허용(펜=그리기, 손=이동/줌).
        // 시뮬레이터: .anyInput(마우스=그리기)라 1손가락 pan이 그리기와 충돌 → 2손가락 이동.
        #if targetEnvironment(simulator)
        host.panGestureRecognizer.minimumNumberOfTouches = 2
        #else
        host.panGestureRecognizer.minimumNumberOfTouches = 1
        #endif
        host.onLayout = { [weak coord] in coord?.applyLayout() }

        // contentView: 줌 대상(viewForZooming). 페이지 point 크기 고정.
        let contentView = UIView()
        host.addSubview(contentView)

        // 페이지 이미지(정적 렌더) — ink 모드 중 라이브 PDFView를 덮어 제스처 분리.
        let imageView = UIImageView()
        imageView.contentMode = .scaleToFill
        contentView.addSubview(imageView)

        // 그리기 캔버스 — 페이지 point 공간, 스크롤은 host가 담당.
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput        // 시뮬레이터엔 펜이 없어 마우스로 그려야 함
        #else
        canvas.drawingPolicy = .pencilOnly      // 펜만 그리기 — 손가락은 2지 줌/팬, 손바닥 거치 무시
        #endif
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.delegate = coord
        contentView.addSubview(canvas)

        coord.host = host
        coord.contentView = contentView
        coord.imageView = imageView
        coord.canvas = canvas

        // PDF 전용 툴피커 — 노트 캔버스 툴피커와 분리(격리)
        DispatchQueue.main.async {
            let picker = PKToolPicker()
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            coord.toolPicker = picker
            canvas.becomeFirstResponder()
            coord.controller?.attach(canvas)   // undo 브리지 연결 — first responder 된 뒤라야 undoManager가 산다
            appLogDebug("ink", "input ready", ["page": "\(coord.pageNum)", "undoMgr": "\(canvas.undoManager != nil)"])
        }

        NotificationCenter.default.addObserver(
            coord, selector: #selector(Coordinator.onBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)

        return host
    }

    func updateUIView(_ host: InkHostScrollView, context: Context) {
        host.backgroundColor = colorScheme == .dark ? .white : .systemGray6
        context.coordinator.update(page: pdfPage)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ host: InkHostScrollView, coordinator: Coordinator) {
        coordinator.commit()                  // 사라질 때(잉크 모드 OFF) 즉시 저장
        coordinator.controller?.attach(nil)   // undo 브리지 해제 — 잉크 OFF 후 stale canUndo 방지
        coordinator.canvas?.resignFirstResponder()
        if let picker = coordinator.toolPicker, let canvas = coordinator.canvas {
            picker.setVisible(false, forFirstResponder: canvas)
        }
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        weak var host: InkHostScrollView?
        weak var contentView: UIView?
        weak var imageView: UIImageView?
        weak var canvas: PKCanvasView?
        var toolPicker: PKToolPicker?
        var controller: PdfInkController?
        var pdfDocument: PDFDocument?
        var noteId: String = ""
        var pageNum: Int = 0
        private let db = DatabaseService.shared
        private var loaded = false
        private var rendered = false
        private var didInitialZoom = false
        private var pageSize: CGSize = .zero
        private var saveWork: DispatchWorkItem?

        func update(page: Int) {
            if page != pageNum {
                commit()
                pageNum = page
                loaded = false; rendered = false; didInitialZoom = false
            }
            applyLayout()
        }

        /// 페이지 point 공간으로 contentView/이미지/캔버스를 세팅하고, host에 fit-zoom 적용.
        func applyLayout() {
            guard let host, let contentView, let imageView, let canvas,
                  let doc = pdfDocument, pageNum >= 1, pageNum <= doc.pageCount,
                  let page = doc.page(at: pageNum - 1) else { return }
            let pb = page.bounds(for: .cropBox)
            guard pb.width > 1, pb.height > 1 else { return }
            pageSize = pb.size

            if !rendered {
                rendered = true
                contentView.frame = CGRect(origin: .zero, size: pb.size)
                imageView.frame = contentView.bounds
                canvas.frame = contentView.bounds            // 페이지 point 공간 = 저장 좌표
                host.contentSize = pb.size
                // 페이지 정적 렌더(2x). PencilKit 잉크는 벡터라 줌해도 선명.
                imageView.image = page.thumbnail(of: CGSize(width: pb.width * 2, height: pb.height * 2), for: .cropBox)
                if let ann = try? db.pdfAnnotation(noteId: noteId, page: pageNum),
                   let data = ann.drawingData, let drawing = try? PKDrawing(data: data) {
                    canvas.drawing = drawing
                } else {
                    canvas.drawing = PKDrawing()
                }
                loaded = true
                controller?.refresh()   // 페이지 로드 시 drawing 재할당 → undo 스택 비워짐. 버튼 disabled 동기화.
                appLogDebug("ink", "input render", ["page": "\(pageNum)", "pageSize": "\(pb.size)", "loaded": "\(canvas.drawing.strokes.count)"])
            }

            let avail = host.bounds.size
            guard avail.width > 1, avail.height > 1 else { return }
            let fit = min(avail.width / pb.width, avail.height / pb.height)
            if !didInitialZoom, fit > 0 {
                didInitialZoom = true
                host.minimumZoomScale = fit
                host.maximumZoomScale = fit * 4
                host.zoomScale = fit
                // 토글 시 리사이즈 진단: 입력 레이어가 fit-zoom으로 그리는 페이지 표시 크기.
                // 라이브 PDFView "live pdf at toggle"의 pageDisp와 비교 — 다르면 토글 점프의 원인.
                appLogDebug("ink", "input zoom", [
                    "page": "\(pageNum)", "fit": "\(fit)",
                    "pageDisp": "\(CGSize(width: pb.width * fit, height: pb.height * fit))",
                    "avail": "\(avail)",
                ])
            }
            centerContent()
        }

        /// 콘텐츠가 뷰포트보다 작으면 inset으로 가운데 정렬.
        private func centerContent() {
            guard let host, let contentView else { return }
            let cw = contentView.frame.width, ch = contentView.frame.height
            let insetX = max(0, (host.bounds.width - cw) / 2)
            let insetY = max(0, (host.bounds.height - ch) / 2)
            host.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        // MARK: UIScrollViewDelegate (2손가락 줌/팬)

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

        // MARK: 저장

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard loaded else { return }   // 초기 drawing 주입에 의한 콜백 무시
            controller?.refresh()          // 스트로크/undo/redo 후 버튼 상태 갱신
            scheduleSave()
        }

        private func scheduleSave() {
            saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.commit() }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }

        @objc func onBackground() { commit() }

        func commit() {
            saveWork?.cancel(); saveWork = nil
            guard loaded, let canvas, pageNum >= 1, !noteId.isEmpty else { return }
            let drawing = canvas.drawing
            if drawing.strokes.isEmpty {
                if let ann = (try? db.pdfAnnotation(noteId: noteId, page: pageNum)) ?? nil, ann.drawingData != nil {
                    try? db.deletePdfAnnotation(noteId: noteId, page: pageNum)
                    appLogDebug("ink", "input delete", ["page": "\(pageNum)"])
                }
            } else {
                let data = drawing.dataRepresentation()
                try? db.savePdfAnnotation(noteId: noteId, page: pageNum, data: data)
                appLogDebug("ink", "input save", ["page": "\(pageNum)", "strokes": "\(drawing.strokes.count)", "bytes": "\(data.count)"])
            }
        }
    }
}

/// 입력 레이어 host 스크롤뷰 — 레이아웃 시점에 fit-zoom/center를 재적용한다.
final class InkHostScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
