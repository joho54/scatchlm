import SwiftUI

/// 피드백 채팅·가이드 채팅 공용 말풍선.
/// **통일 대상은 챗봇(assistant) 응답** — 두 화면의 응답 말풍선을 같은 모양(full-width, `MarkdownContentView`,
/// 회색, 액션 버튼)으로 맞춘다. user 메시지는 통일 대상이 아니며, 우측 정렬·콘텐츠 폭 축소의 단순
/// `Text` 말풍선이다(입력엔 수식/마크다운 렌더가 불필요하고, plain Text라야 안정적으로 보인다).
struct ChatBubbleView<Actions: View>: View {
    let role: String
    let content: String
    @ViewBuilder var actions: () -> Actions

    private var isUser: Bool { role == "user" }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 60)
                Text(content)
                    .font(.system(size: 14))
                    .padding(12)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // preferBake: 채팅 리스트에선 MarkdownUI(중첩 ForEach) 대신 bake 이미지로 — App Hang 방지.
                MarkdownContentView(content: content, preferBake: true)
                Divider()
                HStack(spacing: 12) { actions() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

extension ChatBubbleView where Actions == EmptyView {
    /// 액션 없는 말풍선(user 메시지 등). user는 actions를 쓰지 않는다.
    init(role: String, content: String) {
        self.init(role: role, content: content, actions: { EmptyView() })
    }
}

/// `Equatable` 말풍선 행 — 데이터(role/content/serverId/rating)가 같으면 SwiftUI가 body 재평가를
/// 건너뛴다. 키보드 등장/해제 같은 무관한 트랜잭션마다 N개 버블(이미지 포함)을 통째로 재생성하며
/// 메인 스레드를 막던 App Hang을 차단한다. 액션 클로저는 == 비교에서 제외(매번 새로 생겨도 무시).
struct EquatableChatBubble: View, Equatable {
    let role: String
    let content: String
    var serverId: String? = nil
    var rating: Int? = nil
    var onScrap: (() -> Void)? = nil
    var onRate: ((Int) -> Void)? = nil
    var onDetail: (() -> Void)? = nil

    static func == (l: EquatableChatBubble, r: EquatableChatBubble) -> Bool {
        l.role == r.role && l.content == r.content && l.serverId == r.serverId && l.rating == r.rating
    }

    var body: some View {
        if role == "user" {
            ChatBubbleView(role: role, content: content)
        } else {
            ChatBubbleView(role: role, content: content) {
                if let onScrap {
                    Button { onScrap() } label: {
                        Label("스크랩", systemImage: "pin.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let onRate {
                    Button { onRate(1) } label: {
                        Image(systemName: rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .foregroundStyle(rating == 1 ? Color.green : Color.secondary).font(.caption)
                    }.disabled(serverId == nil)
                    Button { onRate(-1) } label: {
                        Image(systemName: rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .foregroundStyle(rating == -1 ? Color.red : Color.secondary).font(.caption)
                    }.disabled(serverId == nil)
                }
                if let onDetail {
                    Button { onDetail() } label: {
                        Text("자세히").font(.caption).foregroundStyle(.secondary)
                    }.disabled(serverId == nil)
                }
            }
        }
    }
}
