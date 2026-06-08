import SwiftUI
import PencilKit

struct HomeView: View {
    @State private var notes: [Note] = []
    @State private var trashed: [Note] = []
    @State private var folders: [Folder] = []
    @State private var selection: HomeFolderSelection = .all
    @State private var showSidebar = true
    @State private var search = ""
    @State private var path: [String] = []
    @State private var showCreateSheet = false
    @State private var showSettings = false
    @State private var editingNote: Note?
    @State private var movingNote: Note?
    @State private var folderEdit: FolderEditTarget?
    @State private var folderPendingDelete: Folder?   // 비어있지 않은 폴더 삭제 확인
    @State private var notePendingPurge: Note?         // 영구삭제 확인
    @State private var showEmptyTrashConfirm = false
    /// 노트 열람 중 들어온 sync 재로드를 보류했음 — 리스트 복귀 시 1회 반영.
    @State private var pendingHomeReload = false

    private let db = DatabaseService.shared
    private let sync = SyncService.shared

    private var isTrash: Bool { selection == .trash }

    /// 현재 선택된 폴더 id (폴더 선택일 때만, 전체/휴지통은 nil). 새 노트 기본 폴더용.
    private var selectedFolderId: String? {
        if case .folder(let id) = selection { return id }
        return nil
    }

    /// 선택(전체/폴더/휴지통) 필터 AND 검색(§4.5). 전체는 분류·미분류·dangling을 모두 노출.
    private var filteredNotes: [Note] {
        var result: [Note]
        switch selection {
        case .all: result = notes
        case .folder(let id): result = notes.filter { $0.folderId == id }
        case .trash: result = trashed
        }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            result = result.filter { $0.matchesSearch(search) }
        }
        return result
    }

    /// 사이드바 카운트 — 검색 무시, 전체(active) 노트 기준. nil=전체.
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
                    selection: $selection,
                    noteCount: noteCount,
                    trashCount: trashed.count,
                    onAddFolder: { folderEdit = FolderEditTarget(folder: nil) },
                    onRename: { folderEdit = FolderEditTarget(folder: $0) },
                    onDelete: requestDeleteFolder
                )
                Divider()
            }
            notesGrid
        }
        .navigationTitle(isTrash ? "휴지통" : "노트")
        .navigationDestination(for: String.self) { noteId in
            NoteView(noteId: noteId)
                // 진동 픽스 검증: NoteView가 홈 path 푸시 경로로 떴음을 표시.
                .onAppear { appLog("boot", "noteview mount", ["via": "home-path"]) }
        }
        .searchable(text: $search, prompt: "제목·과목·교재로 검색")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isTrash {
                    Button(role: .destructive) {
                        showEmptyTrashConfirm = true
                    } label: {
                        Text("비우기")
                    }
                    .disabled(trashed.isEmpty)
                } else {
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
        // 비어있지 않은 폴더 삭제 경고 → 폴더+노트 재귀 휴지통 이동.
        .alert("폴더 삭제", isPresented: .init(
            get: { folderPendingDelete != nil },
            set: { if !$0 { folderPendingDelete = nil } }
        ), presenting: folderPendingDelete) { folder in
            Button("삭제", role: .destructive) { deleteFolder(folder) }
            Button("취소", role: .cancel) {}
        } message: { folder in
            Text("‘\(folder.name)’ 폴더 안의 노트 \(noteCount(folder.id))개가 휴지통으로 이동합니다.")
        }
        // 노트 영구삭제 경고.
        .alert("영구 삭제", isPresented: .init(
            get: { notePendingPurge != nil },
            set: { if !$0 { notePendingPurge = nil } }
        ), presenting: notePendingPurge) { note in
            Button("영구 삭제", role: .destructive) { purgeNote(note) }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("이 노트는 복구할 수 없습니다.")
        }
        // 휴지통 비우기 경고.
        .alert("휴지통 비우기", isPresented: $showEmptyTrashConfirm) {
            Button("비우기", role: .destructive) { emptyTrash() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("노트 \(trashed.count)개가 영구 삭제됩니다. 복구할 수 없습니다.")
        }
        .onAppear { loadFolders(); loadNotes(); loadTrash() }
        // 로그인 직후 full pull로 복원된 노트는 .onAppear 이후 DB에 머지되므로,
        // sync 완료(lastSyncedAt 변화) 때 다시 읽어 화면에 반영한다. (재실행해야 보이던 문제)
        //
        // 단, **노트가 열려 있는 동안(path 비어있지 않음)엔 재로드를 보류**한다. 필기 autosave가
        // db.onWrite→debounced sync→lastSyncedAt 갱신을 유발하는데, 여기서 notes @State를
        // 재할당하면 NavigationStack 루트가 재렌더되고 .navigationDestination이 재평가되어
        // 푸시된 NoteView가 @State 전소실로 재생성된다(캔버스 makeUIView 재호출=필기 진동, 2026-06-08
        // 텔레메트리로 규명). 리스트로 돌아올 때(path 비면) 한 번 반영한다.
        .onChange(of: sync.lastSyncedAt) {
            if path.isEmpty {
                loadFolders(); loadNotes(); loadTrash()
            } else {
                pendingHomeReload = true
            }
        }
        .onChange(of: path) {
            if path.isEmpty, pendingHomeReload {
                pendingHomeReload = false
                loadFolders(); loadNotes(); loadTrash()
            }
        }
        // 휴지통 진입 시 최신 목록 로드.
        .onChange(of: selection) { if isTrash { loadTrash() } }
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
                    if isTrash {
                        // 휴지통: 진입 불가. 복구/영구삭제만.
                        NoteCardView(note: note)
                            .opacity(0.6)
                            .contextMenu { trashMenu(note) }
                    } else {
                        NavigationLink(value: note.id) {
                            NoteCardView(note: note)
                        }
                        .contextMenu { activeMenu(note) }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func activeMenu(_ note: Note) -> some View {
        Button { editingNote = note } label: {
            Label("편집", systemImage: "pencil")
        }
        Button { movingNote = note } label: {
            Label("폴더로 이동", systemImage: "folder")
        }
        Button(role: .destructive) { deleteNote(note) } label: {
            Label("삭제", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func trashMenu(_ note: Note) -> some View {
        Button { restoreNote(note) } label: {
            Label("복구", systemImage: "arrow.uturn.backward")
        }
        Button(role: .destructive) { notePendingPurge = note } label: {
            Label("영구 삭제", systemImage: "trash.slash")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyIcon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.headline)
            Text(emptySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    private var emptyIcon: String {
        if isTrash { return "trash" }
        return search.isEmpty ? "pencil.and.outline" : "magnifyingglass"
    }
    private var emptyTitle: String {
        if isTrash { return String(localized: "휴지통이 비어 있어요") }
        return search.isEmpty ? String(localized: "아직 노트가 없어요") : String(localized: "검색 결과가 없어요")
    }
    private var emptySubtitle: String {
        if isTrash { return String(localized: "삭제한 노트가 여기로 들어옵니다.") }
        return search.isEmpty
            ? String(localized: "오른쪽 위 + 버튼을 눌러 첫 노트를 만들어 보세요.")
            : String(localized: "다른 검색어를 입력해 보세요.")
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
            if case .folder(let id) = selection, !folders.contains(where: { $0.id == id }) {
                selection = .all
            }
        } catch {
            appLogError("home", "loadFolders failed", ["error": "\(error)"])
        }
    }

    private func loadTrash() {
        do {
            trashed = try db.trashedNotes()
        } catch {
            appLogError("home", "loadTrash failed", ["error": "\(error)"])
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

    /// 폴더 삭제 요청 — 내용이 있으면 경고 alert, 비어있으면 즉시 삭제.
    private func requestDeleteFolder(_ folder: Folder) {
        if noteCount(folder.id) > 0 {
            folderPendingDelete = folder
        } else {
            deleteFolder(folder)
        }
    }

    private func deleteFolder(_ folder: Folder) {
        do {
            try db.deleteFolder(id: folder.id)
            if case .folder(let id) = selection, id == folder.id { selection = .all }
            loadFolders()
            loadNotes()   // 소속 노트가 휴지통으로 이동됨
            loadTrash()
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
            loadTrash()   // 휴지통 카운트 갱신
        } catch {
            appLogError("home", "deleteNote failed", ["error": "\(error)"])
        }
    }

    private func restoreNote(_ note: Note) {
        do {
            try db.restoreNote(id: note.id)
            trashed.removeAll { $0.id == note.id }
            loadNotes()   // active 목록으로 복귀
        } catch {
            appLogError("home", "restoreNote failed", ["error": "\(error)"])
        }
    }

    private func purgeNote(_ note: Note) {
        do {
            try db.permanentlyDeleteNote(id: note.id)
            trashed.removeAll { $0.id == note.id }
        } catch {
            appLogError("home", "purgeNote failed", ["error": "\(error)"])
        }
    }

    private func emptyTrash() {
        do {
            try db.emptyTrash()
            trashed = []
        } catch {
            appLogError("home", "emptyTrash failed", ["error": "\(error)"])
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
        // DB I/O만 백그라운드. PKDrawing.image() 렌더는 반드시 메인 스레드에서 호출한다.
        // PencilKit은 프로세스 전역 공유 렌더 컨텍스트를 쓰며, 이 렌더를 백그라운드(Task.detached)에서
        // 돌리면 그 공유 상태가 손상되어 같은 프로세스의 다른 PKCanvasView(노트 캔버스) 필기가
        // 프로세스 전역으로 먹통이 된다(통제실험으로 규명: 썸네일 grid가 있는 화면에서만 재현).
        let data: Data? = await Task.detached(priority: .utility) {
            guard let pages = try? DatabaseService.shared.pages(noteId: noteId),
                  let first = pages.first else { return nil }
            return first.drawingData
        }.value
        guard let data,
              let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty else {
            self.thumbnail = nil
            return
        }
        let sourceWidth: CGFloat = 800
        let aspect: CGFloat = 160.0 / 240.0
        let rect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceWidth * aspect)
        let scale = 240.0 / sourceWidth
        self.thumbnail = drawing.image(from: rect, scale: scale)   // 메인 스레드(View 메서드)
    }
}
