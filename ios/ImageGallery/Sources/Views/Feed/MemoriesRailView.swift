import SwiftUI

/// "Echoes" -- posts from this day in past years. Mirrors DiscoverMemories
/// on the web (frontend/src/components/discover.jsx). Same self-contained
/// fetch shape as SpotlightCarousel; renders nothing when there's nothing
/// from today in a past year.
///
/// Cards are tilted polaroids with the year stamped on them, to read as
/// keepsakes rather than another feed row.
struct MemoriesRailView: View {
    var reloadKey: Int = 0

    @EnvironmentObject private var session: SessionStore
    @State private var items: [MediaItem] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    NyxSectionHeader(eyebrow: "Echoes", title: "On this day")

                    ScrollView(.horizontal, showsIndicators: false) {
                        // LazyHStack -- see SimilarMediaRail's identical fix/comment.
                        LazyHStack(spacing: 18) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                                    EchoCard(item: item)
                                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -2.5 : 2))
                                }
                                .buttonStyle(NyxPressStyle())
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
        .task(id: reloadKey) {
            guard session.currentUser != nil else { return }
            if let fetched = try? await GalleryAPIClient.shared.memories() {
                items = fetched
            }
        }
    }
}

private struct EchoCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(width: 128, height: 140)
                .overlay(NyxThumbnail(item: item, context: "memories"))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack(alignment: .firstTextBaseline) {
                Text(item.title?.nilIfEmpty ?? "Untitled")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let yearsAgo = item.yearsAgo {
                    Text(yearsAgo == 1 ? "1 yr" : "\(yearsAgo) yrs")
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 128)
        }
        .padding(8)
        .padding(.bottom, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Nyx.surface)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Nyx.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
        .accessibilityElement(children: .combine)
    }
}
