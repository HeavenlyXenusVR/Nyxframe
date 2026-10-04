import SwiftUI

/// One place to find anything -- the iOS counterpart to the web app's
/// `/search` page and command palette.
///
/// Before this, searching was split the same way web's was: the Discover
/// feed had a text field that filtered only the feed, and a separate
/// "Find People" screen behind its own toolbar button searched only
/// users. Two entry points, neither of which could answer the other's
/// question, and no single answer to "where is that thing". This
/// replaces the people-only screen (the toolbar button now opens this)
/// and searches both at once.
///
/// Both kinds are queried for every term, not just the selected tab's,
/// so the tab labels can carry result counts -- someone searching a
/// person's name sees "People 3" without having to guess to look there.
struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case media
        case people

        var id: String { rawValue }
        var label: String { self == .media ? "Media" : "People" }
        var icon: String { self == .media ? "photo.on.rectangle" : "person.2" }
    }

    @State private var query = ""
    @State private var scope: Scope = .media
    @State private var media: [MediaItem] = []
    @State private var people: [GalleryUser] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Bumped on every keystroke so a slow in-flight response can tell it
    /// has been superseded -- without it, results from an earlier, shorter
    /// query can land after (and overwrite) the ones the viewer is
    /// actually waiting for.
    @State private var generation = 0


    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Picker("Results", selection: $scope) {
                        ForEach(Scope.allCases) { value in
                            Text("\(value.label) \(count(for: value))").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                switch scope {
                case .media: mediaResults
                case .people: peopleResults
                }
            }
            .padding(.vertical, 12)
        }
        .overlay { if isLoading && media.isEmpty && people.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "Posts, tags, or people")
        .navigationTitle("Search")
        .nyxScreen()
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { newValue in
            generation += 1
            let token = generation
            Task {
                // Debounce: .searchable fires per keystroke, and each pass
                // here is two network requests.
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard token == generation else { return }
                await run(newValue, token: token)
            }
        }
    }

    @ViewBuilder
    private var mediaResults: some View {
        if media.isEmpty {
            emptyState(
                title: query.isEmpty ? "Search the archive" : "No posts match “\(query)”",
                systemImage: "magnifyingglass"
            )
        } else {
            NyxMediaGrid(items: media)
        }
    }

    @ViewBuilder
    private var peopleResults: some View {
        if people.isEmpty {
            emptyState(
                title: query.isEmpty ? "Find people" : "No people match “\(query)”",
                systemImage: "person.slash"
            )
        } else {
            LazyVStack(spacing: 8) {
                ForEach(people) { user in
                    NavigationLink(destination: ProfileView(username: user.username)) {
                        HStack(spacing: 11) {
                            AvatarView(
                                urlString: user.avatarUrl,
                                fallbackInitial: String((user.displayName ?? user.username).prefix(1)),
                                size: 40
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName ?? user.username).font(.subheadline.weight(.semibold))
                                Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .softCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func emptyState(title: String, systemImage: String) -> some View {
        ContentUnavailableCompat(title: title, systemImage: systemImage)
            .padding(.top, 40)
    }

    private func count(for scope: Scope) -> Int {
        scope == .media ? media.count : people.count
    }

    private func run(_ text: String, token: Int) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            media = []
            people = []
            errorMessage = nil
            return
        }
        isLoading = true
        defer { if token == generation { isLoading = false } }
        // Concurrently, and tolerant of one side failing: a user-search
        // outage shouldn't blank the media results too.
        async let mediaTask = GalleryAPIClient.shared.listMedia(query: trimmed, limit: 40)
        async let peopleTask = GalleryAPIClient.shared.searchUsers(query: trimmed)
        let foundMedia = try? await mediaTask
        let foundPeople = try? await peopleTask
        guard token == generation else { return }
        media = foundMedia ?? []
        people = foundPeople ?? []
        errorMessage = (foundMedia == nil && foundPeople == nil) ? "Search failed. Check your connection and try again." : nil
    }
}
