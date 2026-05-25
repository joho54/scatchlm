import SwiftUI

struct FeedbackCardView: View {
    let feedback: FeedbackRecord
    var onRate: ((Int) -> Void)? = nil
    var onOpenDetailRating: (() -> Void)? = nil

    @State private var localRating: Int?

    private var parsed: AIResponse? {
        guard let data = feedback.content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIResponse.self, from: data)
    }

    private var currentRating: Int? { localRating ?? feedback.userRating }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(parsed?.displayText ?? feedback.content)
                .font(.system(size: 14))
                .lineSpacing(4)

            if feedback.serverFeedbackId != nil {
                HStack(spacing: 12) {
                    ratingButton(value: 1, systemName: "hand.thumbsup")
                    ratingButton(value: -1, systemName: "hand.thumbsdown")
                    Spacer()
                    Button(action: { onOpenDetailRating?() }) {
                        Text("자세히 알려주기")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: 0x5a6878))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(width: feedback.bboxWidth)
        .background(Color(hex: 0xfafbfc))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(hex: 0xe8ecf0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    @ViewBuilder
    private func ratingButton(value: Int, systemName: String) -> some View {
        let selected = currentRating == value
        Button(action: {
            localRating = value
            onRate?(value)
        }) {
            Image(systemName: selected ? "\(systemName).fill" : systemName)
                .font(.system(size: 16))
                .foregroundColor(selected ? (value > 0 ? Color(hex: 0x2e7d32) : Color(hex: 0xc62828)) : Color(hex: 0x8a98a8))
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
