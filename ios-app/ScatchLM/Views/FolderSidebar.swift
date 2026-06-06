import SwiftUI

/// 홈 화면 좌측 폴더 사이드바 (note-folders-spec §4.5).
/// "전체"(nil) + 폴더 목록(sort_order 순). 선택 항목 하이라이트, 폴더 행 contextMenu로
/// 이름변경/삭제, 하단 "+ 폴더" 버튼.
struct FolderSidebar: View {
    let folders: [Folder]
    @Binding var selectedFolderId: String?
    /// 폴더별 노트 수(검색 무시, 전체 기준). nil = "전체".
    let noteCount: (String?) -> Int
    let onAddFolder: () -> Void
    let onRename: (Folder) -> Void
    let onDelete: (Folder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(title: String(localized: "전체"), systemImage: "tray.full",
                        id: nil, count: noteCount(nil))
                    if !folders.isEmpty {
                        Divider().padding(.vertical, 6)
                    }
                    ForEach(folders) { folder in
                        row(title: folder.name, systemImage: "folder",
                            id: folder.id, count: noteCount(folder.id))
                            .contextMenu {
                                Button { onRename(folder) } label: {
                                    Label("이름 변경", systemImage: "pencil")
                                }
                                Button(role: .destructive) { onDelete(folder) } label: {
                                    Label("삭제", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(8)
            }
            Divider()
            Button(action: onAddFolder) {
                Label("폴더", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 220)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(title: String, systemImage: String, id: String?, count: Int) -> some View {
        let selected = selectedFolderId == id
        Button {
            selectedFolderId = id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 20)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
