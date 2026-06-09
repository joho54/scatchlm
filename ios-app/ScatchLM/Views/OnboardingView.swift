import SwiftUI

/// 가이드된 첫 성공 온보딩 (onboarding-guided-first-success-spec).
///
/// 첫 실행에서 "데모 교재 페이지를 보고 → 손으로 답을 쓰고 → 그 교재 기준 AI 피드백을 받고
/// → 그 피드백 카드로 채팅을 이어가는" 핵심 루프를 **실제 노트 위에서** 직접 체험시킨다.
///
/// 설계: 별도 가짜 캔버스/카드를 만들지 않고 **실제 `NoteView`를 데모 노트로 호스팅**한다.
/// - 진입 시 "연습 노트"를 만들고 데모 교재(`demo-{userId}`)를 attach + PDF 열림 상태로 저장
///   → NoteView가 PDF+캔버스 분할로 열린다.
/// - 필기→✨→피드백 카드(캔버스에 박힘)→카드의 '대화' 버튼→채팅이 전부 NoteView의 실제 동작.
/// - 백엔드는 self-heal: PDF/피드백 요청의 인증 의존성(`_ensure_user_exists`)이 데모 교재
///   딥카피를 먼저 보장한 뒤 핸들러가 동작하므로 첫 호출부터 정상.
/// - 온보딩은 그 위에 **하단 안내 바**(가이드 문구 + 항상 보이는 건너뛰기/마치기)만 얹는다.
struct OnboardingView: View {
    /// 완료/건너뛰기 시 true → 호스트(ScatchLMApp)의 fullScreenCover dismiss.
    @Binding var completed: Bool

    private enum Step { case welcome, editor }
    private enum Hint { case write, chat }

    @State private var step: Step = .welcome
    @State private var noteId: String = UUID().uuidString
    @State private var noteReady = false
    @State private var hint: Hint = .write
    @State private var gotFeedback = false
    @State private var hintVisible = true     // 안내 카드 노출. '확인'으로 닫고, 피드백 시 다시 표시.
    @State private var welcomeTextIn = false   // 로고 인트로 완료 후 텍스트/버튼 페이드인.
    @State private var welcomeLogged = false    // onboardingShown 세션당 1회 가드.

    private let db = DatabaseService.shared

    // 데모 교재 메타 — 백엔드 정적 에셋(app/assets/demo-template.pdf)과 짝. 정식 PDF로 교체 시,
    // 페이지 수가 다르면 이 값만 맞추면 된다(백엔드 total_pages는 PDF에서 자동 추출).
    private static let demoTextbookName = "ScatchLM 데모 교재.pdf"
    private static let demoTextbookPages = 2

    var body: some View {
        Group {
            switch step {
            case .welcome: welcomeStep
            case .editor:  editorStep
            }
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            LogoIntroView(size: 140)
            Text(String(localized: "30초면 핵심을 보여드릴게요"))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .opacity(welcomeTextIn ? 1 : 0)
                .offset(y: welcomeTextIn ? 0 : 10)
            Text(String(localized: "데모 교재를 보고 손으로 답을 쓰면,\nAI가 그 교재 기준으로 피드백을 드려요.\n그 피드백으로 대화도 이어갈 수 있어요."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .opacity(welcomeTextIn ? 1 : 0)
                .offset(y: welcomeTextIn ? 0 : 10)
            Spacer()
            VStack(spacing: 8) {
                Button {
                    startEditor()
                } label: {
                    Text(String(localized: "시작"))
                        .font(.headline).frame(maxWidth: 320).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                // 건너뛰기 — 기본(시작) 버튼 바로 밑.
                Button(String(localized: "건너뛰기")) { skip() }
                    .font(.body)
                    .frame(maxWidth: 320)
            }
            .opacity(welcomeTextIn ? 1 : 0)
            .offset(y: welcomeTextIn ? 0 : 10)
            Spacer().frame(height: 40)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // 텍스트·버튼은 로고 모션 완료를 기다리지 않고 곧바로(짧은 페이드) 노출 →
        // 급한 유저는 인트로를 보는 동안에도 바로 '시작'할 수 있다(퍼널 마찰 제거).
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.35)) { welcomeTextIn = true }
            if !welcomeLogged { welcomeLogged = true; track(.onboardingShown, .ok) }
        }
    }

    // MARK: - Editor (real NoteView + onboarding bar)

    private var editorStep: some View {
        ZStack(alignment: .top) {
            if noteReady {
                NoteView(noteId: noteId, onFeedbackAppended: {
                    if !gotFeedback {
                        gotFeedback = true
                        withAnimation { hint = .chat; hintVisible = true }   // 채팅 안내 재노출
                    }
                }, onChatOpened: {
                    // '대화'를 누르면 캔버스의 채팅 안내 자막은 알아서 꺼진다.
                    // 스크랩 안내는 채팅 시트 안 배너(showChatScrapHint)로 이어서 노출된다.
                    withAnimation { hintVisible = false }
                }, showChatScrapHint: true)
                // 진동 픽스 검증: NoteView가 온보딩 경로(HomeView path 우회)로 떴음을 표시.
                .onAppear { appLog("boot", "noteview mount", ["via": "onboarding"]) }
            }

            // 상단 중앙: 크고 잘 보이는 안내 카드. '확인'을 누르면 사라져 UI를 안 가린다.
            if hintVisible {
                hintCard
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 상단 우측: 항상 보이는 작은 건너뛰기/마치기 칩(하단 컨트롤과 안 겹침).
        .overlay(alignment: .topTrailing) { skipChip }
    }

    private var hintTitle: String {
        switch hint {
        case .write: return String(localized: "PDF 문제의 답을 캔버스에 손글씨로 써보세요")
        case .chat:  return String(localized: "피드백 카드의 ‘대화’ 버튼으로 AI와 대화를 이어갈 수 있어요")
        }
    }

    private var hintSubtitle: String {
        switch hint {
        case .write: return String(localized: "다 쓰면 ✨ 버튼을 눌러 교재 기준 AI 피드백을 받으세요")
        case .chat:  return String(localized: "피드백 카드 아래 💬 ‘대화’ 버튼을 눌러보세요")
        }
    }

    private var hintIcon: String {
        switch hint {
        case .write: return "pencil.and.outline"
        case .chat:  return "bubble.left.and.text.bubble.right.fill"
        }
    }

    private var hintCard: some View {
        VStack(spacing: 12) {
            Label {
                Text(hintTitle)
                    .font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: hintIcon)
                    .font(.title3)
            }
            Text(hintSubtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button { withAnimation { hintVisible = false } } label: {
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

    private var skipChip: some View {
        Button { finish() } label: {
            Text(gotFeedback ? String(localized: "마치기") : String(localized: "건너뛰기"))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .foregroundStyle(.white)
        }
        .padding(.top, 10).padding(.trailing, 12)
    }

    // MARK: - Logic

    /// 데모 노트 생성 + 데모 교재 attach + PDF 열림으로 저장한 뒤 실제 NoteView를 연다.
    private func startEditor() {
        var note = Note.new(title: String(localized: "연습 노트"))
        noteId = note.id
        let userId = AuthService.shared.syncUserId ?? ""
        if !userId.isEmpty {
            note.textbookId = "demo-\(userId)"
            note.textbookName = Self.demoTextbookName
            note.textbookPages = Self.demoTextbookPages
            note.pdfOpen = true
            note.lastPage = 1
        }
        do {
            try db.saveNote(&note)
            noteReady = true
            appLog("onboarding", "demo note created", ["noteId": noteId, "textbook": note.textbookId ?? "nil"])
        } catch {
            appLogError("onboarding", "demo note create failed", ["error": "\(error)"])
        }
        track(.onboardingStart, .ok)
        withAnimation { step = .editor }
    }

    /// 환영 화면에서 건너뛰기 — 노트를 만들기 전이라 정리할 것 없음.
    private func skip() { track(.onboardingSkip, .ok); completed = true }

    /// 온보딩 종료(마치기/에디터 건너뛰기). 노트는 NoteView가 이미 영속했으므로 첫 노트로 남는다.
    /// 단, 사용자가 아무것도 안 쓴 빈 노트면 정리(클러터 방지).
    private func finish() {
        if noteReady, let note = try? db.note(id: noteId),
           (note.drawingData == nil || note.drawingData?.isEmpty == true) {
            try? db.deleteNote(id: noteId)
            appLog("onboarding", "empty demo note removed", ["noteId": noteId])
        }
        track(.onboardingFinish, .ok, ["gotFeedback": gotFeedback])
        completed = true
    }
}
