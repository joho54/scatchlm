import SwiftUI
import PencilKit

struct HomeView: View {
    @State private var notes: [Note] = []
    @State private var folders: [Folder] = []
    @State private var selectedFolderId: String?      // nil = "전체"
    @State private var showSidebar = true
    @State private var search = ""
    @State private var path: [String] = []
    @State private var showCreateSheet = false
    @State private var showSettings = false
    @State private var editingNote: Note?
    @State private var movingNote: Note?
    @State private var folderEdit: FolderEditTarget?

    private let db = DatabaseService.shared
    private let sync = SyncService.shared

    /// 폴더 필터(전체=필터 없음) AND 검색(§4.5). 전체는 분류·미분류·dangling을 모두 노출.
    private var filteredNotes: [Note] {
        var result = notes
        if let fid = selectedFolderId {
            result = result.filter { $0.folderId == fid }
        }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            result = result.filter { $0.matchesSearch(search) }
        }
        return result
    }

    /// 사이드바 카운트 — 검색 무시, 전체 노트 기준. nil=전체.
    private func noteCount(_ folderId: String?) -> Int {
        guard let folderId else { return notes.count }
        return notes.filter { $0.folderId == folderId }.count
    }

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 16)
    ]

    var body: some View {
        NavigationStack(path: $path) {
        HStack(spacing: 0) {
            if showSidebar {
                FolderSidebar(
                    folders: folders,
                    selectedFolderId: $selectedFolderId,
                    noteCount: noteCount,
                    onAddFolder: { folderEdit = FolderEditTarget(folder: nil) },
                    onRename: { folderEdit = FolderEditTarget(folder: $0) },
                    onDelete: deleteFolder
                )
                Divider()
            }
            notesGrid
        }
        .navigationTitle("노트")
        .navigationDestination(for: String.self) { noteId in
            NoteView(noteId: noteId)
        }
        .searchable(text: $search, prompt: "제목·과목·교재로 검색")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    // 교재로 시작 — 처음부터 교재를 붙여 만들고 싶을 때.
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "book.badge.plus")
                    }
                    // 즉시 생성 — 빈 노트를 만들고 바로 진입. 제목·주제·교재는 노트 안에서 언제든.
                    Button {
                        createNote()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                HStack {
                    Button {
                        withAnimation { showSidebar.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    SyncStatusIndicator()
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateNoteSheet { title, language, textbook in
                createNote(title: title, language: language, textbook: textbook)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(item: $editingNote) { note in
            NoteMetaSheet(note: note) { updated in
                updateNote(updated)
            }
        }
        .sheet(item: $movingNote) { note in
            MoveToFolderSheet(folders: folders, currentFolderId: note.folderId) { target in
                moveNote(note, to: target)
            }
        }
        .sheet(item: $folderEdit) { target in
            FolderEditSheet(folder: target.folder) { name in
                saveFolder(existing: target.folder, name: name)
            }
        }
        .onAppear { loadFolders(); loadNotes() }
        // 로그인 직후 full pull로 복원된 노트는 .onAppear 이후 DB에 머지되므로,
        // sync 완료(lastSyncedAt 변화) 때 다시 읽어 화면에 반영한다. (재실행해야 보이던 문제)
        .onChange(of: sync.lastSyncedAt) { loadFolders(); loadNotes() }
        }
    }

    @ViewBuilder
    private var notesGrid: some View {
        ScrollView {
            if filteredNotes.isEmpty {
                emptyState
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(filteredNotes) { note in
                    NavigationLink(value: note.id) {
                        NoteCardView(note: note)
                    }
                    .contextMenu {
                        Button {
                            editingNote = note
                        } label: {
                            Label("편집", systemImage: "pencil")
                        }
                        Button {
                            movingNote = note
                        } label: {
                            Label("폴더로 이동", systemImage: "folder")
                        }
                        Button(role: .destructive) {
                            deleteNote(note)
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: search.isEmpty ? "pencil.and.outline" : "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(search.isEmpty ? "아직 노트가 없어요" : "검색 결과가 없어요")
                .font(.headline)
            Text(search.isEmpty
                 ? "오른쪽 위 + 버튼을 눌러 첫 노트를 만들어 보세요."
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
            appLog("home", "loadNotes", ["count": notes.count])
        } catch {
            appLogError("home", "loadNotes failed", ["error": "\(error)"])
        }
    }

    private func loadFolders() {
        do {
            folders = try db.allFolders()
            // 선택 폴더가 사라졌으면(다른 기기 삭제 등) 전체로 폴백 (§7 R1).
            if let sel = selectedFolderId, !folders.contains(where: { $0.id == sel }) {
                selectedFolderId = nil
            }
        } catch {
            appLogError("home", "loadFolders failed", ["error": "\(error)"])
        }
    }

    private func saveFolder(existing: Folder?, name: String) {
        do {
            if var folder = existing {
                folder.name = name
                try db.saveFolder(&folder)
            } else {
                var folder = Folder(name: name, sortOrder: folders.count)
                try db.saveFolder(&folder)
            }
            loadFolders()
        } catch {
            appLogError("home", "saveFolder failed", ["error": "\(error)"])
        }
    }

    private func deleteFolder(_ folder: Folder) {
        do {
            try db.deleteFolder(id: folder.id)
            if selectedFolderId == folder.id { selectedFolderId = nil }
            loadFolders()
            loadNotes()   // 소속 노트가 folder_id=NULL로 이동됨
        } catch {
            appLogError("home", "deleteFolder failed", ["error": "\(error)"])
        }
    }

    private func moveNote(_ note: Note, to folderId: String?) {
        do {
            try db.moveNote(id: note.id, toFolder: folderId)
            if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                notes[idx].folderId = folderId
            }
        } catch {
            appLogError("home", "moveNote failed", ["error": "\(error)"])
        }
    }

    /// 노트 생성 후 곧바로 진입한다.
    /// - 인자 없이 호출하면 빈 노트(제목 없음·주제 없음·교재 없음)를 즉시 만든다.
    /// - "교재로 시작" 시트에서는 title/language/textbook을 채워 호출한다.
    private func createNote(title: String = "", language: String = "", textbook: TextbookListItem? = nil) {
        // 현재 선택 폴더를 기본 폴더로 (전체 화면이면 nil = 미분류).
        var note = Note.new(title: title, language: language, folderId: selectedFolderId)
        if let tb = textbook {
            note.textbookId = tb.id
            note.textbookName = tb.fileName
            note.textbookPages = tb.totalPages
        }
        do {
            try db.saveNote(&note)
            notes.insert(note, at: 0)
            appLog("home", "createNote OK", ["id": note.id, "hasPdf": "\(note.textbookId != nil)"])
            path.append(note.id)  // 즉시 진입
        } catch {
            appLogError("home", "createNote failed", ["error": "\(error)"])
        }
    }

    private func updateNote(_ updated: Note) {
        guard let idx = notes.firstIndex(where: { $0.id == updated.id }) else { return }
        var n = updated
        do {
            try db.saveNote(&n)
            notes[idx] = n
            appLog("home", "updateNote OK", ["id": n.id])
        } catch {
            appLogError("home", "updateNote failed", ["error": "\(error)"])
        }
    }

    private func deleteNote(_ note: Note) {
        do {
            try db.deleteNote(id: note.id)
            notes.removeAll { $0.id == note.id }
        } catch {
            appLogError("home", "deleteNote failed", ["error": "\(error)"])
        }
    }
}

/// 폴더 생성/이름변경 시트 식별자. folder=nil 이면 신규 생성.
/// (.sheet(item:)은 Identifiable이 필요하므로 옵셔널 Folder를 감싼다.)
struct FolderEditTarget: Identifiable {
    let folder: Folder?
    var id: String { folder?.id ?? "__new__" }
}

struct NoteCardView: View {
    let note: Note

    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                colorScheme == .dark ? Color(white: 0.12) : Color.white
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.blue.opacity(0.08))
                            .frame(height: 1)
                            .padding(.top, 24)
                    }
                }
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: note.id) { await loadThumbnail() }

            Text(note.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack {
                if !note.language.isEmpty {
                    Text(note.language)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }

                if note.textbookName != nil {
                    Image(systemName: "book.closed.fill")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }

                Spacer()

                Text(note.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func loadThumbnail() async {
        let noteId = note.id
        let img: UIImage? = await Task.detached(priority: .utility) {
            guard let pages = try? DatabaseService.shared.pages(noteId: noteId),
                  let first = pages.first,
                  let data = first.drawingData,
                  let drawing = try? PKDrawing(data: data),
                  !drawing.strokes.isEmpty else { return nil }

            let sourceWidth: CGFloat = 800
            let aspect: CGFloat = 160.0 / 240.0
            let sourceHeight = sourceWidth * aspect
            let rect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
            let scale = 240.0 / sourceWidth
            return drawing.image(from: rect, scale: scale)
        }.value
        await MainActor.run { self.thumbnail = img }
    }
}
