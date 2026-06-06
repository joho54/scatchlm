import SwiftUI

/// 노트를 폴더로 이동하는 선택 시트 (note-folders-spec §4.5 / C-3).
/// "전체"(폴더 없음, nil) 포함. 현재 소속에 체크 표시.
struct MoveToFolderSheet: View {
    let folders: [Folder]
    let currentFolderId: String?
    let onSelect: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                pickRow(title: String(localized: "전체 (폴더 없음)"), systemImage: "tray.full", id: nil)
                ForEach(folders) { folder in
                    pickRow(title: folder.name, systemImage: "folder", id: folder.id)
                }
            }
            .navigationTitle("폴더로 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func pickRow(title: String, systemImage: String, id: String?) -> some View {
        Button {
            onSelect(id)
            dismiss()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if currentFolderId == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
    }
}
