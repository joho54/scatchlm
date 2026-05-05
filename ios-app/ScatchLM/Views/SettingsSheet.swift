import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var responseLanguage = Config.responseLanguage

    var body: some View {
        NavigationStack {
            Form {
                Section("Feedback Language") {
                    TextField("e.g. Korean, English, 日本語", text: $responseLanguage)
                        .onChange(of: responseLanguage) { _, newValue in
                            Config.responseLanguage = newValue
                        }

                    Text("AI 피드백이 이 언어로 작성됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            try? await AuthService.shared.signOut()
                            dismiss()
                        }
                    } label: {
                        Text("Sign Out")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
