import SwiftUI

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
}
