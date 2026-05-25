import SwiftUI
import PencilKit

struct PageNavigatorView: View {
    let pages: [NotePage]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    let onAdd: () -> Void
    let onClose: () -> Void

    private let thumbSize = CGSize(width: 160, height: 107)  // 가로형

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("페이지")
                    .font(.headline)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { idx, page in
                            PageThumbnail(
                                page: page,
                                index: idx,
                                isCurrent: idx == currentIndex,
                                size: thumbSize
                            )
                            .id(idx)
                            .onTapGesture { onSelect(idx) }
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    proxy.scrollTo(currentIndex, anchor: .center)
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
