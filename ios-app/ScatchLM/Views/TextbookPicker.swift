import SwiftUI

/// 서재(교재) 목록 데이터 — 검색·페이지네이션·soft delete/복구를 한 곳에 모은다.
/// CreateNoteSheet / NoteMetaSheet의 교재 피커가 공유한다(전용 서재 화면은 없음).
@MainActor
@Observable
final class TextbookStore {
    var items: [TextbookListItem] = []
    var query: String = ""
    var showDeleted = false
    var loading = false
    var loadingMore = false

    private let pageSize = 30
    private var offset = 0
    private var hasMore = false
    private var loadedOnce = false
    private var searchTask: Task<Void, Never>?

    /// onAppear에서 1회만 초기 로드.
    func loadInitialIfNeeded() {
        guard !loadedOnce else { return }
        loadedOnce = true
        Task { await reload() }
    }

    /// 검색어 변경 — 300ms 디바운스 후 처음부터 다시 로드.
    func onQueryChange() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await reload()
        }
    }

    func setShowDeleted(_ value: Bool) {
        guard value != showDeleted else { return }
        showDeleted = value
        Task { await reload() }
    }

    /// 업로드 직후 새 교재를 목록 맨 앞에 노출(서버 재조회 없이 즉시 반영).
    func prepend(_ item: TextbookListItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
    }

    func softDelete(_ tb: TextbookListItem) {
        Task {
            do {
                try await APIClient.shared.deleteTextbook(tb.id)
                items.removeAll { $0.id == tb.id }
            } catch {
                appLogError("textbook-store", "delete failed", ["id": tb.id, "error": "\(error)"])
            }
        }
    }

    func restore(_ tb: TextbookListItem) {
        Task {
            do {
                _ = try await APIClient.shared.restoreTextbook(tb.id)
                items.removeAll { $0.id == tb.id }   // 복구함에서 사라짐(정상 목록으로 이동)
            } catch {
                appLogError("textbook-store", "restore failed", ["id": tb.id, "error": "\(error)"])
            }
        }
    }

    /// 마지막 근처 행이 보이면 다음 페이지 선로드(무한 스크롤).
    func loadMoreIfNeeded(current: TextbookListItem) {
        guard hasMore, !loadingMore, !loading else { return }
        guard let idx = items.firstIndex(where: { $0.id == current.id }) else { return }
        if idx >= items.count - 5 {
            Task { await loadMore() }
        }
    }

    private func reload() async {
        loading = true
        do {
            let res = try await fetch(offset: 0)
            items = res.items
            offset = res.items.count
            hasMore = res.hasMore
        } catch {
            appLogError("textbook-store", "reload failed", ["error": "\(error)"])
        }
        loading = false
    }

    private func loadMore() async {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        do {
            let res = try await fetch(offset: offset)
            // 페이지 경계가 삭제/업로드로 흔들릴 수 있어 id 중복 방어.
            let existing = Set(items.map(\.id))
            items.append(contentsOf: res.items.filter { !existing.contains($0.id) })
            offset += res.items.count
            hasMore = res.hasMore
        } catch {
            appLogError("textbook-store", "loadMore failed", ["error": "\(error)"])
        }
        loadingMore = false
    }

    private func fetch(offset: Int) async throws -> TextbookListResponse {
        try await APIClient.shared.get("/pdf/textbooks", query: [
            "q": query.trimmingCharacters(in: .whitespacesAndNewlines),
            "limit": "\(pageSize)",
            "offset": "\(offset)",
            "deleted": showDeleted ? "true" : "false",
        ])
    }
}

/// 교재 한 행의 라벨(아이콘 + 파일명 + 페이지/OCR 칩 + 선택 체크).
struct TextbookRowLabel: View {
    let tb: TextbookListItem
    let isSelected: Bool
    var dimmed: Bool = false

    var body: some View {
        HStack {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(isSelected ? .white : .purple)
                .frame(width: 32, height: 32)
                .background(isSelected ? Color.purple : Color.purple.opacity(0.1))
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

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.purple)
            }
        }
        .opacity(dimmed ? 0.45 : 1)
    }
}

/// 교재 섹션 본문 — 검색창·목록(스와이프 삭제/복구)·삭제함 토글·업로드 버튼.
/// Form의 Section 안에 그대로 펼쳐 넣는다(섹션 컨테이너는 호출부 소유).
struct TextbookPickerBody: View {
    @Bindable var store: TextbookStore
    let selectedId: String?
    let onSelect: (TextbookListItem) -> Void
    let onUpload: () -> Void
    let uploading: Bool

    var body: some View {
        // 검색창
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("교재 검색", text: $store.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: store.query) { _, _ in store.onQueryChange() }
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                    store.onQueryChange()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }

        if store.loading {
            HStack { Spacer(); ProgressView(); Spacer() }
        } else if store.items.isEmpty {
            Text(emptyText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.items) { tb in
                row(tb)
                    .onAppear { store.loadMoreIfNeeded(current: tb) }
            }
            if store.loadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }

        Toggle(isOn: Binding(
            get: { store.showDeleted },
            set: { store.setShowDeleted($0) }
        )) {
            Label("삭제된 교재", systemImage: "trash")
                .font(.subheadline)
        }

        if !store.showDeleted {
            Button(action: onUpload) {
                HStack {
                    Image(systemName: "arrow.up.doc")
                    Text(uploading ? "업로드 중…" : "새 PDF 업로드")
                }
            }
            .disabled(uploading)
        }
    }

    private var emptyText: LocalizedStringKey {
        if store.showDeleted { return "삭제된 교재가 없어요" }
        return store.query.isEmpty ? "교재가 없어요" : "검색 결과가 없어요"
    }

    @ViewBuilder
    private func row(_ tb: TextbookListItem) -> some View {
        Button {
            guard !store.showDeleted else { return }   // 삭제함에선 탭 선택 비활성
            onSelect(tb)
        } label: {
            TextbookRowLabel(tb: tb, isSelected: selectedId == tb.id, dimmed: store.showDeleted)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if store.showDeleted {
                Button { store.restore(tb) } label: {
                    Label("복구", systemImage: "arrow.uturn.backward")
                }
                .tint(.blue)
            } else {
                Button(role: .destructive) { store.softDelete(tb) } label: {
                    Label("삭제", systemImage: "trash")
                }
            }
        }
    }
}
