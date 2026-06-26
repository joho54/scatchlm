import SwiftUI
import UIKit

/// 피드백 채팅·가이드 채팅 공용 말풍선.
/// **통일 대상은 챗봇(assistant) 응답** — 두 화면의 응답 말풍선을 같은 모양(full-width, `MarkdownContentView`,
/// 회색, 액션 버튼)으로 맞춘다. user 메시지는 통일 대상이 아니며, 우측 정렬·콘텐츠 폭 축소의 단순
/// `Text` 말풍선이다(입력엔 수식/마크다운 렌더가 불필요하고, plain Text라야 안정적으로 보인다).
struct ChatBubbleView<Actions: View>: View {
    let role: String
    let content: String
    var fontSize: CGFloat = 14
    @ViewBuilder var actions: () -> Actions

    private var isUser: Bool { role == "user" }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 60)
                Text(content)
                    .font(.system(size: fontSize))
                    .padding(12)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // preferBake: 채팅 리스트에선 MarkdownUI(중첩 ForEach) 대신 bake 이미지로 — App Hang 방지.
                MarkdownContentView(content: content, fontSize: fontSize, preferBake: true)
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
    init(role: String, content: String, fontSize: CGFloat = 14) {
        self.init(role: role, content: content, fontSize: fontSize, actions: { EmptyView() })
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
    /// 전송 실패한 user 메시지 — 실패 캡션 + 롱홀드 재시도/수정 메뉴.
    var failed: Bool = false
    /// 말풍선 글자 크기. ==에 포함해 사용자가 크기를 바꾸면 버블이 재평가되도록 한다.
    var fontSize: CGFloat = 14
    var onScrap: (() -> Void)? = nil
    var onRate: ((Int) -> Void)? = nil
    var onDetail: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    /// assistant 응답 재생성 — 직전 user 질문을 다시 보내 답변을 새로 받는다(기존 답변 교체).
    /// 마지막 assistant 턴에만 주입한다(중간 턴 재생성은 이후 턴을 고아화하므로 호출부가 막음).
    var onRegenerate: (() -> Void)? = nil

    static func == (l: EquatableChatBubble, r: EquatableChatBubble) -> Bool {
        l.role == r.role && l.content == r.content && l.serverId == r.serverId
            && l.rating == r.rating && l.failed == r.failed && l.fontSize == r.fontSize
    }

    var body: some View {
        bubble.contextMenu {
            Button { UIPasteboard.general.string = content } label: {
                Label("복사", systemImage: "doc.on.doc")
            }
            // 실패 user 버블은 복사와 같은 메뉴에서 재시도/수정도 노출(롱홀드 = SwiftUI 표준).
            if role == "user" && failed {
                if let onRetry {
                    Button { onRetry() } label: { Label("재시도", systemImage: "arrow.clockwise") }
                }
                if let onEdit {
                    Button { onEdit() } label: { Label("수정", systemImage: "pencil") }
                }
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        if role == "user" {
            if failed {
                failedUserBubble
            } else {
                ChatBubbleView(role: role, content: content, fontSize: fontSize)
            }
        } else {
            ChatBubbleView(role: role, content: content, fontSize: fontSize) {
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
                if let onRegenerate {
                    Button { onRegenerate() } label: {
                        Label("재시도", systemImage: "arrow.clockwise")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 전송 실패한 user 말풍선 — 우측 정렬 버블 + 빨간 실패 캡션. 버블을 길게 누르면(상위 contextMenu)
    /// 복사/재시도/수정 메뉴가 뜬다.
    private var failedUserBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ChatBubbleView(role: role, content: content, fontSize: fontSize)
            Button { onRetry?() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(String(localized: "전송 실패 · 길게 눌러 재시도"))
                }
                .font(.caption2)
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}
