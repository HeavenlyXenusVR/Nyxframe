import SwiftUI

struct RegisterView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var showingRegister: Bool

    @State private var username = ""
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Mirrors the backend's actual rules (lua/src/routes.lua's M.register:
    // 3-40 chars, [%w_.%-] only, and an 8-char password minimum) so an
    // invalid submission fails instantly instead of after a round trip.
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isUsernameValid: Bool {
        let count = trimmedUsername.count
        guard count >= 3 && count <= 40 else { return false }
        return trimmedUsername.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }
    private var isPasswordValid: Bool { password.count >= 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join the night shift")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("One account for the web gallery and this app.")
                .font(.subheadline)
                .foregroundStyle(Nyx.mist)
                .padding(.bottom, 4)

            NyxField(systemImage: "at", placeholder: "Username", text: $username, contentType: .username)
            if !trimmedUsername.isEmpty && !isUsernameValid {
                hint("3-40 characters: letters, numbers, \".\", \"_\", \"-\" only.")
            }
            NyxField(systemImage: "person", placeholder: "Display name (optional)", text: $displayName, contentType: .nickname)
            NyxField(systemImage: "envelope", placeholder: "Email (optional)", text: $email, contentType: .emailAddress, keyboard: .emailAddress)
            NyxField(systemImage: "key", placeholder: "Password", text: $password, isSecure: true, contentType: .newPassword)
            if !password.isEmpty && !isPasswordValid {
                hint("At least 8 characters.")
            }

            if let errorMessage {
                NyxFormError(message: errorMessage)
            }

            Button {
                Task { await register() }
            } label: {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Create Account")
                }
            }
            .buttonStyle(NyxPrimaryButtonStyle())
            .disabled(!isUsernameValid || !isPasswordValid || isLoading)
            .padding(.top, 4)

            Button {
                showingRegister = false
            } label: {
                (Text("Already have an account? ").foregroundColor(Nyx.mist) + Text("Log in").foregroundColor(.accentColor).bold())
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 2)
        }
        .padding(22)
        .nyxGlass(radius: Nyx.Radius.panel, elevated: true)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Nyx.mist)
            .padding(.leading, 4)
    }

    private func register() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await session.register(
                username: trimmedUsername,
                password: password,
                email: email.isEmpty ? nil : email,
                displayName: displayName.isEmpty ? nil : displayName
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
