import SwiftUI

struct HomeView: View {
    @State private var notes: [Note] = []
    @State private var search = ""
    @State private var showCreateSheet = false
    @State private var showSettings = false
    @State private var selectedNoteId: String?

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
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(filteredNotes) { note in
                    NavigationLink(value: note.id) {
                        NoteCardView(note: note)
                    }
                    .contextMenu {
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
        .onAppear { loadNotes() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Ruled lines preview
            ZStack {
                Color.white
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.blue.opacity(0.08))
                            .frame(height: 1)
                            .padding(.top, 24)
                    }
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(note.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack {
                Text(note.language.uppercased())
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
}
