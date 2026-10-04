import SwiftUI

/// Following / Liked feeds — mirrors the web app's FeedPage.jsx (mode
/// "following"/"liked"), both newly wired up now that the backend actually
/// serves GET /api/feed/following and GET /api/me/likes. Kept as one screen
/// with a segmented switch rather than two, matching how TrendingView
/// already handles its own window switch inline.
struct FollowingLikedView: View {
    enum Mode: String, CaseIterable {
        case following = "Following"
        case liked = "Liked"
    }

    @State private var mode: Mode
    @State private var items: [MediaItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var quickActionRouter: QuickActionRouter


    init(mode: Mode = .following) {
        _mode = State(initialValue: mode)
    }

    var body: some View {
        ScrollView {
            Picker("Feed", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: mode) { _ in Task { await load() } }

            if let errorMessage {
                InlineErrorView(message: errorMessage) { await load() }
            }

            NyxMediaGrid(items: items)

            if items.isEmpty && !isLoading {
                ContentUnavailableCompat(
                    title: mode == .following ? "No posts from people you follow yet" : "Nothing liked yet",
                    systemImage: mode == .following ? "person.2" : "heart",
                    hint: mode == .following
                        ? "Follow a few creators and their newest posts collect here."
                        : "Anything you like while browsing collects here."
                ) {
                    if mode == .following {
                        // Search is a push: it's a screen this stack
                        // doesn't already contain.
                        NavigationLink("Find people to follow") { SearchView() }
                            .buttonStyle(.bordered)
                    } else {
                        // Discover is a TAB, not a push. Pushing a second
                        // copy of it inside this stack would leave the
                        // viewer somewhere that looks like Discover but
                        // has a back button to a feed they were told was
                        // empty. QuickActionRouter is how the app already
                        // switches tabs programmatically (Home-screen
                        // quick actions use it), so reuse that rather
                        // than threading a new binding down here.
                        Button("Browse Discover") {
                            quickActionRouter.pendingDestination = .discover
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 60)
            }
        }
        .navigationTitle(mode.rawValue)
        .nyxScreen()
        .refreshable { await load() }
        .task { await load() }
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView()
            }
        }
    }

    private func load() async {
        let requestedMode = mode
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = requestedMode == .following
                ? try await GalleryAPIClient.shared.followingFeed()
                : try await GalleryAPIClient.shared.likedFeed()
            guard requestedMode == mode else { return }
            items = fetched
        } catch {
            guard requestedMode == mode else { return }
            errorMessage = error.localizedDescription
        }
    }
}
