import SwiftUI

/// 비밀번호 재설정 (OTP 인앱 플로우, D-? / launch-readiness).
/// 1) 이메일 입력 → resetPasswordForEmail (6자리 OTP 발송)
/// 2) OTP + 새 비밀번호 입력 → verifyOTP(.recovery) → update(user: password)
/// URL scheme·호스팅 웹 없이 전부 앱 안에서 완료된다.
struct ForgotPasswordView: View {
    /// 로그인 화면에서 이미 입력한 이메일을 이어받는다(비어 있어도 됨).
    var initialEmail: String = ""

    @Environment(\.dismiss) private var dismiss

    private enum Step { case requestEmail, enterCode }
    @State private var step: Step = .requestEmail

    @State private var email = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var error: String?
    @State private var info: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .requestEmail:
                    Section {
                        TextField("이메일", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("가입에 사용한 이메일로 6자리 재설정 코드를 보내드려요.")
                    }

                    Section {
                        Button {
                            Task { await sendCode() }
                        } label: {
                            buttonLabel(String(localized: "재설정 코드 받기"))
                        }
                        .disabled(loading || email.isEmpty)
                    }

                case .enterCode:
                    Section {
                        TextField("6자리 코드", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        SecureField("새 비밀번호 (6자 이상)", text: $newPassword)
                            .textContentType(.newPassword)
                    } footer: {
                        Text("\(email) 로 보낸 코드를 입력하세요. 코드가 안 보이면 스팸함도 확인해 주세요.")
                    }

                    Section {
                        Button {
                            Task { await resetPassword() }
                        } label: {
                            buttonLabel(String(localized: "비밀번호 변경"))
                        }
                        .disabled(loading || code.isEmpty || newPassword.count < 6)

                        Button("코드 다시 받기") {
                            Task { await sendCode() }
                        }
                        .disabled(loading)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
                if let info {
                    Section { Text(info).foregroundStyle(.secondary).font(.callout) }
                }
            }
            .navigationTitle("비밀번호 재설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear { if email.isEmpty { email = initialEmail } }
        }
    }

    @ViewBuilder
    private func buttonLabel(_ title: String) -> some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            Text(title).frame(maxWidth: .infinity)
        }
    }

    private func sendCode() async {
        loading = true; error = nil; info = nil
        do {
            try await AuthService.shared.requestPasswordReset(email: email)
            step = .enterCode
            info = String(localized: "코드를 보냈어요. 이메일을 확인해 주세요.")
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func resetPassword() async {
        loading = true; error = nil; info = nil
        do {
            try await AuthService.shared.completePasswordReset(
                email: email, token: code.trimmingCharacters(in: .whitespaces), newPassword: newPassword)
            // 성공 시 복구 세션으로 로그인됨 → 시트 닫으면 자동으로 앱 진입.
            dismiss()
        } catch {
            self.error = String(localized: "코드가 올바르지 않거나 만료됐어요. 다시 시도해 주세요.")
        }
        loading = false
    }
}
