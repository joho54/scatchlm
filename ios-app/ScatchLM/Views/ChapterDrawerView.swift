import SwiftUI

/// 챕터 채팅 드로어 (chapter-chat-drawer-spec §4.3 / Track B).
/// 노트 툴바에서 진입. 이 노트·교재에 귀속된 세션을 교재 챕터별로 묶어 보여준다.
/// - 세션 행 탭 → 세션 채팅 열기(이어가기)
/// - 캔버스로 점프 (placement 있으면)
/// - 캔버스로 스크랩 (placement 신규 생성 = 저장과 분리된 배치)
struct ChapterDrawerView: View {
    let noteId: String
    let textbookId: String?
    var subject: String?
    /// 드로어 → 캔버스 점프(placement 카드 위치로 이동). NoteView가 네비게이션·dismiss 처리.
    var onJump: (FeedbackRecord) -> Void
    /// 서랍에서 연 채팅의 **개별 메시지** 스크랩(pin). NoteView의 pinToCanvas로 연결.
    /// (세션 통째 스크랩은 제공하지 않는다 — 긴 대화를 캔버스에 올릴 필요가 없음.)
    var onPin: ((String, String?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ChatSessionRecord] = []
    @State private var chapters: [ChapterItem] = []
    @State private var placements: [String: FeedbackRecord] = [:]
    @State private var chatContext: ChatSheetContext?
    @State private var loading = true

    private let db = DatabaseService.shared

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    ContentUnavailableView(
                        String(localized: "저장된 대화가 없어요"),
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("가이드·피드백 대화를 시작하면 여기에 챕터별로 모여요.")
                    )
                } else {
                    List {
                        ForEach(sections) { section in
                            Section(section.title) {
                                ForEach(section.sessions) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("챕터 대화")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(item: $chatContext) { ctx in
                SessionChatSheet(
                    session: ctx.session,
                    headerContent: ctx.headerContent,
                    headerServerId: ctx.headerServerId,
                    textbookId: ctx.session.textbookId ?? textbookId,
                    currentPage: ctx.session.anchorPage,
                    noteId: noteId,
                    subject: subject,
                    onPin: onPin
                )
            }
        }
        // 명시적 '닫기' 버튼으로만 닫는다 — 스와이프/바깥 탭 비활성화.
        .interactiveDismissDisabled(true)
    }

    // MARK: - Row

    @ViewBuilder
    private func sessionRow(_ session: ChatSessionRecord) -> some View {
        let placement = placements[session.id]
        // 행 탭 → 채팅 열기(개별 메시지 보기·스크랩). 세션 통째 스크랩은 없음.
        Button {
            openSession(session)
        } label: {
            HStack(spacing: 10) {
                kindBadge(session.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(session))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(Self.relative.localizedString(for: session.updatedAt, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // 캔버스에 이 세션의 카드가 있으면 표시(점프는 스와이프).
                if placement != nil {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 점프(캔버스 카드 위치로 이동)는 캔버스 위치 스크롤(읽기 행위)이라 iPhone 읽기 전용
        // 리더에서도 허용한다. iPhone은 `PhoneNoteReaderView`의 onJump이 TabView 페이지 전환 +
        // 해당 페이지 `ReadOnlyNoteCanvas`를 fb.positionY로 스크롤한다(좌표계는 편집 캔버스와 동일).
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let placement {
                Button {
                    onJump(placement)
                } label: {
                    Label("점프", systemImage: "scope")
                }
                .tint(.orange)
            }
        }
    }

    @ViewBuilder
    private func kindBadge(_ kind: String) -> some View {
        let (label, color): (String, Color) = {
            switch ChatSessionRecord.Kind(rawValue: kind) {
            case .pageGuide: return (String(localized: "페이지"), .green)
            case .chapterGuide: return (String(localized: "챕터"), .purple)
            case .feedback, .none: return (String(localized: "피드백"), .blue)
            }
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func displayTitle(_ session: ChatSessionRecord) -> String {
        if !session.title.isEmpty { return session.title }
        switch ChatSessionRecord.Kind(rawValue: session.kind) {
        case .feedback, .none: return String(localized: "피드백 대화")
        default: return String(localized: "가이드 대화")
        }
    }

    // MARK: - 챕터 그룹핑

    private struct DrawerSection: Identifiable {
        let id: String
        let title: String
        let sortKey: Int
        let sessions: [ChatSessionRecord]
    }

    /// anchorPage를 챕터에 매핑해 섹션으로 묶는다. 매칭 실패 시 chapter_title 스냅샷 또는 "기타"(§4.2).
    private var sections: [DrawerSection] {
        var bucket: [String: [ChatSessionRecord]] = [:]
        var meta: [String: (title: String, sort: Int)] = [:]
        for s in sessions {
            var key = "__other__"
            var title = String(localized: "기타")
            var sort = Int.max
            if let page = s.anchorPage, let ch = ChapterItem.narrowest(for: page, in: chapters) {
                key = "ch:\(ch.id)"; title = ch.title; sort = ch.pageStart
            } else if let snap = s.chapterTitle, !snap.isEmpty {
                key = "snap:\(snap)"; title = snap; sort = Int.max - 1
            }
            bucket[key, default: []].append(s)
            meta[key] = (title, sort)
        }
        return bucket.map { key, list in
            DrawerSection(id: key, title: meta[key]?.title ?? "",
                          sortKey: meta[key]?.sort ?? Int.max, sessions: list)
        }
        .sorted { $0.sortKey < $1.sortKey }
    }

    // MARK: - Actions / Load

    private func openSession(_ session: ChatSessionRecord) {
        let isFeedback = ChatSessionRecord.Kind(rawValue: session.kind) == .feedback
        chatContext = ChatSheetContext(
            session: session,
            // 피드백 세션은 원본 카드 본문을 헤더로 보여준다. 가이드 세션은 본문이 message[0]에 있음.
            headerContent: isFeedback ? placements[session.id]?.content : nil,
            headerServerId: isFeedback ? session.sourceFeedbackId : nil
        )
    }

    private func load() async {
        do {
            let loaded = try db.sessions(noteId: noteId)
            var placementMap: [String: FeedbackRecord] = [:]
            for s in loaded {
                if let p = try? db.placement(sessionId: s.id) { placementMap[s.id] = p }
            }
            await MainActor.run {
                self.sessions = loaded
                self.placements = placementMap
            }
        } catch {
            appLogError("drawer", "load sessions failed", ["error": "\(error)"])
        }

        // 챕터 목록 fetch (page→챕터 계산용). 실패해도 스냅샷/기타로 폴백.
        if let textbookId {
            if let chs: [ChapterItem] = try? await APIClient.shared.get("/pdf/\(textbookId)/chapters") {
                await MainActor.run { self.chapters = chs }
            }
        }
        await MainActor.run { self.loading = false }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
