import SwiftUI

/// 그리드 상단 컴팩트 프롬프트 바 (docs/discover-feature-spec.md §4.2 진입점).
///
/// 한 줄짜리 검색창형 pill — 리딩 아이콘 + placeholder가 곧 CTA. 탭하면 discover 시트를 연다
/// (입력은 시트 안에서). 노트 필터링용 `.searchable`과는 위치(그리드 상단)·아이콘·문구로 분리.
/// iPad(`HomeView`)/iPhone(`PhoneHomeView`) 공용.
struct DiscoverPromptBar: View {
    /// 서재 기반 Haiku 제안(있으면 표시). 없으면 정적 CTA.
    var suggestion: String? = nil
    var onTap: () -> Void

    private var label: String { suggestion ?? "공부할 자료 찾기…" }

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
        .accessibilityLabel("공부할 자료 찾기")
        .accessibilityHint("주제를 입력하면 무료 공개 학습자료를 추천합니다")
    }
}
