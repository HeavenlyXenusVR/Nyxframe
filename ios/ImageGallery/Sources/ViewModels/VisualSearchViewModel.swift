import PhotosUI
import SwiftUI

/// Backs `VisualSearchView` -- mirrors web's `VisualSearchPage.jsx`. Two
/// independent entry points share this one view model: a fresh image pick
/// (`pickerItem`), or arriving with a seed post id (`seedMediaId`) from an
/// existing post's "Find visually similar" link, which reuses that post's
/// already-stored perceptual hash via `GET .../visual-similar` instead of
/// re-uploading/re-hashing the same bytes.
@MainActor
final class VisualSearchViewModel: ObservableObject {
    @Published var pickerItem: PhotosPickerItem?
    @Published var previewData: Data?
    @Published var items: [MediaItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasSearched = false

    let seedMediaId: Int?
    private let api = GalleryAPIClient.shared
    /// Mirrors the backend's own 15MB cap on `/api/search/visual`
    /// (`routes.lua`'s `M.visual_search`) -- this endpoint has its own,
    /// smaller limit than the general upload path's `ServerConfig`-backed
    /// one, since it's a search reference image, not a post being saved.
    private let maxSearchImageBytes = 15 * 1024 * 1024

    init(seedMediaId: Int? = nil) {
        self.seedMediaId = seedMediaId
    }

    func loadSeedIfNeeded() async {
        guard let seedMediaId, !hasSearched else { return }
        hasSearched = true
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await api.visuallySimilarMedia(mediaId: seedMediaId)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func handlePickerSelection() async {
        guard let pickerItem else { return }
        errorMessage = nil
        do {
            guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                errorMessage = "Could not read that image. Try picking it again."
                return
            }
            if data.count > maxSearchImageBytes {
                errorMessage = "Search image must be 15MB or smaller."
                return
            }
            previewData = data
            await search(data: data)
        } catch {
            errorMessage = "Could not read that image: \(error.localizedDescription)"
        }
    }

    func search(data: Data) async {
        isLoading = true
        errorMessage = nil
        hasSearched = true
        defer { isLoading = false }
        do {
            items = try await api.visualSearch(data: data, fileName: "search.jpg", mimeType: "image/jpeg")
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            items = []
        }
    }

    func reset() {
        previewData = nil
        items = []
        errorMessage = nil
        hasSearched = false
        pickerItem = nil
    }
}
