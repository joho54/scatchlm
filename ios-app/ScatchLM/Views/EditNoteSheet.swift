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
                Section("제목") {
                    TextField("제목 없음", text: $title)
                }

                Section("주제") {
                    TextField("예: 일본어, 물리학, 세계사", text: $language)

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
                    Section("교재") {
                        HStack {
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(.purple)
                            Text(tbName)
                                .lineLimit(1)
                            Spacer()
                            Text("\(note.textbookPages)페이지")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("노트 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(
                            title.isEmpty ? String(localized: "제목 없음") : title,
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
