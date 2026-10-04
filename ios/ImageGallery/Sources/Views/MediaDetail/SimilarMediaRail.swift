import SwiftUI

struct SimilarMediaRail: View {
    let items: [MediaItem]

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                // LazyHStack, not HStack: each MediaCard runs its own
                // on-screen check (via onAppear/onDisappear) to decide
                // whether to autoplay a video preview -- a plain HStack
                // renders every card immediately regardless of
                // horizontal scroll position, so onAppear fired for
                // cards still off to the right too, autoplaying videos
                // nobody could even see yet. Same root cause as
                // CommentsSection's identical fix: eager rendering of
                // an unbounded/scrollable list, reported live
                // 2026-08-31 as feed/detail scrolling lag.
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                            MediaCard(item: item, aspectRatio: 4.0 / 5.0)
                                .frame(width: 140)
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
