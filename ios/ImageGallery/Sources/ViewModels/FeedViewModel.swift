import Combine
import Foundation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var mediaKind: String? // nil, "image", "video"
    @Published var sort = "new"
    @Published var categoryId: Int?
    @Published var subcategoryId: Int?

    private let api = GalleryAPIClient.shared
    private var offset = 0
    private let pageSize = 60
    private var reachedEnd = false
    // Bumped by every loadInitial() (a filter/search change) so a
    // loadMoreIfNeeded() request already in flight when that happens can
    // detect it's stale and discard its result instead of appending
    // old-filter items onto the just-reset list.
    private var generation = 0

    func loadInitial() async {
        generation += 1
        let requestGeneration = generation
        offset = 0
        reachedEnd = false
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await api.listMedia(mediaKind: mediaKind, categoryId: categoryId, subcategoryId: subcategoryId, query: query, sort: sort, limit: pageSize, offset: 0)
            guard requestGeneration == generation else { return }
            items = fetched
            offset = fetched.count
            reachedEnd = fetched.count < pageSize
            preloadThumbnails(for: fetched)
        } catch {
            guard requestGeneration == generation else { return }
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func loadMoreIfNeeded(currentItem item: MediaItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard index >= items.count - 6, !reachedEnd, !isLoadingMore else { return }
        let requestGeneration = generation
        let requestOffset = offset
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.listMedia(mediaKind: mediaKind, categoryId: categoryId, subcategoryId: subcategoryId, query: query, sort: sort, limit: pageSize, offset: requestOffset)
            guard requestGeneration == generation else { return }
            items.append(contentsOf: next)
            offset += next.count
            reachedEnd = next.count < pageSize
            preloadThumbnails(for: next)
        } catch {
            // Non-fatal — keep whatever's already loaded on screen.
        }
    }

    /// Warms `ImageCache` for the first few thumbnails of a just-fetched
    /// page -- mirrors web's `preloadMediaAssets({limit: 6})` call after
    /// every list response (`DiscoverPage.jsx`/`FeedPage.jsx`). Only
    /// meaningfully useful for a page appended via `loadMoreIfNeeded`
    /// (page 1's items are about to render immediately anyway), but called
    /// uniformly for both same as web does.
    private func preloadThumbnails(for page: [MediaItem]) {
        let urls = page.prefix(6).compactMap { $0.thumbUrl.flatMap(URL.init(string:)) }
        ImageCache.shared.preload(urls: urls)
    }
}
