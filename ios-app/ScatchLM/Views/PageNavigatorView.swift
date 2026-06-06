import SwiftUI
import PencilKit

struct PageNavigatorView: View {
    let pages: [NotePage]
    let currentIndex: Int
    let title: String
    let onSelect: (Int) -> Void
    let onAdd: () -> Void
    let onClose: () -> Void
    let onMove: (IndexSet, Int) -> Void
    let onDelete: (NotePage) -> Void
    let onEditMeta: () -> Void

    @State private var editMode: EditMode = .inactive

    private let thumbSize = CGSize(width: 160, height: 107)  // 가로형

    var body: some View {
        VStack(spacing: 0) {
            // 노트 제목 — 캔버스 위 떠 있던 제목을 여기로 옮김. 탭하면 노트 정보 편집.
            Button(action: onEditMeta) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            HStack(spacing: 8) {
                // 순서 변경(드래그 핸들) 모드 토글. 활성화 시 체크 아이콘 + 액센트로 "완료" 의미를 드러냄.
                // 편집모드에선 빨간 − 로 삭제도 가능.
                if pages.count > 1 {
                    Button {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        Image(systemName: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(editMode.isEditing ? Color.white : .primary)
                            .frame(width: 32, height: 32)
                            .background(editMode.isEditing ? Color.accentColor : Color.primary.opacity(0.06))
                            .clipShape(Circle())
                    }
                }
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { idx, page in
                        row(idx: idx, page: page)
                    }
                    .onMove(perform: onMove)
                    .onDelete { offsets in
                        if let i = offsets.first, pages.indices.contains(i) { onDelete(pages[i]) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
                .environment(\.defaultMinListRowHeight, 1)
                .onAppear {
                    guard pages.indices.contains(currentIndex) else { return }
                    proxy.scrollTo(pages[currentIndex].id, anchor: .center)
                }
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(width: 0.5)
        }
    }

    @ViewBuilder
    private func row(idx: Int, page: NotePage) -> some View {
        // 탭은 Button으로 처리 — .onTapGesture는 List의 스와이프/재정렬 제스처를 가로채 깨뜨린다.
        Button {
            onSelect(idx)
        } label: {
            PageThumbnail(
                page: page,
                index: idx,
                isCurrent: idx == currentIndex,
                size: thumbSize
            )
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            // 셀 전체를 패널과 같은 material로 채운다 → 드래그로 들어올린 셀이
            // 배경 없이 검은 사각형으로 폴백하던 문제 제거(셀 스냅샷이 프로스트를 포함).
            .background(.regularMaterial)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // 길게누르기 → 삭제(사용자 직관). 스와이프·편집모드 빨간 −는 위 .onDelete가 함께 제공.
        .contextMenu {
            Button(role: .destructive) {
                onDelete(page)
            } label: {
                Label("페이지 삭제", systemImage: "trash")
            }
        }
    }
}

private struct PageThumbnail: View {
    let page: NotePage
    let index: Int
    let isCurrent: Bool
    let size: CGSize

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorScheme == .dark ? Color(white: 0.12) : Color.white)

                if let img = renderThumbnail() {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isCurrent ? Color.accentColor : Color.black.opacity(0.08),
                            lineWidth: isCurrent ? 2.5 : 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .contentShape(Rectangle())
    }

    private func renderThumbnail() -> UIImage? {
        guard let data = page.drawingData,
              let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty else { return nil }

        // 캔버스 상단을 기준으로 잘라낸 미리보기.
        // 실제 캔버스 폭은 가변이지만 800pt 기준으로 가정하고 3:4 비율로 crop.
        let sourceWidth: CGFloat = 800
        let sourceHeight = sourceWidth * (size.height / size.width)
        let rect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        let scale = size.width / sourceWidth

        let isDark = colorScheme == .dark
        let img = drawing.image(from: rect, scale: scale)

        if isDark {
            // 다크모드: 잉크가 흰색이라 그대로 노출 (배경은 ZStack에서 처리)
            return img
        }
        return img
    }
}
