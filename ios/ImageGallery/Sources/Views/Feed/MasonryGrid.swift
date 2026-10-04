import SwiftUI

/// A staggered, Pinterest-style grid: items flow into whichever lane is
/// currently shortest, so tiles of different heights pack without the
/// ragged gaps a `LazyVGrid` row leaves. Each lane is its own
/// `LazyVStack`, so off-screen tiles are still never built -- which
/// matters here because `MediaCard` starts a live video preview when it
/// appears.
///
/// Lane assignment only depends on the items before it, so appending a
/// page never reshuffles tiles the viewer has already scrolled past.
struct MasonryGrid<Cell: View>: View {
    let items: [MediaItem]
    let lanes: Int
    let spacing: CGFloat
    /// Width / height for a tile.
    let aspectRatio: (MediaItem) -> CGFloat
    @ViewBuilder let cell: (MediaItem) -> Cell

    var body: some View {
        let distributed = distribute()
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<distributed.count, id: \.self) { lane in
                LazyVStack(spacing: spacing) {
                    ForEach(distributed[lane]) { item in
                        cell(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func distribute() -> [[MediaItem]] {
        let count = max(1, lanes)
        var result = Array(repeating: [MediaItem](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        for item in items {
            var shortest = 0
            for lane in 1..<count where heights[lane] < heights[shortest] {
                shortest = lane
            }
            result[shortest].append(item)
            heights[shortest] += 1 / max(aspectRatio(item), 0.1) + 0.08
        }
        return result
    }
}

/// How tiles are shaped in the Nocturne grids.
///
/// When the viewer picked an explicit `card_aspect_ratio` on web or in
/// Settings, every tile uses it, same as before. Otherwise ("free", the
/// default) tiles follow a fixed rhythm keyed off the post id -- a stand-
/// in for the source image's real aspect ratio, which the list endpoints
/// don't return. Keying off the id (not the position) keeps a tile the
/// same shape wherever it appears.
enum GridRhythm {
    private static let rhythm: [CGFloat] = [4.0 / 5.0, 1, 3.0 / 4.0, 2.0 / 3.0, 1, 5.0 / 4.0, 3.0 / 4.0]

    static func aspectRatio(for item: MediaItem, setting: String?) -> CGFloat {
        switch setting {
        case "1:1", "16:9", "4:3", "3:4":
            return Appearance.cardAspectRatio(setting)
        default:
            return rhythm[abs(item.id) % rhythm.count]
        }
    }

    /// Lanes for `grid_density`: compact packs three, wide gives each post
    /// the full width, comfortable (the default) is two. Regular-width
    /// layouts (iPad) get two more.
    static func lanes(density: String?, regularWidth: Bool) -> Int {
        let base: Int
        switch density {
        case "compact": base = 3
        case "wide": base = 1
        default: base = 2
        }
        return base + (regularWidth ? 2 : 0)
    }
}

/// The standard Nocturne post grid: a `MasonryGrid` of `MediaCard`s that
/// each open `MediaDetailView`, shaped by the viewer's grid settings.
/// Screens that list posts use this rather than assembling the grid
/// themselves, so every grid in the app shares one look.
struct NyxMediaGrid: View {
    let items: [MediaItem]
    var horizontalPadding: CGFloat = 16
    var onItemAppear: ((MediaItem) async -> Void)? = nil

    @EnvironmentObject private var session: SessionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var settings: UserSettings? { session.currentUser?.userSettings }

    var body: some View {
        MasonryGrid(
            items: items,
            lanes: GridRhythm.lanes(density: settings?.gridDensity, regularWidth: horizontalSizeClass == .regular),
            spacing: min(Appearance.gridSpacing(settings?.columnGap), 16),
            aspectRatio: { GridRhythm.aspectRatio(for: $0, setting: settings?.cardAspectRatio) }
        ) { item in
            NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                MediaCard(item: item, aspectRatio: GridRhythm.aspectRatio(for: item, setting: settings?.cardAspectRatio))
            }
            .buttonStyle(NyxPressStyle(scale: 0.97))
            .task {
                await onItemAppear?(item)
            }
        }
        .padding(.horizontal, horizontalPadding)
    }
}
