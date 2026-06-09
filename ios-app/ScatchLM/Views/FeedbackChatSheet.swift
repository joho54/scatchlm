import SwiftUI

/// 세션 기반 채팅 시트 (chapter-chat-drawer-spec §4.4).
/// 피드백 카드·가이드 채팅·드로어가 모두 이 한 뷰로 진입한다. 데이터는 `session_id` 종속.
///
/// `headerContent`는 메시지로 저장되지 않은 원본 본문(피드백 카드 body 등)을 헤더 버블로
/// 보여줄 때만 쓴다. 가이드 세션은 본문이 message[0]로 영속화되므로 headerContent=nil이다.
struct SessionChatSheet: View {
    let session: ChatSessionRecord
    var headerContent: String?
    var headerServerId: String?
    var textbookId: String?
    var currentPage: Int?
    var noteId: String?
    var subject: String?
    /// 온보딩 전용 — 상단에 "스크랩→필기·피드백 루프" 안내 배너를 띄운다. 일반 진입은 false.
    var showScrapHint: Bool = false
    var onPin: ((String, String?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ChatMessageRecord] = []
    @State private var input = ""
    @State private var sending = false
    @State private var pushedRatingMessageId: String?
    @State private var errorMessage: String?
    @State private var scrapHintDismissed = false   // 온보딩 스크랩 안내 카드 닫힘.

    private let db = DatabaseService.shared

    /// headerContent가 AIResponse JSON일 수 있으니 표시용 텍스트로 파싱(아니면 원문).
    private var headerDisplay: String? {
        guard let headerContent else { return nil }
        if let data = headerContent.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(AIResponse.self, from: data) {
            return parsed.displayText
        }
        return headerContent
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let headerDisplay {
                                chatBubble(role: "assistant", content: headerDisplay,
                                           serverId: headerServerId, message: nil)
                                    .id("header")
                            }

                            ForEach(messages) { msg in
                                chatBubble(role: msg.role, content: msg.content,
                                           serverId: msg.serverMessageId, message: msg)
                                    .id(msg.id)
                            }

                            if sending {
                                HStack {
                                    ProgressView().padding(.leading, 16)
                                    Spacer()
                                }
                                .id("loading")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(messages.last?.id ?? "header", anchor: .bottom)
                        }
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    TextField("질문을 입력하세요...", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(input.isEmpty || sending ? .gray : .blue)
                    }
                    .disabled(input.isEmpty || sending)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .overlay(alignment: .top) {
                if showScrapHint && !scrapHintDismissed {
                    scrapHintCard
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle(session.title.isEmpty ? String(localized: "대화") : session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear { loadMessages() }
            .alert("알림", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .navigationDestination(isPresented: Binding(
                get: { pushedRatingMessageId != nil },
                set: { if !$0 { pushedRatingMessageId = nil } }
            )) {
                if let msgId = pushedRatingMessageId,
                   let msg = messages.first(where: { $0.id == msgId }),
                   let serverId = msg.serverMessageId {
                    RatingFormView(
                        feedbackId: serverId,
                        initialRating: msg.userRating ?? 1
                    ) { rating, tags, comment in
                        submitMessageRating(message: msg, rating: rating, reasonTags: tags, comment: comment)
                    }
                }
            }
        }
    }

    /// 온보딩 스크랩 안내 카드 — 답변 아래 '스크랩' 버튼을 가리켜 "캔버스로 가져와 필기·피드백을
    /// 이어가는" 루프를 알린다. 캔버스의 write/chat 안내(OnboardingView.hintCard)와 같은
    /// 검은 플로팅 카드 스타일로 통일한다.
    private var scrapHintCard: some View {
        VStack(spacing: 12) {
            Label {
                Text(String(localized: "대화 내용은 ‘스크랩’으로 캔버스에 다시 가져올 수 있어요"))
                    .font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: "pin.fill")
                    .font(.title3)
            }
            Text(String(localized: "스크랩한 내용 위에 다시 필기하고 ✨로 피드백을 이어가면 학습 루프가 완성돼요"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button { withAnimation { scrapHintDismissed = true } } label: {
                Text(String(localized: "확인"))
                    .font(.headline).frame(maxWidth: 200).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .padding(20)
        .frame(maxWidth: 480)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.85)))
        .foregroundStyle(.white)
        .shadow(radius: 10)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func chatBubble(role: String, content: String, serverId: String?, message: ChatMessageRecord?) -> some View {
        let isUser = role == "user"
        HStack {
            if isUser { Spacer(minLength: 60) }

            if isUser {
                Text(content)
                    .font(.system(size: 14))
                    .padding(12)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownContentView(content: content)

                    Divider()
                    HStack(spacing: 12) {
                        if onPin != nil {
                            Button {
                                onPin?(content, serverId)
                                dismiss()
                            } label: {
                                Label("스크랩", systemImage: "pin.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let msg = message {
                            Button {
                                submitMessageRating(message: msg, rating: 1, reasonTags: [], comment: nil)
                            } label: {
                                Image(systemName: msg.userRating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    .foregroundStyle(msg.userRating == 1 ? Color.green : Color.secondary)
                                    .font(.caption)
                            }
                            .disabled(serverId == nil)

                            Button {
                                submitMessageRating(message: msg, rating: -1, reasonTags: [], comment: nil)
                            } label: {
                                Image(systemName: msg.userRating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                    .foregroundStyle(msg.userRating == -1 ? Color.red : Color.secondary)
                                    .font(.caption)
                            }
                            .disabled(serverId == nil)

                            Button {
                                pushedRatingMessageId = msg.id
                            } label: {
                                Text("자세히")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .disabled(serverId == nil)
                        }
                    }
                }
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }

    private func loadMessages() {
        do {
            messages = try db.messages(sessionId: session.id)
            appLog("chat", "loadMessages", ["sessionId": session.id, "count": "\(messages.count)"])
        } catch {
            appLogError("chat", "loadMessages failed", ["error": "\(error)"])
        }
    }

    private func submitMessageRating(message msg: ChatMessageRecord, rating: Int, reasonTags: [String], comment: String?) {
        guard let serverId = msg.serverMessageId else { return }
        if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
            messages[idx].userRating = rating
        }
        try? db.updateChatMessageRating(id: msg.id, rating: rating, syncedAt: nil)

        Task {
            do {
                var body: [String: Any] = ["rating": rating, "reason_tags": reasonTags]
                if let comment { body["comment"] = comment }
                try await APIClient.shared.postJSONNoContent("/feedback/\(serverId)/rate", body: body)
                try? db.updateChatMessageRating(id: msg.id, rating: rating, syncedAt: Date())
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    messages[idx].userRatingSyncedAt = Date()
                }
                appLog("rating", "chat synced", ["server": serverId, "rating": "\(rating)"])
            } catch {
                appLogError("rating", "chat sync failed", ["server": serverId, "error": "\(error)"])
            }
        }
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        sending = true

        var userMsg = ChatMessageRecord(
            id: UUID().uuidString,
            sessionId: session.id,
            role: "user",
            content: text,
            createdAt: Date()
        )
        do {
            try db.saveChatMessage(&userMsg)
            // 세션 제목이 비어 있으면 첫 user 질문으로 세팅 (결정 2).
            try db.setSessionTitleIfEmpty(sessionId: session.id, title: text)
        } catch {
            appLogError("chat", "saveChatMessage(user) failed", ["error": "\(error)"])
            errorMessage = String(localized: "메시지를 저장하지 못했어요.")
            sending = false
            return
        }
        messages.append(userMsg)

        // history: 헤더 본문(있으면) + 세션 메시지. 가이드 세션은 본문이 messages[0]에 이미 있음.
        var history: [[String: String]] = []
        if let headerDisplay {
            history.append(["role": "assistant", "content": headerDisplay])
        }
        for msg in messages {
            history.append(["role": msg.role, "content": msg.content])
        }

        Task {
            do {
                struct ChatReq: Encodable {
                    let message: String
                    let history: [[String: String]]
                    let response_language: String
                    let subject: String?
                    let textbook_id: String?
                    let current_page: Int?
                    let note_id: String?
                    let parent_feedback_id: String?
                }
                struct ChatRes: Decodable {
                    let content: String
                    let feedback_id: String?
                }

                let reqBody = ChatReq(
                    message: text,
                    history: history.dropLast().map { $0 },
                    response_language: Config.responseLanguage,
                    subject: subject,
                    textbook_id: textbookId,
                    current_page: currentPage,
                    note_id: noteId,
                    parent_feedback_id: session.sourceFeedbackId ?? headerServerId
                )

                let res: ChatRes = try await APIClient.shared.postCodable("/feedback/chat", body: reqBody)

                var assistantMsg = ChatMessageRecord(
                    id: UUID().uuidString,
                    sessionId: session.id,
                    role: "assistant",
                    content: res.content,
                    createdAt: Date(),
                    serverMessageId: res.feedback_id
                )
                do {
                    try db.saveChatMessage(&assistantMsg)
                } catch {
                    appLogError("chat", "saveChatMessage(assistant) failed", ["error": "\(error)"])
                }

                await MainActor.run {
                    messages.append(assistantMsg)
                    sending = false
                }
            } catch {
                appLogError("chat", "send failed", ["error": "\(error)"])
                await MainActor.run {
                    if case APIError.quotaExceeded = error {
                        errorMessage = String(localized: "오늘 사용량을 모두 사용했어요. 내일 다시 시도해 주세요.")
                    } else {
                        errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "답변을 받지 못했어요. 잠시 후 다시 시도해 주세요.")
                    }
                    sending = false
                }
            }
        }
    }
}
