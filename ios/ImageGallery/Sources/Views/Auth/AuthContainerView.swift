import SwiftUI

/// Signed-out entry. A full-bleed night sky with the moon mark and a
/// single glass card that swaps between log in and register, instead of a
/// bare system `Form` under a navigation title.
struct AuthContainerView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var showingRegister = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    brandMark
                        .padding(.top, 48)

                    if let lastError = session.lastError {
                        // Explains *why* the app dropped back to login --
                        // most commonly an expired session, but also the
                        // only place a suspended account's ban reason/
                        // expiry actually surfaces.
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.pink)
                            Text(lastError).font(.footnote)
                            Spacer(minLength: 0)
                            Button {
                                session.lastError = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Dismiss")
                        }
                        .padding(14)
                        .nyxGlass(radius: 18)
                    }

                    Group {
                        if showingRegister {
                            RegisterView(showingRegister: $showingRegister)
                                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                        } else {
                            LoginView(showingRegister: $showingRegister)
                                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: showingRegister)

                    NavigationLink {
                        BackendSettingsView()
                    } label: {
                        Label("Server settings", systemImage: "server.rack")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Nyx.mist)
                    }
                    .padding(.bottom, 32)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(
                ZStack {
                    NyxBackdrop(showsStars: false)
                    StarfieldView(density: 120)
                }
                .ignoresSafeArea()
            )
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var brandMark: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.55), .clear], center: .center, startRadius: 4, endRadius: 70))
                    .frame(width: 140, height: 140)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 16)
            }
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Nyxframe")
                    .font(Nyx.display(40))
                Text("Your archive, after dark.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Nyx.mist)
            }
        }
    }
}

/// A glass text field with a leading glyph, used by the auth forms.
struct NyxField: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(focused ? Color.accentColor : Nyx.mist)
                .frame(width: 20)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboard)
                }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Nyx.hairline, lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// Inline red notice inside an auth card.
struct NyxFormError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.pink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
