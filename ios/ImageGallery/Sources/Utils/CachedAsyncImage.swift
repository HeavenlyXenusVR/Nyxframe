import CryptoKit
import SwiftUI

/// Shared decoded-image cache backing `CachedAsyncImage` below. Two tiers:
/// an in-memory `NSCache` (fast, but wiped on relaunch and evicted under
/// memory pressure) and a disk cache under Caches/ImageCache (survives a
/// cold relaunch -- previously every thumbnail the user had already seen
/// was re-downloaded from scratch on every app launch, since the cache was
/// memory-only). An `actor` (not a plain class) so the in-flight-request
/// map below is safe to touch from multiple concurrent `CachedAsyncImage`
/// loads without a manual lock.
actor ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let diskDirectory: URL

    /// Two views mounting the same brand-new URL at the same instant (e.g.
    /// a grid cell and its own live-preview eligibility check, or a fast
    /// re-render) used to each fire an independent network fetch -- this
    /// was a documented, deliberately-deferred gap. Coalesced here: the
    /// second caller awaits the first caller's in-flight `Task` instead of
    /// starting its own.
    private var inFlight: [URL: Task<UIImage, Error>] = [:]

    /// Oldest-first eviction once the disk cache holds more than this many
    /// files -- mirrors web's `pruneStoredCache` "drop the oldest third"
    /// approach (`frontend/src/api.js`) rather than tracking a byte budget
    /// precisely; thumbnails are small and roughly uniform in size, so a
    /// file-count cap is a good enough proxy for a size cap here.
    private static let maxDiskEntries = 1200
    private var storesSinceLastPrune = 0

    private init() {
        memory.countLimit = 300
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    private func diskPath(for url: URL) -> URL {
        // Swift's `String.hashValue` is randomized per-process (ASLR-seeded),
        // so it can't be used as a stable on-disk filename across launches --
        // a real content hash is needed for the cache to actually survive a
        // relaunch, which is the whole point of the disk tier.
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(hex)
    }

    func image(for url: URL) -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        guard let data = try? Data(contentsOf: diskPath(for: url)), let decoded = UIImage(data: data) else { return nil }
        memory.setObject(decoded, forKey: url as NSURL)
        return decoded
    }

    private func store(_ image: UIImage, data: Data, for url: URL) {
        memory.setObject(image, forKey: url as NSURL)
        try? data.write(to: diskPath(for: url), options: .atomic)
        storesSinceLastPrune += 1
        if storesSinceLastPrune >= 50 {
            storesSinceLastPrune = 0
            pruneDiskCacheIfNeeded()
        }
    }

    /// Fetches `url`, coalescing concurrent callers onto one network
    /// request and one decode. `Task.detached` deliberately does not
    /// inherit this actor's isolation, so every touch of `ImageCache.shared`
    /// inside it is an explicit, unambiguous cross-actor `await` -- easier
    /// to reason about correctly than relying on inherited-isolation rules
    /// with no compiler in this environment to check the result against.
    func loadImage(for url: URL) async throws -> UIImage {
        if let cached = image(for: url) { return cached }
        if let running = inFlight[url] {
            return try await running.value
        }
        let task = Task.detached(priority: .userInitiated) { () throws -> UIImage in
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let uiImage = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            await ImageCache.shared.store(uiImage, data: data, for: url)
            return uiImage
        }
        inFlight[url] = task
        do {
            let result = try await task.value
            inFlight[url] = nil
            return result
        } catch {
            inFlight[url] = nil
            throw error
        }
    }

    /// Warms the cache for thumbnails about to scroll into view -- mirrors
    /// web's idle-scheduled `preloadMediaAssets` (`utils/media.js`), called
    /// right after a page of feed/discover results lands so the next
    /// screenful is already cached (or in flight) by the time the user
    /// actually scrolls to it, instead of every card starting its fetch
    /// only once it's on screen. `nonisolated` and fire-and-forget (no
    /// `await` needed at the call site, callable straight from a
    /// `@MainActor` view model) since it only ever calls back into
    /// `loadImage`, which already does its own cache-check and
    /// in-flight-coalescing correctly -- there's nothing here that needs
    /// this actor's own isolation. Capped concurrency so background
    /// prefetching never meaningfully competes with an in-viewport load.
    nonisolated func preload(urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var iterator = urls.makeIterator()
                func launchNext() {
                    guard let url = iterator.next() else { return }
                    group.addTask { _ = try? await ImageCache.shared.loadImage(for: url) }
                }
                for _ in 0..<min(3, urls.count) { launchNext() }
                for await _ in group { launchNext() }
            }
        }
    }

    private func pruneDiskCacheIfNeeded() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard entries.count > Self.maxDiskEntries else { return }
        let withDates = entries.map { fileUrl -> (URL, Date) in
            let date = (try? fileUrl.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (fileUrl, date)
        }
        let sorted = withDates.sorted { $0.1 < $1.1 }
        let overflow = sorted.count - Self.maxDiskEntries
        let removeCount = overflow + sorted.count / 4
        for (fileUrl, _) in sorted.prefix(removeCount) {
            try? FileManager.default.removeItem(at: fileUrl)
        }
    }
}

/// Identifies the media a `CachedAsyncImage` is loading, purely for the
/// optional load-diagnostics beacon below -- mirrors the `diagnostics={{
/// mediaId, mediaKind, context }}` prop web's `ResilientImage` (ui.jsx)
/// takes at its highest-value call sites (feed cards, media detail,
/// profile avatar) rather than every single image in the app.
struct ImageLoadDiagnosticsContext {
    var mediaId: Int
    var mediaKind: String
    var context: String
}

/// De-dupes repeat diagnostic beacons for an image already reported this
/// session -- a SwiftUI re-render of the same successful/failed image
/// (scrolling a cell off/on screen, an unrelated state change) would
/// otherwise re-fire the beacon every time `.task(id:)` re-runs. Oldest-
/// eviction once the cap is hit, not a wholesale clear (that bug was found
/// and fixed on the web side's equivalent `reportedMediaDiagnostics` Set --
/// no reason to reintroduce it here).
@MainActor
private final class ReportedImageDiagnostics {
    static let shared = ReportedImageDiagnostics()
    private var order: [String] = []
    private var seen: Set<String> = []
    private let cap = 800

    func markIfNew(_ signature: String) -> Bool {
        guard !seen.contains(signature) else { return false }
        seen.insert(signature)
        order.append(signature)
        if order.count > cap {
            let oldest = order.removeFirst()
            seen.remove(oldest)
        }
        return true
    }
}

/// Drop-in `AsyncImage` replacement with a real cache -- same
/// `url:content:` phase-based signature, so every existing call site
/// (`AsyncImage(url:) { phase in ... }`) only needs the type name changed,
/// nothing else.
///
/// Plain `AsyncImage` has no cache of its own: every layer SwiftUI creates
/// (a feed cell scrolling back on screen, a view rebuilding from unrelated
/// state changes, revisiting the same avatar/thumbnail somewhere else in
/// the app) re-fetches AND re-decodes the same bytes from scratch. That
/// repeated decode work is the actual cause of "scrolling the feed/detail
/// view feels laggy" reported live 2026-08-31 -- not a video/GPU problem,
/// a missing-cache problem. `ImageCache` above keeps already-decoded
/// `UIImage`s keyed by URL (memory + disk), so a repeat appearance is a
/// cache hit instead of a network round trip + decode, including across a
/// cold app relaunch.
@MainActor
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content
    private let diagnostics: ImageLoadDiagnosticsContext?

    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, diagnostics: ImageLoadDiagnosticsContext? = nil, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.diagnostics = diagnostics
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        if let cached = await ImageCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }
        phase = .empty
        do {
            let uiImage = try await ImageCache.shared.loadImage(for: url)
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: uiImage))
            reportLoad(outcome: "success")
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
            reportLoad(outcome: "error")
        }
    }

    private func reportLoad(outcome: String) {
        guard let diagnostics, let url else { return }
        let signature = "\(diagnostics.mediaId)|\(diagnostics.context)|\(outcome)"
        guard ReportedImageDiagnostics.shared.markIfNew(signature) else { return }
        DiagnosticsReporter.reportMediaLoad(
            mediaId: diagnostics.mediaId, mediaKind: diagnostics.mediaKind,
            context: diagnostics.context, outcome: outcome, selectedSource: url.lastPathComponent
        )
    }
}
