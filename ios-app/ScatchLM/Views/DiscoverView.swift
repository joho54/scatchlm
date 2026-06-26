import SwiftUI

/// discover 시트 — 질의 입력 → `/api/discover` 호출 → 결과 리스트 (docs/discover-feature-spec.md §4.2 B-2).
/// iPad는 form 시트, iPhone은 full-height로 표시(호출부의 presentationDetents).
struct DiscoverView: View {
    /// 인제스션 성공 알림(서재 갱신용).
    var onAdded: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var phase: Phase = .input
    @State private var suggestions: [DiscoverSuggestion] = []
    @FocusState private var focused: Bool

    enum Phase: Equatable {
        case input
        case loading
        case results(DiscoverResult)
        case error(String)

        static func == (l: Phase, r: Phase) -> Bool {
            switch (l, r) {
            case (.input, .input), (.loading, .loading): return true
            case (.results, .results), (.error, .error): return true
            default: return false
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                content
                    // 스크롤 드래그로 키보드 내림(iMessage 패턴, chat-keyboard-hang-postmortem).
                    .scrollDismissesKeyboard(.interactively)
                    // 검색창 바깥(제안/결과 영역) 탭 → 키보드 해제. simultaneous라 칩·결과 버튼 탭은 안 막음.
                    .simultaneousGesture(TapGesture().onEnded { focused = false })
            }
            .navigationTitle("자료 찾기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear {
                focused = true
                loadSuggestions()
            }
        }
    }

    /// 검색창 placeholder — 서재 기반 첫 도전 분야(있으면), 없으면 정적 예시.
    private var placeholderText: String {
        suggestions.first?.topic ?? "예: 비교언어학"
    }

    private func loadSuggestions() {
        guard suggestions.isEmpty else { return }
        Task {
            // 홈 프롬프트 바와 같은 세션 캐시를 공유 — 중복 Haiku 호출 방지.
            let result = await DiscoverSuggestionLoader.shared.load(
                language: Config.responseLanguage
            )
            await MainActor.run { suggestions = result }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.magnifyingglass")
                .foregroundStyle(.tint)
            // placeholder도 서재 기반 Haiku 제안 하나로 채운다(로드 전엔 정적 예시).
            TextField(placeholderText, text: $query)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(run)
            if !query.isEmpty {
                Button {
                    query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .input:
            placeholder
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("무료 공개 자료를 찾는 중…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results(let result):
            DiscoverResultsView(result: result, onAdded: onAdded)
        case .error(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(msg)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("다시 시도", action: run)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("지금까지 공부한 것과 이어지는, 새로 도전해볼 분야예요.\n탭하면 무료 공개 자료를 찾아 드려요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 40)

                // 서재 기반 "새로 도전해볼 분야" 제안 칩 — topic 탭하면 질의를 채우고 바로 검색.
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("새로 도전해볼 분야")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                        ForEach(suggestions) { s in
                            Button {
                                query = s.topic
                                run()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "sparkles").font(.callout).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(s.topic)
                                            .font(.callout).fontWeight(.medium)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        if !s.bridge.isEmpty {
                                            Text(s.bridge)
                                                .font(.caption).foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        focused = false
        phase = .loading
        appLog("discover", "query", ["len": "\(q.count)"])
        Task {
            do {
                let result = try await APIClient.shared.discover(
                    query: q, responseLanguage: Config.responseLanguage
                )
                await MainActor.run { phase = .results(result) }
            } catch {
                appLogError("discover", "request failed", ["error": "\(error)"])
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? "자료를 찾지 못했어요. 잠시 후 다시 시도해 주세요."
                await MainActor.run { phase = .error(msg) }
            }
        }
    }
}
