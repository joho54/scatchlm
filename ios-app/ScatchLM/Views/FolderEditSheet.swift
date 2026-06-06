import SwiftUI

/// 폴더 생성/이름변경 시트 (note-folders-spec §4.5).
/// folder == nil 이면 신규 생성, 있으면 이름 변경. 1~100자 제약.
struct FolderEditSheet: View {
    let folder: Folder?
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(folder: Folder?, onSave: @escaping (String) -> Void) {
        self.folder = folder
        self.onSave = onSave
        _name = State(initialValue: folder?.name ?? "")
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("폴더 이름", text: $name)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle(folder == nil ? "새 폴더" : "이름 변경")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장", action: save)
                        .disabled(trimmed.isEmpty || trimmed.count > 100)
                }
            }
        }
    }

    private func save() {
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return }
        onSave(trimmed)
        dismiss()
    }
}
