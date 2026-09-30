import SwiftUI

/// Following feed, liked posts and collections -- the web app's
/// Following / Liked / Collections pages under one tab.
struct LibraryScreen: View {
    enum Section: String, CaseIterable, Identifiable {
        case following = "Following"
        case liked = "Liked"
        case collections = "Collections"
        var id: String { rawValue }
    }

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var navigator: TVNavigator
    @State private var section: Section = .following
    @State private var items: [MediaItem] = []
    @State private var myCollections: [CollectionSummary] = []
    @State private var publicCollections: [CollectionSummary] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var reachedEnd = false
    @State private var errorMessage: String?
    @State private var generation = 0

    private let pageSize = 48

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .bottom) {
                    Text("Library").font(.system(size: 64, weight: .heavy))
                    Spacer()
                    HStack(spacing: 16) {
                        ForEach(Section.allCases) { option in
                            TVPill(title: option.rawValue, isSelected: section == option) { section = option }
                        }
                    }
                }
                .focusSection()

                if session.currentUser == nil && section != .collections {
                    TVSignInPrompt(reason: section == .following
                                   ? "Follow creators to build a feed of their latest uploads."
                                   : "Everything you like while browsing collects here.")
                } else if section == .collections {
                    collectionsView
                } else {
                    feedView
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvScreenBackground()
        .task(id: "\(section.rawValue)|\(session.currentUser?.id ?? 0)") { await load() }
    }

    @ViewBuilder
    private var feedView: some View {
        if isLoading && items.isEmpty {
            TVLoadingView()
        } else if let errorMessage, items.isEmpty {
            TVMessageView(systemImage: "wifi.exclamationmark", title: "Couldn't load \(section.rawValue.lowercased())", message: errorMessage) {
                Task { await load() }
            }
        } else if items.isEmpty {
            TVMessageView(
                systemImage: section == .following ? "person.2" : "heart",
                title: section == .following ? "No posts from people you follow yet" : "You haven't liked anything yet",
                message: section == .following ? "Find creators in Search or Trending and follow them." : "Press Like on any post to save it here."
            )
        } else {
            TVMediaGrid(items: items, onReachEnd: { item in
                Task { await loadMore(after: item) }
            }) { item, all in navigator.openMedia(item, in: all) }
            if isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    @ViewBuilder
    private var collectionsView: some View {
        if isLoading && myCollections.isEmpty && publicCollections.isEmpty {
            TVLoadingView()
        } else if myCollections.isEmpty && publicCollections.isEmpty {
            TVMessageView(systemImage: "folder", title: "No collections yet", message: "Collections made on the website or iPhone app show up here.")
        } else {
            if !myCollections.isEmpty { collectionRow("Your collections", myCollections) }
            if !publicCollections.isEmpty { collectionRow("Community collections", publicCollections) }
        }
    }

    private func collectionRow(_ title: String, _ rows: [CollectionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 340), spacing: 48)], alignment: .leading, spacing: 48) {
                ForEach(rows) { collection in
                    TVCollectionCard(collection: collection) { navigator.push(.collection(collection.id)) }
                }
            }
        }
        .focusSection()
    }

    // MARK: Loading

    private func fetch(offset: Int) async throws -> [MediaItem] {
        switch section {
        case .following: return try await GalleryAPIClient.shared.followingFeed(limit: pageSize, offset: offset)
        case .liked: return try await GalleryAPIClient.shared.likedFeed(limit: pageSize, offset: offset)
        case .collections: return []
        }
    }

    private func load() async {
        generation += 1
        let requestGeneration = generation
        errorMessage = nil
        isLoading = true
        defer { if requestGeneration == generation { isLoading = false } }
        if section == .collections {
            let signedIn = session.currentUser != nil
            async let everyone = GalleryAPIClient.shared.collections(mine: false)
            let mineRows: [CollectionSummary] = signedIn ? ((try? await GalleryAPIClient.shared.collections(mine: true)) ?? []) : []
            let allRows: [CollectionSummary] = (try? await everyone) ?? []
            guard requestGeneration == generation else { return }
            myCollections = mineRows
            let mineIds = Set(mineRows.map(\.id))
            publicCollections = allRows.filter { !mineIds.contains($0.id) }
            return
        }
        guard session.currentUser != nil else { items = []; return }
        items = []
        reachedEnd = false
        do {
            let page = try await fetch(offset: 0)
            guard requestGeneration == generation else { return }
            items = page
            reachedEnd = page.count < pageSize
        } catch {
            guard requestGeneration == generation else { return }
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    private func loadMore(after item: MediaItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index >= items.count - 6,
              !reachedEnd, !isLoadingMore, !isLoading else { return }
        let requestGeneration = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await fetch(offset: items.count), requestGeneration == generation else { return }
        let known = Set(items.map(\.id))
        items.append(contentsOf: page.filter { !known.contains($0.id) })
        reachedEnd = page.count < pageSize
    }
}

/// Every post in one collection.
struct CollectionDetailScreen: View {
    let collectionId: Int
    @EnvironmentObject private var navigator: TVNavigator
    @State private var detail: CollectionDetailResponse?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let detail {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(detail.collection.name).font(.system(size: 56, weight: .heavy))
                            if let description = detail.collection.description?.nilIfEmpty {
                                Text(description).foregroundStyle(.secondary)
                            }
                            if let owner = detail.collection.displayName ?? detail.collection.username {
                                Text("By \(owner)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        let stills = (detail.media ?? []).filter { !$0.isVideo && $0.locked != true }
                        if !stills.isEmpty {
                            Button {
                                navigator.push(.slideshow(items: stills))
                            } label: {
                                Label("Slideshow", systemImage: "play.rectangle.on.rectangle")
                            }
                        }
                    }
                    .focusSection()
                    if let media = detail.media, !media.isEmpty {
                        TVMediaGrid(items: media) { item, all in navigator.openMedia(item, in: all) }
                    } else {
                        TVMessageView(systemImage: "folder", title: "This collection is empty")
                    }
                } else if let errorMessage {
                    TVMessageView(systemImage: "exclamationmark.triangle", title: "Couldn't open this collection", message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    TVLoadingView()
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvScreenBackground()
        .task { await load() }
    }

    private func load() async {
        errorMessage = nil
        do {
            detail = try await GalleryAPIClient.shared.collectionDetail(id: collectionId)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}
