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
    @State private var uploadError: String?   // 업로드 실패(스캔 페이지 천장 초과 등) 사용자 안내

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
            .sheet(isPresented: $showFilePicker) {
                // asCopy 피커 — 클라우드(OneDrive 등) 미다운로드 파일도 시스템이 다운로드+샌드박스
                // 복사한 로컬 사본 URL을 준다. (구 .fileImporter는 placeholder URL → 비조정 읽기 ENOENT)
                DocumentPicker(
                    contentTypes: [.pdf],
                    onPick: { url in
                        showFilePicker = false
                        handleFileImport(url)
                    },
                    onCancel: { showFilePicker = false }
                )
            }
            .alert("교재를 올릴 수 없어요", isPresented: Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })) {
                Button("확인", role: .cancel) { uploadError = nil }
            } message: {
                Text(uploadError ?? "")
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

    /// asCopy 피커가 넘긴 로컬 사본 URL을 업로드. 사본이라 security-scope 처리 불필요.
    private func handleFileImport(_ url: URL) {
        appLog("pdf-upload", "picked file", [
            "name": url.lastPathComponent,
            "isFileURL": "\(url.isFileURL)",
        ])

        uploading = true
        Task {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            appLog("pdf-upload", "starting upload", [
                "name": url.lastPathComponent,
                "size": "\(fileSize)",
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
                // 침묵 금지 — 스캔 페이지 천장 초과(422)·클라우드 다운로드 실패 등을 사용자에게 알린다.
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? "교재를 올리지 못했어요. 잠시 후 다시 시도해 주세요."
                await MainActor.run {
                    uploading = false
                    uploadError = msg
                }
            }
        }
    }
}
