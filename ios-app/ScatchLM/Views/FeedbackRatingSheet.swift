import SwiftUI

/// 평가 입력 폼 — sheet에도, navigation push에도 재사용 가능 (자체 NavigationStack 없음)
struct RatingFormView: View {
    let feedbackId: String
    let initialRating: Int
    let onSubmit: (Int, [String], String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rating: Int
    @State private var selectedTags: Set<String> = []
    @State private var comment: String = ""

    init(feedbackId: String, initialRating: Int, onSubmit: @escaping (Int, [String], String?) -> Void) {
        self.feedbackId = feedbackId
        self.initialRating = initialRating
        self.onSubmit = onSubmit
        _rating = State(initialValue: initialRating)
    }

    private let allTags: [(key: String, label: String)] = [
        ("wrong_language", String(localized: "언어 오류")),
        ("tone_off", String(localized: "어조 부적절")),
        ("factually_wrong", String(localized: "사실 오류")),
        ("too_long", String(localized: "너무 김")),
        ("too_short", String(localized: "너무 짧음")),
        ("unhelpful", String(localized: "도움 안 됨")),
        ("other", String(localized: "기타")),
    ]

    var body: some View {
        Form {
            Section("평가") {
                Picker("", selection: $rating) {
                    Text("👍 좋음").tag(1)
                    Text("👎 아쉬움").tag(-1)
                }
                .pickerStyle(.segmented)
            }

            Section("사유 (복수 선택)") {
                let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(allTags, id: \.key) { tag in
                        tagChip(key: tag.key, label: tag.label)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("코멘트 (선택)") {
                TextEditor(text: $comment)
                    .frame(minHeight: 100)
            }
        }
        .navigationTitle("피드백 평가")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("제출") {
                    let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(rating, Array(selectedTags), trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func tagChip(key: String, label: String) -> some View {
        let selected = selectedTags.contains(key)
        Button(action: {
            if selected { selectedTags.remove(key) } else { selectedTags.insert(key) }
        }) {
            Text(label)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.15) : Color(hex: 0xeef1f4))
                .foregroundColor(selected ? Color.accentColor : Color(hex: 0x4a5868))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Sheet 컨테이너 — NoteView처럼 sheet으로 띄울 때 사용
struct FeedbackRatingSheet: View {
    let feedbackId: String
    let initialRating: Int
    let onSubmit: (Int, [String], String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RatingFormView(feedbackId: feedbackId, initialRating: initialRating, onSubmit: onSubmit)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("취소") { dismiss() }
                    }
                }
        }
    }
}
