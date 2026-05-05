import SwiftUI

struct FeedbackCardView: View {
    let feedback: FeedbackRecord

    private var parsed: AIResponse? {
        guard let data = feedback.content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIResponse.self, from: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let parsed {
                // Recognized text
                if !parsed.recognizedText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "text.viewfinder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(parsed.recognizedText)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                    }

                    Rectangle()
                        .fill(Color(hex: 0xe8ecf0))
                        .frame(height: 1)
                }

                // Feedback
                Text(parsed.feedback)
                    .font(.system(size: 14))
                    .lineSpacing(4)

                // Summary
                if !parsed.summary.isEmpty {
                    Rectangle()
                        .fill(Color(hex: 0xe8ecf0))
                        .frame(height: 1)

                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(parsed.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(feedback.content)
                    .font(.system(size: 14))
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
}

// Color hex convenience
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
