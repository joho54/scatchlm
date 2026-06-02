import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("ScatchLM")
                .font(.largeTitle.bold())

            Text("Handwriting-based language learning")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 360)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Button {
                Task { await handleAuth() }
            } label: {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(isSignUp ? "Sign Up" : "Sign In")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: 360)
            .disabled(loading || email.isEmpty || password.isEmpty)

            Button(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up") {
                isSignUp.toggle()
                error = nil
            }
            .font(.footnote)

            HStack {
                VStack { Divider() }
                Text("or").font(.caption).foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .frame(maxWidth: 360)

            Button {
                Task { await handleGoogleSignIn() }
            } label: {
                Label("Continue with Google", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: 360)
            .disabled(loading)

            // Sign in with Apple (Guideline 4.8 대응)
            Button {
                Task { await handleAppleSignIn() }
            } label: {
                Label("Sign in with Apple", systemImage: "applelogo")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .foregroundStyle(.white)
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 360)
            .disabled(loading)

            Spacer()
        }
        .padding()
    }

    private func handleAuth() async {
        loading = true
        error = nil
        do {
            if isSignUp {
                try await AuthService.shared.signUp(email: email, password: password)
                try await AuthService.shared.signIn(email: email, password: password)
            } else {
                try await AuthService.shared.signIn(email: email, password: password)
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func handleAppleSignIn() async {
        loading = true
        error = nil
        do {
            try await AuthService.shared.signInWithApple()
        } catch let authError as ASAuthorizationError where authError.code == .canceled {
            // 사용자가 취소 — 무시
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func handleGoogleSignIn() async {
        loading = true
        error = nil
        do {
            try await AuthService.shared.signInWithGoogle()
        } catch is CancellationError {
            // 사용자가 시트를 닫음 — 무시
        } catch {
            // ASWebAuthenticationSession 사용자 취소도 조용히 처리
            let ns = error as NSError
            if !(ns.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && ns.code == 1) {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }
}
