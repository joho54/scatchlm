import SwiftUI

struct FeedbackChatSheet: View {
    let feedback: FeedbackRecord
    var textbookId: String?
    var currentPage: Int?
    var noteId: String?
    var subject: String?
    var onPin: ((String, String?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ChatMessageRecord] = []
    @State private var input = ""
    @State private var sending = false
    @State private var pushedRatingMessageId: String?

    private let db = DatabaseService.shared

    private var parsed: AIResponse? {
        guard let data = feedback.content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIResponse.self, from: data)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            // Original feedback — 평가는 카드에서 하므로 채팅 헤더에서는 미노출
                            chatBubble(
                                role: "assistant",
                                content: parsed?.displayText ?? feedback.content,
                                serverId: feedback.serverFeedbackId,
                                message: nil
                            )
                            .id("original")

                            // Chat history
                            ForEach(messages) { msg in
                                chatBubble(
                                    role: msg.role,
                                    content: msg.content,
                                    serverId: msg.serverMessageId,
                                    message: msg
                                )
                                .id(msg.id)
                            }

                            if sending {
                                HStack {
                                    ProgressView()
                                        .padding(.leading, 16)
                                    Spacer()
                                }
                                .id("loading")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(messages.last?.id ?? "original", anchor: .bottom)
                        }
                    }
                }

                Divider()

                // Input bar
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
            .navigationTitle("피드백 대화")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear { loadMessages() }
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
                    BakedMarkdownView(content: content)

                    Divider()
                    HStack(spacing: 12) {
                        if onPin != nil {
                            Button {
                                onPin?(content, serverId)
                                dismiss()
                            } label: {
                                Label("박제", systemImage: "pin.fill")
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
                                appLog("chat-detail", "tapped", ["msgId": msg.id, "serverId": serverId ?? "nil"])
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
            messages = try db.chatMessages(feedbackId: feedback.id)
            appLog("chat", "loadMessages", ["feedbackId": feedback.id, "count": "\(messages.count)"])
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

        // Save user message locally
        var userMsg = ChatMessageRecord(
            id: UUID().uuidString,
            feedbackId: feedback.id,
            role: "user",
            content: text,
            createdAt: Date(),
            serverMessageId: nil,
            userRating: nil,
            userRatingSyncedAt: nil
        )
        try? db.saveChatMessage(&userMsg)
        messages.append(userMsg)

        // Build history for API
        var history: [[String: String]] = [
            ["role": "assistant", "content": parsed?.displayText ?? feedback.content]
        ]
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
                    parent_feedback_id: feedback.serverFeedbackId
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

                // Save assistant message with server id
                var assistantMsg = ChatMessageRecord(
                    id: UUID().uuidString,
                    feedbackId: feedback.id,
                    role: "assistant",
                    content: res.content,
                    createdAt: Date(),
                    serverMessageId: res.feedback_id,
                    userRating: nil,
                    userRatingSyncedAt: nil
                )
                try? db.saveChatMessage(&assistantMsg)

                await MainActor.run {
                    messages.append(assistantMsg)
                    sending = false
                }
            } catch {
                appLogError("chat", "send failed", ["error": "\(error)"])
                await MainActor.run { sending = false }
            }
        }
    }
}
