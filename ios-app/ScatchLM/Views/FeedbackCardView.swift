import SwiftUI

struct FeedbackCardView: View {
    let feedback: FeedbackRecord

    private var parsed: AIResponse? {
        guard let data = feedback.content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIResponse.self, from: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(parsed?.displayText ?? feedback.content)
                .font(.system(size: 14))
                .lineSpacing(4)
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
