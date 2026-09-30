import AVFoundation
import SwiftUI

@main
struct NyxframeTVApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var unreadCounts = UnreadCountsService()
    @StateObject private var music = TVBackgroundMusic.shared
    @StateObject private var tabs = TVTabRouter()

    init() {
        // Music starts before anything else -- before the backend origin
        // resolves, before sign-in -- so the very first thing a viewer
        // hears on launch is the soundtrack, with no interaction needed.
        Task { @MainActor in
            TVBackgroundMusic.shared.start()
            TVSiteBackground.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(session)
                .environmentObject(unreadCounts)
                .environmentObject(music)
                .environmentObject(tabs)
                .preferredColorScheme(.dark)
        }
    }
}

enum TVTab: Hashable {
    case discover, trending, search, library, inbox, account
}

@MainActor
final class TVTabRouter: ObservableObject {
    @Published var selection: TVTab = .discover
}

struct TVRootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var unreadCounts: UnreadCountsService
    @EnvironmentObject private var music: TVBackgroundMusic
    @EnvironmentObject private var tabs: TVTabRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.isBootstrapping {
                TVSplashView()
            } else {
                TabView(selection: $tabs.selection) {
                    TVTabStack { DiscoverScreen() }
                        .tabItem { Label("Discover", systemImage: "sparkles") }
                        .tag(TVTab.discover)
                    TVTabStack { TrendingScreen() }
                        .tabItem { Label("Trending", systemImage: "chart.line.uptrend.xyaxis") }
                        .tag(TVTab.trending)
                    TVTabStack { SearchScreen() }
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(TVTab.search)
                    TVTabStack { LibraryScreen() }
                        .tabItem { Label("Library", systemImage: "rectangle.stack") }
                        .tag(TVTab.library)
                    TVTabStack { InboxScreen() }
                        .tabItem { Label(inboxTitle, systemImage: "bell") }
                        .tag(TVTab.inbox)
                    TVTabStack { AccountScreen() }
                        .tabItem { Label(session.currentUser == nil ? "Sign In" : "Account", systemImage: "person.crop.circle") }
                        .tag(TVTab.account)
                }
            }
        }
        // The remote's play/pause button toggles the soundtrack while
        // browsing. (Inside the video player, AVKit keeps the button for
        // the video itself.)
        .onPlayPauseCommand { music.toggle() }
        .tint(Color(hex: session.currentUser?.userSettings?.accentColor ?? Appearance.defaultAccentHex))
        .task {
            music.start()
            await session.bootstrap()
            updatePolling()
        }
        .onChange(of: session.currentUser?.id) { _, _ in updatePolling() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            music.ensurePlaying()
            TVSiteBackground.shared.resync()
            Task {
                await session.refreshCurrentUser()
                await unreadCounts.refresh()
            }
        }
    }

    private var inboxTitle: String {
        let total = unreadCounts.notifications + unreadCounts.messages
        return total > 0 ? "Inbox (\(total))" : "Inbox"
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

struct TVSplashView: View {
    @EnvironmentObject private var music: TVBackgroundMusic

    var body: some View {
        VStack(spacing: 36) {
            HStack(spacing: 24) {
                RoundedRectangle(cornerRadius: 28)
                    .fill(TVTheme.accent)
                    .frame(width: 120, height: 120)
                    .overlay(Text("N").font(.system(size: 72, weight: .heavy)).foregroundStyle(.black.opacity(0.85)))
                Text("Nyxframe").font(.system(size: 96, weight: .heavy))
            }
            ProgressView()
            if let title = music.currentTitle {
                Label(title, systemImage: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvScreenBackground()
    }
}

/// A small "now playing" line for screens that show the soundtrack.
struct TVNowPlayingBadge: View {
    @EnvironmentObject private var music: TVBackgroundMusic

    var body: some View {
        switch music.state {
        case .playing:
            if let title = music.currentTitle {
                Label(title, systemImage: "music.note").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case .silencedForVideo:
            Label("Music paused for video", systemImage: "speaker.slash").font(.caption).foregroundStyle(.secondary)
        case .off:
            Label("Music off", systemImage: "speaker.slash").font(.caption).foregroundStyle(.secondary)
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .idle, .loading:
            EmptyView()
        }
    }
}
