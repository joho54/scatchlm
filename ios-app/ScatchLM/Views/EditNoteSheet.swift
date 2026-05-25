import SwiftUI

struct EditNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var language: String
    @State private var recentLanguages: [String] = []

    let note: Note
    let onSave: (String, String) -> Void

    init(note: Note, onSave: @escaping (String, String) -> Void) {
        self.note = note
        self.onSave = onSave
        _title = State(initialValue: note.title)
        _language = State(initialValue: note.language)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Untitled note", text: $title)
                }

                Section("Target Language") {
                    TextField("e.g. Japanese, Ancient Greek", text: $language)

                    if !recentLanguages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(recentLanguages, id: \.self) { lang in
                                    Button(lang) {
                                        language = lang
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(language == lang ? .purple : .secondary)
                                }
                            }
                        }
                    }
                }

                if let tbName = note.textbookName {
                    Section("Textbook") {
                        HStack {
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(.purple)
                            Text(tbName)
                                .lineLimit(1)
                            Spacer()
                            Text("\(note.textbookPages) pages")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            title.isEmpty ? "Untitled note" : title,
                            language.isEmpty ? "en" : language
                        )
                        dismiss()
                    }
                    .disabled(title == note.title && language == note.language)
                }
            }
            .onAppear { loadRecentLanguages() }
        }
    }

    private func loadRecentLanguages() {
        do {
            let notes = try DatabaseService.shared.allNotes()
            recentLanguages = Array(Set(notes.map(\.language))).sorted()
        } catch {}
    }
}
