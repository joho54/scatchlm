import SwiftUI

/// 동기화 상태 인디케이터 + 수동 새로고침 (D-4).
/// 탭하면 즉시 push→pull(coalesced)을 요청한다. C-6 reachability 상태(offline)도 표시.
struct SyncStatusIndicator: View {
    @State private var sync = SyncService.shared

    var body: some View {
        Button {
            sync.requestSync()
        } label: {
            switch sync.status {
            case .idle:
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.secondary)
            case .syncing:
                ProgressView()
                    .controlSize(.small)
            case .offline:
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.orange)
            case .error:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.red)
            }
        }
        .accessibilityLabel(String(localized: "동기화"))
    }
}
