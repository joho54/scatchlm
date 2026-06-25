import SwiftUI

/// discover 결과 리스트 — iPad/iPhone 공용 (docs/discover-feature-spec.md §4.2 B-3).
///
/// 각 항목: 제목 / level 칩 / format / why / 액션.
/// - PDF format → "서재에 추가": url 다운로드 → 기존 멀티파트 업로드 재사용(Track C-2).
/// - 웹페이지·강의코스 → "열기": 인앱 SafariView(인제스션 아님).
/// 0개면 `note`를 중앙에 표시.
struct DiscoverResultsView: View {
    let result: DiscoverResult
    /// 인제스션 성공 시 알림(서재 갱신 트리거용). 호출부에서 textbook 목록을 다시 읽을 수 있다.
    var onAdded: (() -> Void)? = nil

    @State private var ingest: [String: IngestState] = [:]
    @State private var safariURL: IdentifiedURL?

    enum IngestState: Equatable {
        case idle
        case working
        case added
        case failed(String)
    }

    var body: some View {
        Group {
            if result.recommendations.isEmpty {
                emptyState
            } else {
                List(result.recommendations) { item in
                    row(item)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $safariURL) { wrapped in
            SafariView(url: wrapped.url)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(result.note.isEmpty
                 ? "추천할 자료를 찾지 못했어요."
                 : result.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ item: DiscoverItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 6) {
                chip(item.level, system: "graduationcap.fill")
                chip(item.format, system: item.formatSymbol)
            }

            if !item.why.isEmpty {
                Text(item.why)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionButton(item)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func chip(_ text: String, system: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system).font(.caption2)
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func actionButton(_ item: DiscoverItem) -> some View {
        let state = ingest[item.url] ?? .idle
        if item.isPDF {
            switch state {
            case .added:
                Label("서재에 추가됨", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("추가하는 중…").font(.subheadline)
                }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg).font(.caption).foregroundStyle(.red)
                    Button { Task { await ingestPDF(item) } } label: {
                        Label("다시 시도", systemImage: "arrow.clockwise")
                    }
                    .font(.subheadline)
                }
            case .idle:
                Button { Task { await ingestPDF(item) } } label: {
                    Label("서재에 추가", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else {
            Button {
                if let url = item.parsedURL { safariURL = IdentifiedURL(url: url) }
            } label: {
                Label("열기", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func ingestPDF(_ item: DiscoverItem) async {
        guard let url = item.parsedURL else {
            ingest[item.url] = .failed("주소가 올바르지 않아요.")
            return
        }
        ingest[item.url] = .working
        appLog("discover", "ingest start", ["url": item.url])
        do {
            let local = try await PdfDownloader.download(from: url, suggestedName: item.title)
            defer { PdfDownloader.cleanup(local) }
            struct UploadResult: Decodable {
                let id: String
                let fileName: String
                enum CodingKeys: String, CodingKey { case id; case fileName }
            }
            let res: UploadResult = try await APIClient.shared.uploadFile("/pdf/upload", fileURL: local)
            appLog("discover", "ingest OK", ["id": res.id, "name": res.fileName])
            await MainActor.run {
                ingest[item.url] = .added
                onAdded?()
            }
        } catch is CancellationError {
            await MainActor.run { ingest[item.url] = .idle }
        } catch {
            appLogError("discover", "ingest failed", ["error": "\(error)"])
            let msg = (error as? LocalizedError)?.errorDescription
                ?? "서재에 추가하지 못했어요. 잠시 후 다시 시도해 주세요."
            await MainActor.run { ingest[item.url] = .failed(msg) }
        }
    }
}

/// SafariView 시트 표시용 Identifiable URL 래퍼.
struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
