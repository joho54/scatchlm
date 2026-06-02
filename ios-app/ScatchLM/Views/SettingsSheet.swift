import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var responseLanguage = Config.responseLanguage
    @State private var mathRenderMode = Config.mathRenderMode

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

                Section("수식 렌더링") {
                    Picker("수식 렌더링", selection: $mathRenderMode) {
                        ForEach(Config.MathRenderMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mathRenderMode) { _, newValue in
                        Config.mathRenderMode = newValue
                    }

                    Text("자동: 수식이 있으면 KaTeX로 렌더. 수식 안 보기는 가볍게 텍스트만 표시합니다.")
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
