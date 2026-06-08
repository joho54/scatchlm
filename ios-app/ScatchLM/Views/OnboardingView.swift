import SwiftUI

/// 가이드된 첫 성공 온보딩 (onboarding-guided-first-success-spec).
///
/// 첫 실행에서 "데모 교재 페이지를 보고 → 손으로 답을 쓰고 → 그 교재 기준 AI 피드백을 받고
/// → 그 피드백 카드로 채팅을 이어가는" 핵심 루프를 **실제 노트 위에서** 직접 체험시킨다.
///
/// 설계: 별도 가짜 캔버스/카드를 만들지 않고 **실제 `NoteView`를 데모 노트로 호스팅**한다.
/// - 진입 시 "연습 노트"를 만들고 데모 교재(`demo-{userId}`)를 attach + PDF 열림 상태로 저장
///   → NoteView가 PDF+캔버스 분할로 열린다.
/// - 필기→✨→피드백 카드(캔버스에 박힘)→카드 탭→채팅이 전부 NoteView의 실제 동작.
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
    @State private var hintVisible = true
    @State private var hintToken = 0          // 증가 시 .task(id:) 재시작 → 자동 숨김 타이머 리셋

    private let db = DatabaseService.shared

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
            Image(systemName: "sparkles")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(String(localized: "30초면 핵심을 보여드릴게요"))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(String(localized: "데모 교재를 보고 손으로 답을 쓰면,\nAI가 그 교재 기준으로 피드백을 드려요.\n그 피드백으로 대화도 이어갈 수 있어요."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
            Spacer().frame(height: 40)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Editor (real NoteView + onboarding bar)

    private var editorStep: some View {
        ZStack(alignment: .top) {
            if noteReady {
                NoteView(noteId: noteId, onFeedbackAppended: {
                    if !gotFeedback {
                        gotFeedback = true
                        withAnimation { hint = .chat }
                    }
                })
            }

            // 상단 중앙: 작은 힌트 — 몇 초 뒤 자동으로 사라져 UI를 가리지 않는다.
            if hintVisible {
                hintPill
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 상단 우측: 항상 보이는 작은 건너뛰기/마치기 칩(하단 컨트롤과 안 겹침).
        .overlay(alignment: .topTrailing) { skipChip }
        .task(id: hintToken) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation { hintVisible = false }
        }
        .onChange(of: hint) { _, _ in
            withAnimation { hintVisible = true }
            hintToken += 1                 // 타이머 리셋 → 채팅 힌트도 4초 뒤 사라짐
        }
    }

    private var hintPill: some View {
        Text(hint == .write
             ? String(localized: "PDF 문제의 답을 캔버스에 쓰고 ✨를 누르세요")
             : String(localized: "피드백 카드를 탭하면 AI와 대화를 이어갈 수 있어요"))
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.8)))
            .foregroundStyle(.white)
            .shadow(radius: 4)
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
            note.textbookName = "ScatchLM 데모 교재.pdf"
            note.textbookPages = 2
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
        withAnimation { step = .editor }
    }

    /// 환영 화면에서 건너뛰기 — 노트를 만들기 전이라 정리할 것 없음.
    private func skip() { completed = true }

    /// 온보딩 종료(마치기/에디터 건너뛰기). 노트는 NoteView가 이미 영속했으므로 첫 노트로 남는다.
    /// 단, 사용자가 아무것도 안 쓴 빈 노트면 정리(클러터 방지).
    private func finish() {
        if noteReady, let note = try? db.note(id: noteId),
           (note.drawingData == nil || note.drawingData?.isEmpty == true) {
            try? db.deleteNote(id: noteId)
            appLog("onboarding", "empty demo note removed", ["noteId": noteId])
        }
        completed = true
    }
}
