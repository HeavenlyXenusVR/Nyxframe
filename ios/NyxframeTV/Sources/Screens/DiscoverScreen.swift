import SwiftUI

/// The home screen -- mirrors the web app's Discover page: greeting hero,
/// category and media-type filters, sort, an "On this day" shelf for
/// signed-in viewers, and the endlessly scrolling grid.
struct DiscoverScreen: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var feed = FeedViewModel()
    @State private var categories: [CategorySummary] = []
    @State private var memories: [MediaItem] = []
    @EnvironmentObject private var navigator: TVNavigator
    @State private var loadedOnce = false

    private static let sorts: [(String, String)] = [
        ("new", "Newest"), ("trending", "Trending"), ("popular", "Most liked"),
        ("views", "Most viewed"), ("downloads", "Most downloaded"), ("old", "Oldest"),
    ]
    private static let kinds: [(String?, String)] = [(nil, "All"), ("image", "Images"), ("video", "Videos")]
    /// The web app's 18+ filter ("18+ posts" in Discover's filter panel).
    private static let adultModes: [(String, String)] = [("show", "Show 18+"), ("hide", "Hide 18+"), ("only", "Only 18+")]
    /// Remembered on this TV, like the web app keeps it for the session.
    @AppStorage("nyxframe_tv_adult_filter") private var adultMode = "show"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                hero
                filters
                if !memories.isEmpty {
                    TVMediaShelf(title: "On this day", items: memories) { item, all in open(item, in: all) }
                }
                results
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvScreenBackground()
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            feed.adult = adultMode == "show" ? nil : adultMode
            if let sort = session.currentUser?.userSettings?.defaultSort, !sort.isEmpty { feed.sort = sort }
            Task { await loadLookups() }
            await feed.loadInitial()
        }
        .onChange(of: session.currentUser?.id) { _, _ in
            Task { await loadMemories() }
        }
    }

    // MARK: Sections

    private var hero: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Discover").font(.headline).foregroundStyle(TVTheme.accent)
                Text(greeting).font(.system(size: 64, weight: .heavy))
                TVNowPlayingBadge()
            }
            Spacer()
            HStack(spacing: 24) {
                NavigationLink(value: TVRoute.slideshow(items: feed.items.filter { !$0.isVideo && $0.locked != true })) {
                    Label("Slideshow", systemImage: "play.rectangle.on.rectangle")
                }
                .disabled(feed.items.allSatisfy { $0.isVideo || $0.locked == true })
                Button {
                    if let pick = feed.items.filter({ $0.locked != true }).randomElement() { open(pick, in: feed.items) }
                } label: {
                    Label("Surprise Me", systemImage: "sparkles")
                }
                .disabled(feed.items.isEmpty)
                Button {
                    Task { await feed.loadInitial() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .focusSection()
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    TVPill(title: "All categories", isSelected: feed.categoryId == nil) { setCategory(nil) }
                    ForEach(categories) { category in
                        TVPill(title: category.name, isSelected: feed.categoryId == category.id) { setCategory(category.id) }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            // Scrolls sideways instead of squeezing: media type, 18+ and
            // sort together are wider than the screen at TV text sizes.
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(Self.kinds, id: \.1) { kind in
                    TVPill(title: kind.1, isSelected: feed.mediaKind == kind.0) {
                        feed.mediaKind = kind.0
                        reload()
                    }
                }
                Divider().frame(height: 40).padding(.horizontal, 12)
                ForEach(Self.adultModes, id: \.0) { mode in
                    TVPill(title: mode.1, isSelected: adultMode == mode.0) {
                        adultMode = mode.0
                        feed.adult = mode.0 == "show" ? nil : mode.0
                        reload()
                    }
                }
                Divider().frame(height: 40).padding(.horizontal, 12)
                Menu {
                    ForEach(Self.sorts, id: \.0) { sort in
                        Button {
                            feed.sort = sort.0
                            reload()
                        } label: {
                            if feed.sort == sort.0 { Label(sort.1, systemImage: "checkmark") } else { Text(sort.1) }
                        }
                    }
                } label: {
                    Label("Sort: \(Self.sorts.first { $0.0 == feed.sort }?.1 ?? "Newest")", systemImage: "arrow.up.arrow.down")
                }
            }
            .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            if adultMode == "only", session.currentUser?.ageVerifiedAt == nil {
                Label(session.currentUser == nil
                      ? "18+ posts stay locked until you sign in with an age-verified account."
                      : "18+ posts stay locked until your age is verified on the Nyxframe website.",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var results: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(resultsHeading).font(.title3.bold())
            if feed.isLoading && feed.items.isEmpty {
                TVLoadingView(label: "Loading the gallery…")
            } else if let error = feed.errorMessage, feed.items.isEmpty {
                TVMessageView(systemImage: "wifi.exclamationmark", title: "Couldn't load posts", message: error) { reload() }
            } else if feed.items.isEmpty {
                TVMessageView(systemImage: "sparkles", title: "Nothing here yet", message: "Try another category or media type.")
            } else {
                TVMediaGrid(items: feed.items, onReachEnd: { item in
                    Task { await feed.loadMoreIfNeeded(currentItem: item) }
                }) { item, all in open(item, in: all) }
                if feed.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
            }
        }
    }

    // MARK: Helpers

    private var greeting: String {
        guard let user = session.currentUser else { return "Welcome to Nyxframe" }
        let name = user.displayName?.nilIfEmpty ?? user.username
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning, \(name)"
        case 12..<17: return "Good afternoon, \(name)"
        case 17..<22: return "Good evening, \(name)"
        default: return "Still up, \(name)?"
        }
    }

    private var resultsHeading: String {
        let base = Self.sorts.first { $0.0 == feed.sort }?.1 ?? "Newest"
        if let id = feed.categoryId, let name = categories.first(where: { $0.id == id })?.name {
            return "\(base) in \(name)"
        }
        return base == "Newest" ? "Latest uploads" : base
    }

    private func setCategory(_ id: Int?) {
        feed.categoryId = id
        feed.subcategoryId = nil
        reload()
    }

    private func reload() {
        Task { await feed.loadInitial() }
    }

    private func open(_ item: MediaItem, in list: [MediaItem]) {
        navigator.openMedia(item, in: list)
    }

    private func loadLookups() async {
        if let fetched = try? await GalleryAPIClient.shared.categories() { categories = fetched }
        await loadMemories()
    }

    private func loadMemories() async {
        guard session.currentUser != nil else { memories = []; return }
        memories = (try? await GalleryAPIClient.shared.memories()) ?? []
    }
}
