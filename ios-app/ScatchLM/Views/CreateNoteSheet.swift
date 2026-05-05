import SwiftUI
import UniformTypeIdentifiers

struct CreateNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var language = ""
    @State private var recentLanguages: [String] = []
    @State private var textbooks: [TextbookListItem] = []
    @State private var selectedTextbookId: String?
    @State private var loadingTextbooks = false
    @State private var showFilePicker = false
    @State private var uploading = false

    let onCreate: (String, String, TextbookListItem?) -> Void

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

                Section("Textbook (optional)") {
                    if loadingTextbooks {
                        ProgressView()
                    } else {
                        ForEach(textbooks) { tb in
                            Button {
                                selectedTextbookId = selectedTextbookId == tb.id ? nil : tb.id
                            } label: {
                                HStack {
                                    Image(systemName: "book.closed.fill")
                                        .foregroundStyle(selectedTextbookId == tb.id ? .white : .purple)
                                        .frame(width: 32, height: 32)
                                        .background(selectedTextbookId == tb.id ? Color.purple : Color.purple.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading) {
                                        Text(tb.fileName)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(tb.totalPages) pages")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if selectedTextbookId == tb.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.purple)
                                    }
                                }
                            }
                        }

                        Button {
                            showFilePicker = true
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.doc")
                                Text(uploading ? "Uploading..." : "Upload new PDF")
                            }
                        }
                        .disabled(uploading)
                    }
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let selected = textbooks.first { $0.id == selectedTextbookId }
                        onCreate(
                            title.isEmpty ? "Untitled note" : title,
                            language.isEmpty ? "en" : language,
                            selected
                        )
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadRecentLanguages()
                loadTextbooks()
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [UTType.pdf],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
    }

    private func loadRecentLanguages() {
        do {
            let notes = try DatabaseService.shared.allNotes()
            let langs = Set(notes.map(\.language)).sorted()
            recentLanguages = langs
            if let first = langs.first, language.isEmpty {
                language = first
            }
        } catch {}
    }

    private func loadTextbooks() {
        loadingTextbooks = true
        Task {
            do {
                let items: [TextbookListItem] = try await APIClient.shared.get("/pdf/textbooks")
                await MainActor.run {
                    textbooks = items
                    loadingTextbooks = false
                }
            } catch {
                print("[CreateNote] Failed to load textbooks: \(error)")
                await MainActor.run { loadingTextbooks = false }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        uploading = true
        Task {
            do {
                struct UploadResult: Decodable {
                    let id: String
                    let fileName: String
                    let totalPages: Int
                }
                let result: UploadResult = try await APIClient.shared.uploadFile("/pdf/upload", fileURL: url)
                let item = TextbookListItem(id: result.id, fileName: result.fileName, totalPages: result.totalPages)
                await MainActor.run {
                    textbooks.append(item)
                    selectedTextbookId = item.id
                    uploading = false
                }
            } catch {
                print("[CreateNote] Upload failed: \(error)")
                await MainActor.run { uploading = false }
            }
        }
    }
}
