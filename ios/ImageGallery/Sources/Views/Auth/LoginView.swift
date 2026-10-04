import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var showingRegister: Bool

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingTwoFactorToken: String?

    var body: some View {
        if let pendingTwoFactorToken {
            TwoFactorView(pendingToken: pendingTwoFactorToken) {
                self.pendingTwoFactorToken = nil
            }
        } else {
            loginForm
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome back")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Sign in to pick up where you left off.")
                .font(.subheadline)
                .foregroundStyle(Nyx.mist)
                .padding(.bottom, 4)

            NyxField(systemImage: "person", placeholder: "Username", text: $username, contentType: .username)
            NyxField(systemImage: "key", placeholder: "Password", text: $password, isSecure: true, contentType: .password)
                .onSubmit { Task { await login() } }

            if let errorMessage {
                NyxFormError(message: errorMessage)
            }

            Button {
                Task { await login() }
            } label: {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Log In")
                }
            }
            .buttonStyle(NyxPrimaryButtonStyle())
            .disabled(username.isEmpty || password.isEmpty || isLoading)
            .padding(.top, 4)

            Button {
                showingRegister = true
            } label: {
                (Text("New here? ").foregroundColor(Nyx.mist) + Text("Create an account").foregroundColor(.accentColor).bold())
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 2)
        }
        .padding(22)
        .nyxGlass(radius: Nyx.Radius.panel, elevated: true)
    }

    private func login() async {
        guard !username.isEmpty, !password.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await session.login(username: username, password: password)
            if response.needs2fa == true, let token = response.pendingToken {
                pendingTwoFactorToken = token
            }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}
