import SwiftUI
import PencilKit

struct HomeView: View {
    @State private var notes: [Note] = []
    @State private var search = ""
    @State private var showCreateSheet = false
    @State private var showSettings = false
    @State private var selectedNoteId: String?
    @State private var editingNote: Note?

    private let db = DatabaseService.shared

    private var filteredNotes: [Note] {
        if search.isEmpty { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 16)
    ]

    var body: some View {
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
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleteNote(note)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Notes")
        .navigationDestination(for: String.self) { noteId in
            NoteView(noteId: noteId)
        }
        .searchable(text: $search, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
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
        .sheet(isPresented: $showCreateSheet) {
            CreateNoteSheet { title, language, textbook in
                createNote(title: title, language: language, textbook: textbook)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(item: $editingNote) { note in
            EditNoteSheet(note: note) { newTitle, newLanguage in
                updateNote(note, title: newTitle, language: newLanguage)
            }
        }
        .onAppear { loadNotes() }
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

    private func createNote(title: String, language: String, textbook: TextbookListItem? = nil) {
        var note = Note.new(title: title, language: language)
        if let tb = textbook {
            note.textbookId = tb.id
            note.textbookName = tb.fileName
            note.textbookPages = tb.totalPages
        }
        do {
            try db.saveNote(&note)
            appLog("home", "createNote OK", ["id": note.id, "title": note.title, "countBefore": notes.count])
            notes.insert(note, at: 0)
            appLog("home", "createNote done", ["countAfter": notes.count])
        } catch {
            appLogError("home", "createNote failed", ["error": "\(error)"])
        }
    }

    private func updateNote(_ note: Note, title: String, language: String) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = notes[idx]
        updated.title = title
        updated.language = language
        updated.updatedAt = Date()
        do {
            try db.saveNote(&updated)
            notes[idx] = updated
            appLog("home", "updateNote OK", ["id": updated.id])
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
                Text(note.language)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())

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
