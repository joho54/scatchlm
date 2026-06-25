import SwiftUI

/// 위젯 딥링크(`scatchlm://session/<id>?note=<noteId>`) 라우팅.
///
/// 콜드런치 대응: onOpenURL은 인증·DB 준비보다 먼저 fire될 수 있다. 그래서 여기선 intent를
/// 단순 stash만 하고, 실제 세션 조회·표시는 인증된 서브트리에 붙은 시트가 준비된 뒤
/// `WidgetSessionLoader`가 DB가 채워질 때까지 짧게 폴링하며 처리한다(고정 딜레이 금지).
@Observable
final class DeepLinkRouter {
    var pending: PendingSession?

    /// 위젯에서 들어온 URL을 파싱해 pending intent로 저장한다.
    func handle(_ url: URL) {
        guard url.scheme == WidgetShared.urlScheme else { return }
        switch url.host {
        case "session":
            // scatchlm://session/<sessionId>?note=<noteId>
            let sessionId = url.lastPathComponent
            guard !sessionId.isEmpty, sessionId != "session" else { return }
            let note = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "note" })?.value
            pending = PendingSession(id: sessionId, noteId: note)
            appLog("deeplink", "session intent", ["session": sessionId])
        case "note":
            // 레거시/세션 없는 단서 — 정밀 점프 불가. 현재는 앱을 전면으로 가져오는 것까지만.
            appLog("deeplink", "note intent (no jump)", ["note": url.lastPathComponent])
        default:
            appLog("deeplink", "unknown url", ["url": url.absoluteString])
        }
    }
}

struct PendingSession: Identifiable, Equatable {
    let id: String        // sessionId
    let noteId: String?
}

/// 위젯 딥링크로 세션 시트를 루트에서 여는 로더.
///
/// 콜드런치 시 DB의 현재 유저(scopedUserId)가 아직 주입되지 않았을 수 있어, 세션이 조회될
/// 때까지 짧게 폴링한다. 조회되면 `SessionChatSheet`를 onPin 없이 띄운다(스크랩/연습문제 버튼
/// 자동 숨김 — 위젯 진입은 읽기·대화 전용, PhoneNoteReaderView와 동일 패턴).
struct WidgetSessionLoader: View {
    let pending: PendingSession
    let onClose: () -> Void

    @State private var resolved: Resolved?
    @State private var failed = false
    private let db = DatabaseService.shared

    private enum Resolved {
        case found(session: ChatSessionRecord, header: String?, headerServerId: String?)
    }

    var body: some View {
        Group {
            if case let .found(session, header, headerServerId) = resolved {
                SessionChatSheet(
                    session: session,
                    headerContent: header,
                    headerServerId: headerServerId,
                    textbookId: session.textbookId,
                    currentPage: session.anchorPage,
                    noteId: pending.noteId,
                    subject: nil
                    // onPin 미전달 → 캔버스 스크랩/연습문제 버튼 자동 숨김
                )
            } else if failed {
                notFound
            } else {
                ProgressView("불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: pending.id) { await resolve() }
    }

    private var notFound: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("대화를 찾지 못했어요.")
                .font(.headline)
            Text("동기화가 끝나지 않았거나 삭제된 대화일 수 있어요.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("닫기") { onClose() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// DB가 준비될 때까지 최대 ~3초 폴링하며 세션을 조회한다.
    private func resolve() async {
        for attempt in 0..<20 {
            if let session = try? db.session(id: pending.id) {
                let fb = db.feedbackForSession(pending.id)
                resolved = .found(session: session, header: fb?.content, headerServerId: fb?.serverFeedbackId)
                appLog("deeplink", "session resolved", ["session": pending.id, "attempt": "\(attempt)"])
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)   // 150ms
        }
        appLogWarn("deeplink", "session not found", ["session": pending.id])
        failed = true
    }
}
