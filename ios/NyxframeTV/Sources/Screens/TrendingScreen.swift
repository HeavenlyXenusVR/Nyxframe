import SwiftUI

/// Trending posts over a chosen window, plus the creator leaderboard --
/// the web app's Trending page.
struct TrendingScreen: View {
    @EnvironmentObject private var navigator: TVNavigator
    @State private var days = 7
    @State private var items: [MediaItem] = []
    @State private var leaders: [LeaderboardEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private static let windows: [(Int, String)] = [(1, "Today"), (7, "This week"), (30, "This month"), (365, "This year")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trending").font(.system(size: 64, weight: .heavy))
                        TVNowPlayingBadge()
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        ForEach(Self.windows, id: \.0) { window in
                            TVPill(title: window.1, isSelected: days == window.0) {
                                days = window.0
                                Task { await load() }
                            }
                        }
                    }
                }
                .focusSection()

                if !leaders.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Top creators").font(.title3.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 32) {
                                ForEach(Array(leaders.prefix(12).enumerated()), id: \.element.id) { index, entry in
                                    Button {
                                        navigator.push(.user(entry.username))
                                    } label: {
                                        VStack(spacing: 12) {
                                            ZStack(alignment: .topLeading) {
                                                TVAvatar(urlString: entry.userAvatarUrl, name: entry.displayName ?? entry.username, size: 120)
                                                Text("#\(index + 1)")
                                                    .font(.caption.bold())
                                                    .padding(8)
                                                    .background(TVTheme.accent, in: Capsule())
                                            }
                                            Text(entry.displayName ?? entry.username).font(.callout.bold()).lineLimit(1)
                                            Text("\(entry.totalViews.compactString) views · \(entry.totalLikes.compactString) likes")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        .frame(width: 220)
                                        .padding(.vertical, 16)
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                            .padding(.vertical, 24)
                        }
                        .scrollClipDisabled()
                    }
                    .focusSection()
                }

                if isLoading && items.isEmpty {
                    TVLoadingView()
                } else if let errorMessage, items.isEmpty {
                    TVMessageView(systemImage: "wifi.exclamationmark", title: "Couldn't load trending posts", message: errorMessage) {
                        Task { await load() }
                    }
                } else if items.isEmpty {
                    TVMessageView(systemImage: "chart.line.uptrend.xyaxis", title: "Nothing trending yet", message: "Try a longer time window.")
                } else {
                    TVMediaGrid(items: items) { item, all in navigator.openMedia(item, in: all) }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvScreenBackground()
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        async let trending = GalleryAPIClient.shared.trendingMedia(days: days, limit: 60)
        async let board = GalleryAPIClient.shared.leaderboard(window: days <= 7 ? "7d" : days <= 30 ? "30d" : "all")
        do {
            items = try await trending
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
        leaders = (try? await board) ?? leaders
    }
}
