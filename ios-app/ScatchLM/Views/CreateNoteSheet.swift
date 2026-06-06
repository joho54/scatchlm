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

                Section("교재 (선택)") {
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
                                        HStack(spacing: 6) {
                                            Text("\(tb.totalPages)페이지")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if let chip = tb.ocrChip {
                                                Text(chip)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(Color.purple.opacity(0.12))
                                                    .foregroundStyle(.purple)
                                                    .clipShape(Capsule())
                                            }
                                        }
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
                                Text(uploading ? "업로드 중…" : "새 PDF 업로드")
                            }
                        }
                        .disabled(uploading)
                    }
                }
            }
            .navigationTitle("새 노트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기") {
                        let selected = textbooks.first { $0.id == selectedTextbookId }
                        // intake(A): 기존 PDF가 새 노트에 편입 → is_scanned 1회 재평가(멱등, 평생1회).
                        if let tid = selectedTextbookId {
                            Task { try? await APIClient.shared.ensureTextbook(tid) }
                        }
                        onCreate(
                            Note.resolveTitle(title, textbookName: selected?.fileName),
                            language,  // 빈 주제는 그대로 — 분야 중립 (백엔드 처리)
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
            let langs = Set(notes.map(\.language)).filter { !$0.isEmpty }.sorted()
            recentLanguages = langs
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
                        let isScanned: Bool?
                        let ocrStatus: String?
                        enum CodingKeys: String, CodingKey {
                            case id, fileName, totalPages
                            case isScanned = "is_scanned"
                            case ocrStatus = "ocr_status"
                        }
                    }
                    let res: UploadResult = try await APIClient.shared.uploadFile("/pdf/upload", fileURL: url)
                    appLog("pdf-upload", "upload OK", [
                        "id": res.id,
                        "name": res.fileName,
                        "pages": "\(res.totalPages)",
                        "scanned": "\(res.isScanned ?? false)",
                    ])
                    let item = TextbookListItem(
                        id: res.id, fileName: res.fileName, totalPages: res.totalPages,
                        isScanned: res.isScanned ?? false, ocrStatus: res.ocrStatus,
                        ocrPagesTotal: (res.isScanned ?? false) ? res.totalPages : 0
                    )
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
