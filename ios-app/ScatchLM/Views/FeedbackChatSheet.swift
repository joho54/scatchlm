import SwiftUI
import MarkdownUI

struct FeedbackChatSheet: View {
    let feedback: FeedbackRecord
    var textbookId: String?
    var currentPage: Int?
    var onPin: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ChatMessageRecord] = []
    @State private var input = ""
    @State private var sending = false

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
                            // Original feedback
                            chatBubble(role: "assistant", content: parsed?.displayText ?? feedback.content)
                                .id("original")

                            // Chat history
                            ForEach(messages) { msg in
                                chatBubble(role: msg.role, content: msg.content)
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
        }
    }

    @ViewBuilder
    private func chatBubble(role: String, content: String) -> some View {
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
                    Markdown(content)
                        .markdownTextStyle {
                            FontSize(14)
                        }
                    if onPin != nil {
                        Divider()
                        Button {
                            onPin?(content)
                            dismiss()
                        } label: {
                            Label("캔버스에 박제", systemImage: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            createdAt: Date()
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
                    let textbook_id: String?
                    let current_page: Int?
                }
                struct ChatRes: Decodable {
                    let content: String
                }

                let reqBody = ChatReq(
                    message: text,
                    history: history.dropLast().map { $0 },
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

                // Save assistant message
                var assistantMsg = ChatMessageRecord(
                    id: UUID().uuidString,
                    feedbackId: feedback.id,
                    role: "assistant",
                    content: res.content,
                    createdAt: Date()
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
