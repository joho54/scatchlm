import SwiftUI

/// 채팅 한 턴(표시용 통일 모델). 피드백(ChatMessageRecord)·가이드(GuideChatMessage)가 각각 매핑해 쓴다.
struct ChatTurn: Identifiable {
    let id: String
    let role: String          // "user" | "assistant"
    let content: String
    var serverId: String? = nil
    var rating: Int? = nil
    /// 전송 실패한 user 메시지 — 말풍선에 실패 표시 + 롱홀드 재시도/수정 메뉴를 띄운다.
    var failed: Bool = false
}

/// **통일 채팅 스레드** — 피드백·가이드·챕터 챗이 공유하는 단일 컴포넌트.
/// 메시지 리스트 + 입력바 + 키보드 처리(표준 iMessage `safeAreaInset` 패턴)를 한 곳에 담는다.
/// - 키보드가 입력바(작은 inset)만 밀어 올리고 ScrollView 프레임은 안 줄어, SwiftUI 자동 키보드
///   회피가 LazyVStack 전체를 재레이아웃하던 App Hang을 피한다.
/// - 버블은 `EquatableChatBubble`(데이터 동일 시 재평가 스킵). 헤더(피드백 카드/가이드 본문)는
///   호출부가 `@ViewBuilder header`로 주입. 전송/평가/스크랩 로직은 호출부 콜백.
struct ChatThreadView<Header: View>: View {
    let turns: [ChatTurn]
    @Binding var input: String
    var sending: Bool
    var placeholder: String = "질문을 입력하세요..."

    var onSend: () -> Void
    var onScrap: ((ChatTurn) -> Void)? = nil
    var onRate: ((ChatTurn, Int) -> Void)? = nil
    var onDetail: ((ChatTurn) -> Void)? = nil
    /// 실패한 user 메시지 롱홀드 → 같은 내용으로 재전송.
    var onRetry: ((ChatTurn) -> Void)? = nil
    /// 실패한 user 메시지 롱홀드 → 내용을 입력창으로 되돌리고 실패 버블 제거(수정 후 재전송).
    var onEdit: ((ChatTurn) -> Void)? = nil

    /// 리스트 최상단 헤더(피드백 카드 본문 / 가이드 설명 + 평가 등). 없으면 EmptyView.
    /// 현재 글자 크기(`fontSize`)를 받아 헤더 본문도 함께 키울 수 있게 한다.
    @ViewBuilder var header: (CGFloat) -> Header

    @FocusState private var focused: Bool
    /// 말풍선 글자 크기. 입력바의 글자 크기 메뉴로 조절하며 `Config.chatFontSize`에 영속화한다.
    @State private var fontSize: CGFloat = Config.chatFontSize

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header(fontSize)
                        .id("header")

                    ForEach(turns) { turn in
                        EquatableChatBubble(
                            role: turn.role,
                            content: turn.content,
                            serverId: turn.serverId,
                            rating: turn.rating,
                            failed: turn.failed,
                            fontSize: fontSize,
                            onScrap: onScrap.map { f in { f(turn) } },
                            onRate: turn.role == "user" ? nil : onRate.map { f in { r in f(turn, r) } },
                            onDetail: turn.role == "user" ? nil : onDetail.map { f in { f(turn) } },
                            onRetry: turn.role == "user" ? onRetry.map { f in { f(turn) } } : nil,
                            onEdit: turn.role == "user" ? onEdit.map { f in { f(turn) } } : nil
                        )
                        .equatable()
                        .id(turn.id)
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
            // 스크롤 드래그로 키보드 내림(iMessage 패턴).
            .scrollDismissesKeyboard(.interactively)
            // 메시지 영역 빈 곳 탭 → 키보드 해제. simultaneous라 버블 내 버튼 탭은 막지 않음.
            .simultaneousGesture(TapGesture().onEnded { focused = false })
            .onChange(of: turns.count) { _, _ in
                withAnimation {
                    proxy.scrollTo(turns.last?.id ?? "header", anchor: .bottom)
                }
            }
            // 입력바를 safeAreaInset로 — 키보드 회피가 리스트를 재레이아웃하지 않게(App Hang 차단).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        fontSizeMenu

                        TextField(placeholder, text: $input, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .focused($focused)

                        Button {
                            focused = false
                            onSend()
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
                .background(.bar)
            }
        }
    }

    /// 입력바 좌측 글자 크기 메뉴 — 작게/보통/크게/더 크게/아주 크게 프리셋.
    /// 선택 시 즉시 말풍선·헤더에 반영(@State fontSize)하고 `Config.chatFontSize`에 영속화한다.
    private var fontSizeMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { fontSize },
                set: { fontSize = $0; Config.chatFontSize = $0 }
            )) {
                Text("작게").tag(CGFloat(14))
                Text("보통").tag(CGFloat(16))
                Text("크게").tag(CGFloat(18))
                Text("더 크게").tag(CGFloat(20))
                Text("아주 크게").tag(CGFloat(22))
            } label: {
                Text("글자 크기")
            }
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
    }
}

extension ChatThreadView where Header == EmptyView {
    init(turns: [ChatTurn], input: Binding<String>, sending: Bool,
         placeholder: String = "질문을 입력하세요...",
         onSend: @escaping () -> Void,
         onScrap: ((ChatTurn) -> Void)? = nil,
         onRate: ((ChatTurn, Int) -> Void)? = nil,
         onDetail: ((ChatTurn) -> Void)? = nil,
         onRetry: ((ChatTurn) -> Void)? = nil,
         onEdit: ((ChatTurn) -> Void)? = nil) {
        self.init(turns: turns, input: input, sending: sending, placeholder: placeholder,
                  onSend: onSend, onScrap: onScrap, onRate: onRate, onDetail: onDetail,
                  onRetry: onRetry, onEdit: onEdit,
                  header: { _ in EmptyView() })
    }
}
