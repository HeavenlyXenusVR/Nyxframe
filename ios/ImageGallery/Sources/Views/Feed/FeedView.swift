import SwiftUI

/// Explore -- the app's front page.
///
/// Top to bottom: a header that knows what night it is (tonight's moon
/// phase and a greeting), one search capsule into the unified Search,
/// the Spotlight carousel of the week's trending posts, "Echoes" from
/// this day in past years, then the feed itself as a staggered grid
/// under a filter shelf that pins to the top while you scroll.
struct FeedView: View {
    @StateObject private var viewModel = FeedViewModel()
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var quickActionRouter: QuickActionRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingFilters = false
    /// Bumped by pull-to-refresh so the self-fetching rails reload too.
    @State private var railsReloadKey = 0

    private var settings: UserSettings? { session.currentUser?.userSettings }
    private var gridSpacing: CGFloat { min(Appearance.gridSpacing(settings?.columnGap), 16) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26, pinnedViews: [.sectionHeaders]) {
                header
                searchCapsule

                if !isFiltering {
                    SpotlightCarousel(reloadKey: railsReloadKey)
                    MemoriesRailView(reloadKey: railsReloadKey)
                }

                Section {
                    resultsSection
                } header: {
                    filterShelf
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .nyxScreen(stars: true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Frosts the status-bar strip so the feed doesn't scroll
            // under the clock unreadably (the nav bar is hidden here).
            Color.clear.frame(height: 0).background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showingFilters) {
            FeedFilterSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
        }
        .refreshable {
            railsReloadKey += 1
            await viewModel.loadInitial()
        }
        .task {
            if viewModel.items.isEmpty {
                // Only on the genuinely first load -- applying the saved
                // default_sort preference here (not in FeedViewModel's own
                // init, which runs before session.currentUser is
                // necessarily populated) instead of every time this view
                // reappears, so it never clobbers a sort the viewer already
                // picked for this session from the filter shelf.
                if let defaultSort = settings?.defaultSort, !defaultSort.isEmpty {
                    viewModel.sort = defaultSort
                }
                await viewModel.loadInitial()
            }
        }
    }

    private var isFiltering: Bool {
        !viewModel.query.isEmpty || viewModel.categoryId != nil || viewModel.subcategoryId != nil || viewModel.mediaKind != nil
    }

    // MARK: Header

    private var header: some View {
        let moon = MoonPhase.current()
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: moon.symbol)
                        .symbolRenderingMode(.hierarchical)
                    Text("\(moon.name) · \(Date().formatted(.dateTime.weekday(.wide)))".uppercased())
                        .tracking(1.2)
                }
                .font(Nyx.eyebrow)
                .foregroundStyle(Color.accentColor)
                .accessibilityElement(children: .combine)

                Text(greeting)
                    .font(Nyx.display(30))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Button {
                quickActionRouter.pendingDestination = .you
            } label: {
                AvatarView(
                    urlString: session.currentUser?.avatarUrl,
                    fallbackInitial: String((session.currentUser?.displayName?.nilIfEmpty ?? session.currentUser?.username ?? "?").prefix(1)),
                    shape: AvatarShape(settings?.profileAvatarShape),
                    size: 46
                )
                .overlay(
                    Circle().strokeBorder(
                        AngularGradient(colors: [Color.accentColor, .purple, Color.accentColor], center: .center),
                        lineWidth: 2
                    )
                    .padding(-4)
                )
            }
            .buttonStyle(NyxPressStyle())
            .accessibilityLabel("Your profile")
        }
        .padding(.horizontal, 20)
    }

    private var greeting: String {
        let name = session.currentUser?.displayName?.nilIfEmpty ?? session.currentUser?.username ?? "there"
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Morning, \(name)"
        case 12..<17: return "Afternoon, \(name)"
        case 17..<22: return "Evening, \(name)"
        default: return "Still up, \(name)?"
        }
    }

    // MARK: Search

    private var searchCapsule: some View {
        HStack(spacing: 10) {
            // One door into the unified Search (posts and people at once)
            // rather than a feed-only text field beside a separate people
            // search -- see SearchView's header comment for why that split
            // was removed. Feed-only keyword filtering still lives in the
            // filter sheet, which also saves it as an alert.
            NavigationLink {
                SearchView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Search posts, tags, people")
                        .foregroundStyle(Nyx.mist)
                    Spacer()
                }
                .font(.system(.subheadline, design: .rounded))
                .padding(.horizontal, 16)
                .frame(height: 50)
                .nyxGlass(radius: 25)
            }
            .buttonStyle(NyxPressStyle(scale: 0.98))

            Button {
                showingFilters = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 50, height: 50)
                    .nyxGlass(radius: 25)
                    .overlay(alignment: .topTrailing) {
                        if isFiltering {
                            Circle().fill(Color.accentColor).frame(width: 10, height: 10).offset(x: -6, y: 6)
                        }
                    }
            }
            .buttonStyle(NyxPressStyle())
            .accessibilityLabel("Filters")
        }
        .padding(.horizontal, 20)
    }

    // MARK: Filter shelf

    private static let sortOptions: [(value: String, label: String, icon: String)] = [
        ("new", "Newest", "sparkles"),
        ("popular", "Popular", "heart.fill"),
        ("views", "Most viewed", "eye.fill"),
        ("downloads", "Downloaded", "arrow.down.circle.fill"),
        ("old", "Oldest", "hourglass"),
    ]

    private var currentSort: (value: String, label: String, icon: String) {
        Self.sortOptions.first { $0.value == viewModel.sort } ?? Self.sortOptions[0]
    }

    private var filterShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { viewModel.sort },
                        set: { newValue in
                            guard newValue != viewModel.sort else { return }
                            viewModel.sort = newValue
                            Task { await viewModel.loadInitial() }
                        }
                    )) {
                        ForEach(Self.sortOptions, id: \.value) { option in
                            Label(option.label, systemImage: option.icon).tag(option.value)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: currentSort.icon).imageScale(.small)
                        Text(currentSort.label)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("Sort: \(currentSort.label)")

                Rectangle()
                    .fill(Nyx.hairline)
                    .frame(width: 1, height: 22)

                if !viewModel.query.isEmpty {
                    NyxChip(title: "“\(viewModel.query)”", systemImage: "xmark", isSelected: true) {
                        viewModel.query = ""
                        Task { await viewModel.loadInitial() }
                    }
                    .accessibilityLabel("Clear search \(viewModel.query)")
                }

                CategoryChipsRow(selectedCategoryId: $viewModel.categoryId) { categoryId in
                    viewModel.categoryId = categoryId
                    viewModel.subcategoryId = nil
                    Task { await viewModel.loadInitial() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Nyx.hairline).frame(height: 1)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            NyxSectionHeader(
                eyebrow: isFiltering ? "Filtered" : "The feed",
                title: isFiltering ? "Results" : "Fresh tonight"
            )
            .padding(.top, 12)

            if let errorMessage = viewModel.errorMessage {
                InlineErrorView(message: errorMessage) { await viewModel.loadInitial() }
            }

            if viewModel.isLoading && viewModel.items.isEmpty {
                SkeletonGridView(lanes: lanes)
            } else if viewModel.items.isEmpty {
                ContentUnavailableCompat(
                    title: "Nothing under these stars",
                    systemImage: "sparkle.magnifyingglass",
                    hint: isFiltering ? "Try another category, or clear the filters." : nil
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                MasonryGrid(
                    items: viewModel.items,
                    lanes: lanes,
                    spacing: gridSpacing,
                    aspectRatio: { GridRhythm.aspectRatio(for: $0, setting: settings?.cardAspectRatio) }
                ) { item in
                    NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                        MediaCard(item: item, aspectRatio: GridRhythm.aspectRatio(for: item, setting: settings?.cardAspectRatio))
                    }
                    .buttonStyle(NyxPressStyle(scale: 0.97))
                    .task {
                        await viewModel.loadMoreIfNeeded(currentItem: item)
                    }
                }
                .padding(.horizontal, 16)

                if viewModel.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
    }

    private var lanes: Int {
        GridRhythm.lanes(density: settings?.gridDensity, regularWidth: horizontalSizeClass == .regular)
    }
}
