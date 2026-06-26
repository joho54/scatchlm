import SwiftUI

/// 그리드 상단 컴팩트 프롬프트 바 (docs/discover-feature-spec.md §4.2 진입점).
///
/// 한 줄짜리 검색창형 pill — 리딩 아이콘 + placeholder가 곧 CTA. 탭하면 discover 시트를 연다
/// (입력은 시트 안에서). 노트 필터링용 `.searchable`과는 위치(그리드 상단)·아이콘·문구로 분리.
/// iPad(`HomeView`)/iPhone(`PhoneHomeView`) 공용.
struct DiscoverPromptBar: View {
    /// 서재 기반 도전 분야 제안 topic(있으면 표시). 없으면 정적 CTA.
    var suggestion: String? = nil
    var onTap: () -> Void

    private var label: String { suggestion ?? "새로 도전해볼 분야 찾기…" }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.magnifyingglass")
                    .foregroundStyle(.tint)
                Text(label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("새로 도전해볼 분야 찾기")
        .accessibilityHint("서재와 이어지는 새 분야를 추천하고, 탭하면 무료 공개 자료를 찾습니다")
    }
}
