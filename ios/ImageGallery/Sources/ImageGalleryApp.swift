import SwiftUI

@main
struct ImageGalleryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionStore()
    @StateObject private var biometricLock = BiometricLockService()
    @StateObject private var quickActionRouter = QuickActionRouter.shared
    @StateObject private var unreadCounts = UnreadCountsService()
    @StateObject private var uploadRecovery = UploadRecoveryService()
    @StateObject private var backgroundUploads = BackgroundUploadManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(biometricLock)
                .environmentObject(quickActionRouter)
                .environmentObject(unreadCounts)
                .environmentObject(uploadRecovery)
                .environmentObject(backgroundUploads)
        }
    }
}

/// Top-level chooser between the auth flow and the signed-in app shell.
/// Mirrors the web app's `ctx.user` gate in `frontend/src/App.jsx`.
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var biometricLock: BiometricLockService
    @EnvironmentObject private var unreadCounts: UnreadCountsService
    @EnvironmentObject private var uploadRecovery: UploadRecoveryService
    @EnvironmentObject private var backgroundUploads: BackgroundUploadManager
    @AppStorage("theme_mode") private var themeMode = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if biometricLock.isEnabled && !biometricLock.isUnlocked {
                BiometricLockView()
            } else if session.isBootstrapping {
                LaunchVeilView()
            } else if session.currentUser != nil {
                AppShellView()
                    .transition(.opacity)
            } else {
                AuthContainerView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: session.currentUser?.id)
        .preferredColorScheme(colorScheme)
        .tint(Color(hex: session.currentUser?.userSettings?.accentColor))
        .modifier(GalleryFontDesign(galleryFont: session.currentUser?.userSettings?.galleryFont))
        .background(NyxBackdrop(showsStars: false).ignoresSafeArea())
        // gallery_bg_color -- mirrors web's --gallery-bg-override. Handed to
        // the Nocturne backdrop (see NyxBackdrop) as an environment value,
        // which every screen paints behind itself via `.nyxScreen()` --
        // including List/Form screens, whose own opaque grouped background
        // `.nyxScreen()` hides, so the override now reaches those too.
        .environment(\.nyxBackdropHex, session.currentUser?.userSettings?.galleryBgColor)
        .environment(\.nyxReduceMotion, session.currentUser?.userSettings?.reduceMotion == true)
        // reduce_motion: nils out the animation on every transaction that
        // flows through this point in the tree, including ones descendant
        // views set with explicit withAnimation(...) calls -- the
        // documented way to suppress animations app-wide from one place
        // instead of threading a flag through every file that calls
        // withAnimation/.animation individually.
        .transaction { transaction in
            if session.currentUser?.userSettings?.reduceMotion == true {
                transaction.animation = nil
            }
        }
        .task {
            BadgeService.requestAuthorization()
            await session.bootstrap()
            await biometricLock.attemptUnlock()
            updatePolling()
            await ServerConfig.shared.refresh()
            BackgroundMusicService.shared.startIfNeeded()
            await uploadRecovery.checkPendingJobs()
        }
        .onChange(of: session.currentUser?.id) { _ in
            updatePolling()
        }
        // A chunked upload's transfer finishing (BackgroundUploadManager
        // hands off a job id to PendingUploadJobStore right as this fires)
        // is exactly the moment worth checking uploadJobStatus promptly,
        // rather than waiting for the next unrelated foreground transition
        // below -- see UploadRecoveryService's doc comment.
        .onChange(of: backgroundUploads.completionNotice) { _ in
            Task { await uploadRecovery.checkPendingJobs() }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    await session.refreshCurrentUser()
                    await biometricLock.attemptUnlock()
                    await unreadCounts.refresh()
                    await uploadRecovery.checkPendingJobs()
                }
            } else if newPhase == .background {
                biometricLock.lock()
            }
        }
        .alert(
            "Upload update",
            isPresented: Binding(
                get: { uploadRecovery.recoveredMessage != nil },
                set: { isPresented in if !isPresented { uploadRecovery.recoveredMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uploadRecovery.recoveredMessage ?? "")
        }
        // Sibling to the alert above, not a merge into it: this one covers
        // an upload's own transfer finishing/failing (BackgroundUploadManager),
        // the other covers the separate server-side finish job resolving
        // after the app was relaunched (UploadRecoveryService) -- see each
        // service's header comment. A single upload can raise either, or
        // neither, but never both for the same event.
        .alert(
            "Upload update",
            isPresented: Binding(
                get: { backgroundUploads.completionNotice != nil },
                set: { isPresented in if !isPresented { backgroundUploads.completionNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backgroundUploads.completionNotice ?? "")
        }
    }

    private var colorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func updatePolling() {
        if session.currentUser != nil {
            unreadCounts.startPolling()
        } else {
            unreadCounts.stopPolling()
            unreadCounts.reset()
        }
    }
}

/// `gallery_font` -- mirrors web's FONT_MAP (frontend/src/utils/
/// appearance.js): serif/mono/rounded/system map directly onto SwiftUI's
/// `Font.Design` cases. `.fontDesign(_:)` is iOS 16.1+ but this app's
/// deployment target is 16.0, so it's gated behind `#available` -- on 16.0
/// itself this is a no-op (system font design), not a crash or build error.
private struct GalleryFontDesign: ViewModifier {
    let galleryFont: String?

    func body(content: Content) -> some View {
        if #available(iOS 16.1, *) {
            content.fontDesign(design)
        } else {
            content
        }
    }

    @available(iOS 16.1, *)
    private var design: Font.Design {
        switch galleryFont {
        case "serif": return .serif
        case "mono": return .monospaced
        case "rounded": return .rounded
        default: return .default
        }
    }
}
