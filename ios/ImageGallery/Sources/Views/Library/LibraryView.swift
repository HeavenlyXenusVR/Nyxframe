import SwiftUI

/// Library -- everything you've kept, and the ways back into the archive
/// that aren't the main feed. A bento of doors (collections, likes,
/// follows, trending, categories) above two live shelves: what you liked
/// most recently, and your own collections.
struct LibraryView: View {
    @State private var recentLikes: [MediaItem] = []
    @State private var myCollections: [CollectionSummary] = []
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                bento
                recentLikesShelf
                collectionsShelf
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .nyxScreen(stars: true)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")
            }
        }
        .refreshable { await load() }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
    }

    private func load() async {
        async let likes = GalleryAPIClient.shared.likedFeed(limit: 12)
        async let collections = GalleryAPIClient.shared.collections(mine: true)
        recentLikes = (try? await likes) ?? recentLikes
        myCollections = (try? await collections) ?? myCollections
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOUR VAULT")
                .font(Nyx.eyebrow)
                .tracking(1.4)
                .foregroundStyle(Color.accentColor)
            Text("Library")
                .font(Nyx.display(34))
        }
        .padding(.horizontal, 20)
    }

    // MARK: Bento

    private var bento: some View {
        VStack(spacing: 12) {
            NavigationLink {
                CollectionsListView()
            } label: {
                BentoTile(
                    title: "Collections",
                    subtitle: myCollections.isEmpty ? "Curate your own constellations" : "\(myCollections.count) of yours",
                    systemImage: "square.stack.3d.up.fill",
                    colors: [Color.accentColor, .indigo],
                    height: 150,
                    covers: myCollections.compactMap { $0.coverUrl }.prefix(3).map { $0 }
                )
            }
            .buttonStyle(NyxPressStyle(scale: 0.98))

            HStack(spacing: 12) {
                NavigationLink {
                    FollowingLikedView(mode: .liked)
                } label: {
                    BentoTile(title: "Liked", subtitle: "Hearts you've left", systemImage: "heart.fill", colors: [.pink, .purple])
                }
                .buttonStyle(NyxPressStyle())

                NavigationLink {
                    FollowingLikedView(mode: .following)
                } label: {
                    BentoTile(title: "Following", subtitle: "New from your people", systemImage: "person.2.fill", colors: [.blue, .indigo])
                }
                .buttonStyle(NyxPressStyle())
            }

            HStack(spacing: 12) {
                NavigationLink {
                    TrendingView()
                } label: {
                    BentoTile(title: "Trending", subtitle: "Rising tonight", systemImage: "flame.fill", colors: [.orange, .pink])
                }
                .buttonStyle(NyxPressStyle())

                NavigationLink {
                    CategoryBrowserView()
                } label: {
                    BentoTile(title: "Categories", subtitle: "Browse by kind", systemImage: "square.grid.3x3.fill", colors: [.teal, .blue])
                }
                .buttonStyle(NyxPressStyle())
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Shelves

    @ViewBuilder
    private var recentLikesShelf: some View {
        if !recentLikes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                NyxSectionHeader(eyebrow: "Recently", title: "Liked by you") {
                    NavigationLink("See all") { FollowingLikedView(mode: .liked) }
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                }
                SimilarMediaRail(items: recentLikes)
            }
        }
    }

    @ViewBuilder
    private var collectionsShelf: some View {
        if !myCollections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                NyxSectionHeader(eyebrow: "Curated", title: "Your collections")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(myCollections) { collection in
                            NavigationLink {
                                CollectionDetailView(collectionId: collection.id)
                            } label: {
                                CollectionCover(collection: collection)
                            }
                            .buttonStyle(NyxPressStyle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

/// One door in the Library bento: a gradient glyph, a title and a line of
/// context, optionally fanned with up to three cover images.
private struct BentoTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let colors: [Color]
    var height: CGFloat = 128
    var covers: [String] = []

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Nyx.Radius.card, style: .continuous)
                .fill(LinearGradient(colors: colors.map { $0.opacity(0.22) }, startPoint: .topLeading, endPoint: .bottomTrailing))

            if !covers.isEmpty {
                HStack(spacing: -26) {
                    ForEach(Array(covers.enumerated()), id: \.offset) { index, cover in
                        CachedAsyncImage(url: URL(string: cover)) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Color.white.opacity(0.1)
                            }
                        }
                        .frame(width: 64, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                        .rotationEffect(.degrees(Double(index - 1) * 8))
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 28)
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: (colors.first ?? .clear).opacity(0.5), radius: 8, x: 0, y: 4)
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Nyx.mist)
                    .lineLimit(1)
            }
            .padding(16)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .nyxGlass(radius: Nyx.Radius.card)
        .accessibilityElement(children: .combine)
    }
}

/// A collection on the Library shelf: its cover (or a gradient when it has
/// none) with the name over a scrim.
private struct CollectionCover: View {
    let collection: CollectionSummary

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let cover = collection.coverUrl, let url = URL(string: cover) {
                    CachedAsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            fallback
                        }
                    }
                } else {
                    fallback
                }
            }
            .frame(width: 160, height: 120)
            .clipped()

            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .center)

            VStack(alignment: .leading, spacing: 2) {
                if collection.isSmart == true {
                    Label("Smart", systemImage: "wand.and.stars")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(collection.name)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(12)
        }
        .frame(width: 160, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 5)
    }

    private var fallback: some View {
        LinearGradient(colors: [Nyx.glow, Nyx.glowAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(.white.opacity(0.7)))
    }
}
