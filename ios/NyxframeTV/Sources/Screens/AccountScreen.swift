import SwiftUI

/// Sign-in (with two-factor) when signed out; the viewer's account,
/// soundtrack controls and playback settings when signed in.
struct AccountScreen: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                if let user = session.currentUser {
                    AccountSummary(user: user)
                } else {
                    SignInForm()
                }
                MusicSettings()
                PlaybackSettings()
                AboutSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvScreenBackground()
    }
}

// MARK: - Sign in

private struct SignInForm: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var tabs: TVTabRouter
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var pendingToken: String?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(pendingToken == nil ? "Sign in" : "Two-factor code").font(.system(size: 64, weight: .heavy))
            Text(pendingToken == nil
                 ? "Use your Nyxframe username and password. You can browse, watch and listen without an account."
                 : "Enter the 6-digit code from your authenticator app, or a recovery code.")
                .foregroundStyle(.secondary)
            if let message = errorMessage ?? session.lastError {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 20) {
                if pendingToken == nil {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(signIn)
                    Button(action: signIn) {
                        Label(isWorking ? "Signing in…" : "Sign In", systemImage: "arrow.right.circle.fill")
                    }
                    .disabled(isWorking || username.isEmpty || password.isEmpty)
                } else {
                    TextField("Code", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.asciiCapable)
                        .onSubmit(verify)
                    HStack(spacing: 24) {
                        Button(action: verify) {
                            Label(isWorking ? "Verifying…" : "Verify", systemImage: "checkmark.shield")
                        }
                        .disabled(isWorking || code.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Start Over") {
                            pendingToken = nil
                            code = ""
                            errorMessage = nil
                        }
                    }
                }
            }
            .frame(maxWidth: 900)
            .focusSection()
            Text("New to Nyxframe? Create an account on the website or the iPhone app, then sign in here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func signIn() {
        guard !isWorking, !username.isEmpty, !password.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let response = try await session.login(username: username.trimmingCharacters(in: .whitespaces), password: password)
                if response.needs2fa == true, let token = response.pendingToken {
                    pendingToken = token
                } else if session.currentUser != nil {
                    password = ""
                    tabs.selection = .discover
                } else {
                    errorMessage = "Sign-in didn't complete. Please try again."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func verify() {
        guard let pendingToken, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await session.completeTwoFactor(pendingToken: pendingToken, code: code.trimmingCharacters(in: .whitespaces))
                self.pendingToken = nil
                code = ""
                password = ""
                tabs.selection = .discover
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Signed in

private struct AccountSummary: View {
    let user: GalleryUser
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var navigator: TVNavigator
    @State private var confirmingSignOut = false

    var body: some View {
        HStack(spacing: 48) {
            TVAvatar(urlString: user.avatarUrl, name: user.displayName ?? user.username, size: 180)
            VStack(alignment: .leading, spacing: 12) {
                Text(user.displayName?.nilIfEmpty ?? user.username).font(.system(size: 56, weight: .heavy))
                Text("@\(user.username)").foregroundStyle(.secondary)
                if user.ageVerifiedAt == nil {
                    Label("Age not verified -- 18+ posts stay hidden. Verify on the website.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    Button {
                        navigator.push(.user(user.username))
                    } label: {
                        Label("View My Profile", systemImage: "person.crop.square")
                    }
                    Button(role: .destructive) {
                        confirmingSignOut = true
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                .padding(.top, 12)
            }
        }
        .focusSection()
        .confirmationDialog("Sign out of Nyxframe on this Apple TV?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) { Task { await session.logout() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Settings

private struct MusicSettings: View {
    @EnvironmentObject private var music: TVBackgroundMusic

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Background music").font(.title3.bold())
            Text("Plays around the clock. It fades out when a video starts and fades back in when the video ends. The remote's Play/Pause button also turns it on or off while browsing.")
                .font(.caption).foregroundStyle(.secondary)
            TVNowPlayingBadge()
            HStack(spacing: 24) {
                Button {
                    music.toggle()
                } label: {
                    Label(music.isEnabled ? "Music On" : "Music Off", systemImage: music.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                Button {
                    music.volume = (music.volume - 0.1).rounded(toPlaces: 1)
                } label: {
                    Label("Quieter", systemImage: "minus")
                }
                .disabled(!music.isEnabled || music.volume <= 0.05)
                Text("Volume \(Int((music.volume * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 220)
                Button {
                    music.volume = (music.volume + 0.1).rounded(toPlaces: 1)
                } label: {
                    Label("Louder", systemImage: "plus")
                }
                .disabled(!music.isEnabled || music.volume >= 0.95)
                Button {
                    music.skip()
                } label: {
                    Label("Next Track", systemImage: "forward.fill")
                }
                .disabled(!music.isEnabled || music.trackCount < 2)
            }
            .focusSection()
            if music.trackCount > 0 {
                Text("\(music.trackCount) track\(music.trackCount == 1 ? "" : "s") in rotation").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaybackSettings: View {
    @State private var quality = PlaybackPreferences.quality

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Video quality").font(.title3.bold())
            Text("Used when a video starts. You can also change it from the player's transport bar.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(TVVideoURLs.qualities, id: \.0) { option in
                    TVPill(title: option.1, isSelected: quality == option.0) {
                        quality = option.0
                        PlaybackPreferences.quality = option.0
                    }
                }
            }
            .focusSection()
        }
    }
}

private struct AboutSection: View {
    @State private var origin = LiveConfigService.shared.currentOrigin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About").font(.title3.bold())
            Text("Nyxframe for Apple TV \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Label(origin.isEmpty ? "Looking for the server…" : origin, systemImage: "server.rack")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            origin = await LiveConfigService.shared.refresh()
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
