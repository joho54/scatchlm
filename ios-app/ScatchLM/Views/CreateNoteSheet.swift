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

                Section("Subject") {
                    TextField("e.g. Japanese, Physics, World History", text: $language)

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
        appLog("pdf-upload", "fileImporter callback")

        switch result {
        case .failure(let err):
            appLogError("pdf-upload", "picker returned error", ["error": "\(err)"])
            return
        case .success(let urls):
            guard let url = urls.first else {
                appLogError("pdf-upload", "picker returned empty urls")
                return
            }
            appLog("pdf-upload", "picked file", [
                "name": url.lastPathComponent,
                "isFileURL": "\(url.isFileURL)",
            ])

            uploading = true
            Task {
                // security-scoped 접근은 Task 안에서 잡고 풀어야 한다.
                // 함수가 먼저 리턴하면 defer가 즉시 호출돼서 Task가 파일을 못 읽음.
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }

                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                appLog("pdf-upload", "starting upload", [
                    "name": url.lastPathComponent,
                    "size": "\(fileSize)",
                    "securityScoped": "\(granted)",
                ])

                do {
                    struct UploadResult: Decodable {
                        let id: String
                        let fileName: String
                        let totalPages: Int
                    }
                    let res: UploadResult = try await APIClient.shared.uploadFile("/pdf/upload", fileURL: url)
                    appLog("pdf-upload", "upload OK", [
                        "id": res.id,
                        "name": res.fileName,
                        "pages": "\(res.totalPages)",
                    ])
                    let item = TextbookListItem(id: res.id, fileName: res.fileName, totalPages: res.totalPages)
                    await MainActor.run {
                        textbooks.append(item)
                        selectedTextbookId = item.id
                        uploading = false
                    }
                } catch {
                    appLogError("pdf-upload", "upload failed", ["error": "\(error)"])
                    await MainActor.run { uploading = false }
                }
            }
        }
    }
}
