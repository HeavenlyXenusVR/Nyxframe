import SwiftUI

/// Searches posts and people at once, using tvOS's native search keyboard
/// (which also accepts Siri dictation and the iPhone keyboard).
struct SearchScreen: View {
    @EnvironmentObject private var navigator: TVNavigator
    @State private var query = ""
    @State private var posts: [MediaItem] = []
    @State private var people: [GalleryUser] = []
    @State private var tags: [String] = []
    @State private var isSearching = false
    @State private var searchedFor = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestions
                } else if isSearching && posts.isEmpty && people.isEmpty {
                    TVLoadingView(label: "Searching…")
                } else if posts.isEmpty && people.isEmpty && searchedFor == query {
                    TVMessageView(systemImage: "magnifyingglass", title: "No results for “\(query)”", message: "Try a tag, a title, or a creator's name.")
                } else {
                    if !people.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("People").font(.title3.bold())
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 32) {
                                    ForEach(people) { user in
                                        Button {
                                            navigator.push(.user(user.username))
                                        } label: {
                                            VStack(spacing: 12) {
                                                TVAvatar(urlString: user.avatarUrl, name: user.displayName ?? user.username, size: 110)
                                                Text(user.displayName ?? user.username).font(.callout.bold()).lineLimit(1)
                                                Text("@\(user.username)").font(.caption2).foregroundStyle(.secondary)
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
                    if !posts.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Posts").font(.title3.bold())
                            TVMediaGrid(items: posts) { item, all in navigator.openMedia(item, in: all) }
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvScreenBackground()
        .searchable(text: $query, prompt: "Search wallpapers, memes, tags, people")
        .task(id: query) { await search() }
        .task { await loadTags() }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Popular tags").font(.title3.bold())
            if tags.isEmpty {
                Text("Start typing to search the whole gallery.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24)], alignment: .leading, spacing: 24) {
                    ForEach(tags, id: \.self) { tag in
                        Button("#\(tag)") { query = tag }
                    }
                }
                .focusSection()
            }
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            posts = []
            people = []
            return
        }
        // Debounce: the keyboard updates the query on every letter.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        async let postResults = GalleryAPIClient.shared.listMedia(query: term, sort: "popular", limit: 60)
        async let userResults = GalleryAPIClient.shared.searchUsers(query: term)
        let foundPosts = (try? await postResults) ?? []
        let foundPeople = (try? await userResults) ?? []
        guard !Task.isCancelled else { return }
        posts = foundPosts
        people = foundPeople
        searchedFor = query
    }

    private func loadTags() async {
        guard tags.isEmpty else { return }
        tags = (try? await GalleryAPIClient.shared.popularTags()) ?? []
    }
}
