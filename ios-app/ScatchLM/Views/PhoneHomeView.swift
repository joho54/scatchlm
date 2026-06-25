import SwiftUI

/// iPhone 컴패니언 홈 셸 (iphone-companion-app-spec §4.2·B-3).
///
/// iPad의 `HomeView`(편집 가능)와 달리, iPhone은 **읽기 전용**이다:
/// - 노트를 열람(`PhoneNoteReaderView`) — 필기/편집 불가.
/// - 교재 PDF는 **노트 내부에서** 진입한다(노트 종속). 교재 필기(`pdfAnnotation`)가
///   `noteId`로 영속화되므로, 전역 교재 탭은 노트 컨텍스트가 없어 필기 레이어를 못 띄운다.
///   따라서 교재 탭을 제거하고 `PhoneNoteReaderView`의 "교재" 진입점으로 일원화한다.
/// - 챗 서랍은 노트 내부 툴바에서 진입(`PhoneNoteReaderView`).
///
/// 편집 진입점(노트 생성 FAB, 교재 업로드, 메타 편집)은 **노출하지 않는다**(§4.2 마지막 줄).
struct PhoneHomeView: View {
    var body: some View {
        PhoneNotesTab()
    }
}

// MARK: - 노트 탭

private struct PhoneNotesTab: View {
    @State private var notes: [Note] = []
    @State private var folders: [Folder] = []
    @State private var selectedFolder: String? = nil   // nil = 전체(분류·미분류 모두)
    @State private var search = ""
    @State private var showSettings = false
    @State private var showCreateSheet = false
    @State private var showDiscover = false
    @State private var path: [String] = []   // 생성 후 프로그래밍 push용 노트 ID 스택

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
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // 학습 자료 추천 진입(§4.2 — iPad/iPhone 공용 프롬프트 바).
                DiscoverPromptBar { showDiscover = true }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
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
                // 노트 생성(§확장). iPhone도 노트+교재 생성 가능 — 필기는 iPad.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
            }
            .sheet(isPresented: $showDiscover) {
                DiscoverView()
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateNoteSheet { title, language, textbook in
                    createNote(title: title, language: language, textbook: textbook)
                }
            }
            .onAppear { loadNotes() }
            .onChange(of: sync.lastSyncedAt) { loadNotes() }
        }
    }

    /// 노트 생성 — iPad `HomeView.createNote`와 동일 영속(교재 연결 포함). 생성 후 즉시 리더로 push.
    /// 필기·피드백은 iPad 전용이라, iPhone 리더(`PhoneNoteReaderView`)는 생성된 노트를 읽기·교재 열람만 한다.
    private func createNote(title: String, language: String, textbook: TextbookListItem?) {
        var note = Note.new(title: title, language: language, folderId: selectedFolder)
        if let tb = textbook {
            note.textbookId = tb.id
            note.textbookName = tb.fileName
            note.textbookPages = tb.totalPages
        }
        do {
            try db.saveNote(&note)
            notes.insert(note, at: 0)
            appLog("phoneHome", "createNote OK", ["id": note.id, "hasPdf": "\(note.textbookId != nil)"])
            track(.noteCreate, .ok, ["hasPdf": note.textbookId != nil])
            path.append(note.id)   // 생성 직후 리더 진입
        } catch {
            appLogError("phoneHome", "createNote failed", ["error": "\(error)"])
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
