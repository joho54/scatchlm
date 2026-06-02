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

    @FocusState private var focused: Field?
    private enum Field { case email, code, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header

                    VStack(spacing: 14) {
                        switch step {
                        case .requestEmail:
                            emailField
                        case .enterCode:
                            codeField
                            passwordField
                        }

                        if let error { banner(error, tint: .red, icon: "exclamationmark.circle.fill") }
                        if let info  { banner(info,  tint: .green, icon: "checkmark.circle.fill") }

                        primaryButton

                        if step == .enterCode {
                            Button("코드 다시 받기") { Task { await sendCode() } }
                                .font(.callout)
                                .disabled(loading)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(24)
                .animation(.snappy, value: step)
                .animation(.default, value: error)
                .animation(.default, value: info)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear {
                if email.isEmpty { email = initialEmail }
                focused = .email
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: step == .requestEmail ? "lock.rotation" : "envelope.badge.shield.half.filled")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text("비밀번호 재설정")
                .font(.title2.bold())
            Text(step == .requestEmail
                 ? "가입에 사용한 이메일로 6자리 재설정 코드를 보내드려요."
                 : "\(email) 로 보낸 6자리 코드를 입력하세요.\n코드가 안 보이면 스팸함도 확인해 주세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Fields

    private var emailField: some View {
        TextField("이메일", text: $email)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused, equals: .email)
            .submitLabel(.send)
            .onSubmit { Task { await sendCode() } }
            .fieldStyle()
    }

    private var codeField: some View {
        TextField("6자리 코드", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.title3.monospacedDigit())
            .tracking(6)
            .multilineTextAlignment(.center)
            .focused($focused, equals: .code)
            .onChange(of: code) { _, v in
                // 숫자만, 최대 6자리.
                let digits = v.filter(\.isNumber)
                code = String(digits.prefix(6))
            }
            .fieldStyle()
    }

    private var passwordField: some View {
        SecureField("새 비밀번호 (6자 이상)", text: $newPassword)
            .textContentType(.newPassword)
            .focused($focused, equals: .password)
            .submitLabel(.done)
            .onSubmit { if canReset { Task { await resetPassword() } } }
            .fieldStyle()
    }

    // MARK: - Button

    private var primaryButton: some View {
        Button {
            focused = nil
            Task { step == .requestEmail ? await sendCode() : await resetPassword() }
        } label: {
            Group {
                if loading {
                    ProgressView().tint(.white)
                } else {
                    Text(step == .requestEmail ? "재설정 코드 받기" : "비밀번호 변경")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(loading || (step == .requestEmail ? email.isEmpty : !canReset))
    }

    private var canReset: Bool { code.count == 6 && newPassword.count >= 6 }

    // MARK: - Banner

    private func banner(_ text: String, tint: Color, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
            Text(text)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func sendCode() async {
        guard !email.isEmpty, !loading else { return }
        loading = true; error = nil; info = nil
        do {
            try await AuthService.shared.requestPasswordReset(email: email)
            step = .enterCode
            info = String(localized: "코드를 보냈어요. 이메일을 확인해 주세요.")
            focused = .code
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func resetPassword() async {
        guard canReset, !loading else { return }
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

// MARK: - Field 스타일 (재사용)

private extension View {
    func fieldStyle() -> some View {
        self
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
