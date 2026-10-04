import SwiftUI

/// The week's trending posts as a paged, full-bleed carousel at the top
/// of Explore -- the "tonight's sky" moment of the app, replacing the old
/// row of small trending thumbnails. Self-contained (own fetch + state)
/// so it doesn't entangle `FeedViewModel`'s pagination with a second,
/// differently-sorted request.
///
/// Advances on its own every few seconds unless Reduce Motion is on
/// (system or account setting), and stops while its tab is in the
/// background.
struct SpotlightCarousel: View {
    var reloadKey: Int = 0

    @State private var items: [MediaItem] = []
    @State private var isLoading = true
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.nyxReduceMotion) private var accountReduceMotion
    @Environment(\.nyxTabIsActive) private var tabIsActive

    private let height: CGFloat = 340

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                RoundedRectangle(cornerRadius: Nyx.Radius.hero, style: .continuous)
                    .fill(Nyx.glow.opacity(0.3))
                    .frame(height: height)
                    .padding(.horizontal, 20)
            } else if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    NyxSectionHeader(eyebrow: "Spotlight", title: "Trending this week") {
                        NavigationLink("See all", destination: TrendingView())
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                    }

                    TabView(selection: $page) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                                SpotlightSlide(item: item, rank: index + 1)
                            }
                            .buttonStyle(NyxPressStyle(scale: 0.98))
                            .padding(.horizontal, 20)
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: height)

                    pageDots
                }
            }
        }
        .task(id: reloadKey) {
            if let fetched = try? await GalleryAPIClient.shared.trendingMedia(days: 7, limit: 8) {
                items = fetched
                page = min(page, max(0, fetched.count - 1))
            }
            isLoading = false
        }
        .task(id: autoAdvanceKey) {
            guard autoAdvances else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled, items.count > 1 else { continue }
                withAnimation(.easeInOut(duration: 0.6)) {
                    page = (page + 1) % items.count
                }
            }
        }
    }

    private var autoAdvances: Bool {
        !systemReduceMotion && !accountReduceMotion && tabIsActive && items.count > 1
    }

    /// Restarts the advance loop (and its 6s countdown) whenever any input
    /// to it changes, including the viewer swiping to a page themselves.
    private var autoAdvanceKey: String {
        "\(autoAdvances)-\(page)-\(items.count)"
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<items.count, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Color.accentColor : Nyx.mist.opacity(0.35))
                    .frame(width: index == page ? 18 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of \(items.count)")
    }
}

private struct SpotlightSlide: View {
    let item: MediaItem
    let rank: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay(NyxThumbnail(item: item, context: "spotlight"))
                .clipped()

            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.25), .clear],
                startPoint: .bottom,
                endPoint: .center
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Nº \(rank)")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.accentColor, in: Capsule())
                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.caption2.bold())
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }

                Text(item.title?.nilIfEmpty ?? "Untitled")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .lineLimit(2)

                HStack(spacing: 12) {
                    if let name = item.displayName?.nilIfEmpty ?? item.username {
                        Label(name, systemImage: "person.crop.circle")
                            .lineLimit(1)
                    }
                    if let likes = item.likeCount, likes > 0 {
                        Label("\(likes)", systemImage: "heart.fill")
                    }
                    if let views = item.views, views > 0 {
                        Label("\(views)", systemImage: "eye.fill")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: Nyx.Radius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Nyx.Radius.hero, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 10)
        .accessibilityElement(children: .combine)
    }
}
