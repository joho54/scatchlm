import SwiftUI
import UniformTypeIdentifiers

/// 기존 노트의 제목·주제·교재를 한 곳에서 편집한다.
/// - 노트 좌상단 제목 탭 → 전체 편집
/// - 교재 미연결 상태에서 PDF pill 탭 → 교재 설정 (focusTextbook=true로 교재 섹션 강조)
/// 즉시 생성된 빈 노트도 여기서 교재를 나중에 붙일 수 있다.
struct NoteMetaSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var language: String
    @State private var selectedTextbookId: String?
    @State private var selectedTextbookName: String?
    @State private var selectedTextbookPages: Int

    @State private var recentLanguages: [String] = []
    @State private var textbooks: [TextbookListItem] = []
    @State private var loadingTextbooks = false
    @State private var showFilePicker = false
    @State private var uploading = false
    @State private var uploadError: String?   // 업로드 실패 사용자 안내 (침묵 금지)

    let note: Note
    let focusTextbook: Bool
    /// 변경된 메타를 반영한 Note를 돌려준다. 부모가 영속화한다.
    let onSave: (Note) -> Void

    init(note: Note, focusTextbook: Bool = false, onSave: @escaping (Note) -> Void) {
        self.note = note
        self.focusTextbook = focusTextbook
        self.onSave = onSave
        _title = State(initialValue: note.title)
        _language = State(initialValue: note.language)
        _selectedTextbookId = State(initialValue: note.textbookId)
        _selectedTextbookName = State(initialValue: note.textbookName)
        _selectedTextbookPages = State(initialValue: note.textbookPages)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("제목") {
                    TextField("제목 없음", text: $title)
                }

                Section("주제") {
                    TextField("예: 일본어, 물리학, 세계사 (비워두면 분야 중립)", text: $language)

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

                Section("교재") {
                    if loadingTextbooks {
                        ProgressView()
                    } else {
                        if selectedTextbookId != nil {
                            Button(role: .destructive) {
                                selectedTextbookId = nil
                                selectedTextbookName = nil
                                selectedTextbookPages = 0
                            } label: {
                                Label("교재 연결 해제", systemImage: "xmark.circle")
                            }
                        }

                        ForEach(textbooks) { tb in
                            Button {
                                if selectedTextbookId == tb.id {
                                    selectedTextbookId = nil
                                    selectedTextbookName = nil
                                    selectedTextbookPages = 0
                                } else {
                                    selectedTextbookId = tb.id
                                    selectedTextbookName = tb.fileName
                                    selectedTextbookPages = tb.totalPages
                                }
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
            .navigationTitle(focusTextbook ? "교재 설정" : "노트 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        var updated = note
                        // 제목이 비어 있고 교재를 지정하면 PDF 이름을 기본 제목으로.
                        updated.title = Note.resolveTitle(title, textbookName: selectedTextbookId == nil ? nil : selectedTextbookName)
                        updated.language = language  // 빈 값 허용 = 분야 중립
                        updated.textbookId = selectedTextbookId
                        updated.textbookName = selectedTextbookName
                        updated.textbookPages = selectedTextbookId == nil ? 0 : selectedTextbookPages
                        // intake(A): 교재가 노트에 편입 → is_scanned 1회 재평가(멱등, 평생1회).
                        if let tid = selectedTextbookId {
                            Task { try? await APIClient.shared.ensureTextbook(tid) }
                        }
                        onSave(updated)
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadRecentLanguages()
                loadTextbooks()
            }
            .sheet(isPresented: $showFilePicker) {
                // asCopy 피커 — 클라우드(OneDrive 등) 미다운로드 파일도 로컬 사본으로 받아 ENOENT 방지.
                DocumentPicker(
                    contentTypes: [.pdf],
                    onPick: { url in
                        showFilePicker = false
                        handleFileImport(url)
                    },
                    onCancel: { showFilePicker = false }
                )
            }
            .alert("교재를 올릴 수 없어요", isPresented: uploadErrorPresented) {
                Button("확인", role: .cancel) { uploadError = nil }
            } message: {
                Text(uploadError ?? "")
            }
        }
    }

    /// 인라인 Binding(get:set:)을 body에 두면 type-check가 무거워져 컴파일이 터진다 → 분리.
    private var uploadErrorPresented: Binding<Bool> {
        Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })
    }

    private func loadRecentLanguages() {
        do {
            let notes = try DatabaseService.shared.allNotes()
            recentLanguages = Array(Set(notes.map(\.language)).filter { !$0.isEmpty }).sorted()
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
                appLogError("note-meta", "load textbooks failed", ["error": "\(error)"])
                await MainActor.run { loadingTextbooks = false }
            }
        }
    }

    /// asCopy 피커가 넘긴 로컬 사본 URL을 업로드. 사본이라 security-scope 처리 불필요.
    private func handleFileImport(_ url: URL) {
        appLog("pdf-upload", "picked file", ["name": url.lastPathComponent])
        uploading = true
        Task {
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
                let item = TextbookListItem(
                    id: res.id, fileName: res.fileName, totalPages: res.totalPages,
                    isScanned: res.isScanned ?? false, ocrStatus: res.ocrStatus,
                    ocrPagesTotal: (res.isScanned ?? false) ? res.totalPages : 0
                )
                await MainActor.run {
                    textbooks.append(item)
                    selectedTextbookId = item.id
                    selectedTextbookName = item.fileName
                    selectedTextbookPages = item.totalPages
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
