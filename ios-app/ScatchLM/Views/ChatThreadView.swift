import SwiftUI

/// 입력바 '연습문제' 퀵액션이 보내는 고정 프롬프트.
/// 가이드(=채팅) 안에서 읽기→필기 다리를 한 탭으로 잇기 위한 것 — 유저가 매번 직접 치던
/// "간단한 연습문제 내줘" 발화를 결정론적 버튼으로 치환한다. 호스트는 이 프롬프트를 전송하고
/// 응답을 자동으로 캔버스에 스크랩(onPin)한다.
enum ChatQuickAction {
    static let practicePrompt = String(localized: "방금 내용으로 간단한 연습문제를 내줘")
    /// PDF 필기 모드 하단 바 '필기 질문' 퀵액션이 보내는 고정 프롬프트.
    /// 방금 쓴 필기(페이지+잉크 합성 이미지가 자동 첨부됨)에 대해 한 탭으로 AI에게 물어본다.
    static let handwritingPrompt = String(localized: "내가 방금 필기한 내용을 봐줘")
    /// PDF 라이브(읽기) 모드에서 본문을 드래그 선택한 뒤 '선택 질문' 버튼이 보내는 고정 프롬프트.
    /// 선택한 구절은 selected_text로 백엔드에 함께 전달돼 "이 부분"의 실체가 된다.
    static let selectionPrompt = String(localized: "선택한 부분을 설명해줘")
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
    /// assistant 응답 '재시도' → 직전 user 질문을 다시 보내 답변을 새로 받는다(기존 답변 교체).
    /// 마지막 assistant 턴에만 노출한다(중간 턴 재생성은 이후 턴을 고아화).
    var onRegenerate: ((ChatTurn) -> Void)? = nil
    /// 입력바 '연습문제' 퀵액션 — 고정 프롬프트(`ChatQuickAction.practicePrompt`)를 전송하고
    /// 응답을 자동으로 캔버스에 스크랩한다. 스크랩 대상(캔버스)이 있는 호스트만 주입한다.
    var onQuickPractice: (() -> Void)? = nil

    /// 리스트 최상단 헤더(피드백 카드 본문 / 가이드 설명 + 평가 등). 없으면 EmptyView.
    /// 현재 글자 크기(`fontSize`)를 받아 헤더 본문도 함께 키울 수 있게 한다.
    @ViewBuilder var header: (CGFloat) -> Header

    @FocusState private var focused: Bool
    /// 말풍선 글자 크기. 입력바의 글자 크기 메뉴로 조절하며 `Config.chatFontSize`에 영속화한다.
    @State private var fontSize: CGFloat = Config.chatFontSize

    /// 맨 아래 스크롤 타깃 — 전송 중이면 로딩 인디케이터, 아니면 마지막 턴(없으면 헤더).
    private var scrollAnchor: String {
        if sending { return "loading" }
        return turns.last?.id ?? "header"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header(fontSize)
                        .id("header")

                    ForEach(turns) { turn in
                        // 재시도(재생성)는 '마지막 assistant 턴'에만 — 중간 턴 재생성 시 이후 턴이 고아가 됨.
                        let isLastAssistant = turn.role == "assistant" && turn.id == turns.last?.id
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
                            onEdit: turn.role == "user" ? onEdit.map { f in { f(turn) } } : nil,
                            onRegenerate: isLastAssistant ? onRegenerate.map { f in { f(turn) } } : nil
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
                    proxy.scrollTo(scrollAnchor, anchor: .bottom)
                }
            }
            // 시트가 처음 뜰 때 맨 아래로 — 퀵액션(선택/필기 질문)은 시트 표시 *전에* user 메시지를
            // 동기로 append하므로 turns.count가 변하지 않아 위 onChange가 안 탄다. LazyVStack 레이아웃
            // 이후 스크롤되도록 다음 런루프로 미룬다(onAppear 시점엔 셀이 아직 배치 전).
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(scrollAnchor, anchor: .bottom)
                }
            }
            // 로딩 인디케이터 등장/소멸 시에도 따라 내려가 응답 진행 상태가 늘 보이게.
            .onChange(of: sending) { _, _ in
                withAnimation {
                    proxy.scrollTo(scrollAnchor, anchor: .bottom)
                }
            }
            // 입력바를 safeAreaInset로 — 키보드 회피가 리스트를 재레이아웃하지 않게(App Hang 차단).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // GPT풍 입력바 — 하드 Divider 없이 .bar 머티리얼로 자연스럽게 분리하고,
                // TextField와 전송 버튼을 하나의 둥근 pill 안에 담는다(전송 = pill 내부 우하단 원형).
                HStack(alignment: .bottom, spacing: 8) {
                    if let onQuickPractice {
                        Button(action: onQuickPractice) {
                            Label("연습문제", systemImage: "pencil.and.list.clipboard")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .disabled(sending)
                    }

                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(placeholder, text: $input, axis: .vertical)
                            .lineLimit(1...5)
                            .focused($focused)
                            .padding(.leading, 14)
                            .padding(.vertical, 9)

                        Button {
                            focused = false
                            onSend()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(
                                    input.isEmpty || sending ? Color.gray.opacity(0.4) : Color.blue,
                                    in: Circle()
                                )
                        }
                        .disabled(input.isEmpty || sending)
                        .padding(.trailing, 5)
                        .padding(.bottom, 4)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
         onRegenerate: ((ChatTurn) -> Void)? = nil,
         onQuickPractice: (() -> Void)? = nil) {
        self.init(turns: turns, input: input, sending: sending, placeholder: placeholder,
                  onSend: onSend, onScrap: onScrap, onRate: onRate, onDetail: onDetail,
                  onRetry: onRetry, onEdit: onEdit, onRegenerate: onRegenerate,
                  onQuickPractice: onQuickPractice,
                  header: { _ in EmptyView() })
    }
}
