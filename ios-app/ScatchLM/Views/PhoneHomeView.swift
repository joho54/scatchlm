import SwiftUI

/// iPhone 컴패니언 홈 셸 (iphone-companion-app-spec §4.2·B-3).
///
/// iPad의 `HomeView`(편집 가능)와 달리, iPhone은 **읽기 전용**이다:
/// - 노트 탭: 동기화된 노트를 열람(`PhoneNoteReaderView`) — 필기/편집 불가.
/// - 교재 탭: 연결된 교재 PDF를 읽기 전용으로 보기 + 가이드 채팅(`PdfViewerView`).
/// - 챗 서랍 탭(§4.3, Track C)은 `chapter-chat-drawer-spec` 선행 필요 → 본 MVP 범위 외(§R1).
///
/// 편집 진입점(노트 생성 FAB, 교재 업로드, 메타 편집)은 **노출하지 않는다**(§4.2 마지막 줄).
struct PhoneHomeView: View {
    var body: some View {
        TabView {
            PhoneNotesTab()
                .tabItem { Label("노트", systemImage: "note.text") }

            PhoneTextbooksTab()
                .tabItem { Label("교재", systemImage: "books.vertical") }
        }
    }
}

// MARK: - 노트 탭

private struct PhoneNotesTab: View {
    @State private var notes: [Note] = []
    @State private var folders: [Folder] = []
    @State private var selectedFolder: String? = nil   // nil = 전체(분류·미분류 모두)
    @State private var search = ""
    @State private var showSettings = false

    private let db = DatabaseService.shared
    private let sync = SyncService.shared

    private var filteredNotes: [Note] {
        var result = notes
        // 폴더 필터(읽기 전용 — note-folders-spec §4.5). 전체(nil)는 모든 노트 노출.
        if let sel = selectedFolder {
            result = result.filter { $0.folderId == sel }
        }
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            result = result.filter { note in
                note.title.localizedCaseInsensitiveContains(term)
                    || note.language.localizedCaseInsensitiveContains(term)
                    || (note.textbookName?.localizedCaseInsensitiveContains(term) ?? false)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !folders.isEmpty {
                    folderChips
                }
                ScrollView {
                    if filteredNotes.isEmpty {
                        emptyState
                    }
                    // iPhone은 단일 컬럼(§4.2). 썸네일/카드 렌더는 iPad와 동일 컴포넌트 재사용.
                    LazyVStack(spacing: 12) {
                        ForEach(filteredNotes) { note in
                            NavigationLink(value: note.id) {
                                NoteCardView(note: note)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("노트")
            .navigationDestination(for: String.self) { noteId in
                PhoneNoteReaderView(noteId: noteId)
            }
            .searchable(text: $search, prompt: "제목·과목·교재로 검색")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        SyncStatusIndicator()
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
            }
            .onAppear { loadNotes() }
            .onChange(of: sync.lastSyncedAt) { loadNotes() }
        }
    }

    // 폴더 필터 칩 바(읽기 전용 — 생성/이름변경/삭제는 iPad 전용). 전체 + 폴더 목록.
    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                folderChip(title: "전체", id: nil)
                ForEach(folders) { folder in
                    folderChip(title: folder.name, id: folder.id)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func folderChip(title: String, id: String?) -> some View {
        let selected = selectedFolder == id
        return Button {
            selectedFolder = id
        } label: {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: search.isEmpty ? "ipad.and.iphone" : "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(search.isEmpty ? "아직 노트가 없어요" : "검색 결과가 없어요")
                .font(.headline)
            Text(search.isEmpty
                 ? "iPad에서 만든 노트가 여기에 동기화돼 열람할 수 있어요."
                 : "다른 검색어를 입력해 보세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    private func loadNotes() {
        do {
            notes = try db.allNotes()
            folders = (try? db.allFolders()) ?? []
            // 선택한 폴더가 동기화로 사라졌으면 전체로 되돌린다.
            if let sel = selectedFolder, !folders.contains(where: { $0.id == sel }) {
                selectedFolder = nil
            }
            appLog("phoneHome", "loadNotes", ["count": notes.count, "folders": folders.count])
        } catch {
            appLogError("phoneHome", "loadNotes failed", ["error": "\(error)"])
        }
    }
}

// MARK: - 교재 탭

private struct PhoneTextbooksTab: View {
    @State private var textbooks: [TextbookListItem] = []
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading && textbooks.isEmpty {
                    ProgressView("불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if textbooks.isEmpty {
                    emptyState
                } else {
                    List(textbooks) { tb in
                        NavigationLink(value: tb) {
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed.fill")
                                    .foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tb.fileName)
                                        .font(.body)
                                        .lineLimit(2)
                                    Text("\(tb.totalPages)페이지")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("교재")
            .navigationDestination(for: TextbookListItem.self) { tb in
                // 읽기 전용 PDF 뷰어(§4.4). PdfViewerView는 이미 비편집(PDFView 기본) +
                // 플로팅 바라 compact에서 그대로 동작. 읽기 전용이므로 페이지 영속은 불필요.
                PdfViewerView(
                    textbookId: tb.id,
                    totalPages: tb.totalPages,
                    initialPage: 1,
                    onPageChanged: { _ in },
                    onClose: { }
                )
                .navigationTitle(tb.fileName)
                .navigationBarTitleDisplayMode(.inline)
            }
            .task { await loadTextbooks() }
            .refreshable { await loadTextbooks() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: loadError == nil ? "books.vertical" : "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(loadError ?? "아직 교재가 없어요")
                .font(.headline)
            Text(loadError == nil
                 ? "iPad에서 교재 PDF를 업로드하면 여기서 읽을 수 있어요."
                 : "당겨서 새로고침 해보세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    private func loadTextbooks() async {
        loading = true
        defer { loading = false }
        do {
            let items: [TextbookListItem] = try await APIClient.shared.get("/pdf/textbooks")
            textbooks = items
            loadError = nil
            appLog("phoneHome", "loadTextbooks", ["count": items.count])
        } catch {
            loadError = "교재를 불러오지 못했어요"
            appLogError("phoneHome", "loadTextbooks failed", ["error": "\(error)"])
        }
    }
}
