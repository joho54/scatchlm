import SwiftUI

/// 입력바 '연습문제' 퀵액션이 보내는 고정 프롬프트.
/// 가이드(=채팅) 안에서 읽기→필기 다리를 한 탭으로 잇기 위한 것 — 유저가 매번 직접 치던
/// "간단한 연습문제 내줘" 발화를 결정론적 버튼으로 치환한다. 호스트는 이 프롬프트를 전송하고
/// 응답을 자동으로 캔버스에 스크랩(onPin)한다.
enum ChatQuickAction {
    static let practicePrompt = String(localized: "방금 내용으로 간단한 연습문제를 내줘")
}

/// 채팅 한 턴(표시용 통일 모델). 피드백(ChatMessageRecord)·가이드(GuideChatMessage)가 각각 매핑해 쓴다.
struct ChatTurn: Identifiable {
    let id: String
    let role: String          // "user" | "assistant"
    let content: String
    var serverId: String? = nil
    var rating: Int? = nil
    /// 전송 실패한 user 메시지 — 말풍선에 실패 표시 + 롱홀드 재시도/수정 메뉴를 띄운다.
    var failed: Bool = false
    /// assistant 응답의 LLM 인출 단서 — 버블 하단 #해시태그 표시.
    var keywords: [String] = []
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
    /// 입력바 '연습문제' 퀵액션 — 고정 프롬프트(`ChatQuickAction.practicePrompt`)를 전송하고
    /// 응답을 자동으로 캔버스에 스크랩한다. 스크랩 대상(캔버스)이 있는 호스트만 주입한다.
    var onQuickPractice: (() -> Void)? = nil

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
                            keywords: turn.keywords,
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
                        if let onQuickPractice {
                            Button(action: onQuickPractice) {
                                Label("연습문제", systemImage: "pencil.and.list.clipboard")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(.blue)
                            .disabled(sending)
                        }

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
}

extension ChatThreadView where Header == EmptyView {
    init(turns: [ChatTurn], input: Binding<String>, sending: Bool,
         placeholder: String = "질문을 입력하세요...",
         onSend: @escaping () -> Void,
         onScrap: ((ChatTurn) -> Void)? = nil,
         onRate: ((ChatTurn, Int) -> Void)? = nil,
         onDetail: ((ChatTurn) -> Void)? = nil,
         onRetry: ((ChatTurn) -> Void)? = nil,
         onEdit: ((ChatTurn) -> Void)? = nil,
         onQuickPractice: (() -> Void)? = nil) {
        self.init(turns: turns, input: input, sending: sending, placeholder: placeholder,
                  onSend: onSend, onScrap: onScrap, onRate: onRate, onDetail: onDetail,
                  onRetry: onRetry, onEdit: onEdit, onQuickPractice: onQuickPractice,
                  header: { _ in EmptyView() })
    }
}
