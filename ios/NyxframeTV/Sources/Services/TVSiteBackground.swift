import Combine
import SwiftUI
import UIKit

/// The gallery's rotating site background, kept in sync with the website.
///
/// The backend picks one gallery image for everyone and rotates it every
/// few minutes (`GET /api/site/background`, `refresh_after_seconds` says
/// when the current pick expires). This mirrors App.jsx's
/// refreshSiteBackground: fetch, fully load the new image before showing
/// it, then crossfade from the old image over 5 seconds -- the same
/// duration and 50% strength as the web's `.app-shell::before/::after`.
/// The last background is remembered so a cold launch shows it
/// immediately instead of a blank backdrop.
@MainActor
final class TVSiteBackground: ObservableObject {
    static let shared = TVSiteBackground()

    struct Layer: Equatable {
        let id: Int
        let image: UIImage
        static func == (lhs: Layer, rhs: Layer) -> Bool { lhs.id == rhs.id }
    }

    /// Matches the web's `--site-background-strength` (dark theme).
    static let strength: Double = 0.5
    /// Matches the web's `transition: opacity 5000ms ease`.
    static let crossfadeSeconds: Double = 5

    @Published private(set) var current: Layer?

    private struct Response: Decodable {
        struct Background: Decodable { var id: Int; var url: String }
        var background: Background?
        var refreshAfterSeconds: Double?
    }

    private static let cacheKey = "nyxframe_tv_site_background"
    private var loop: Task<Void, Never>?

    private init() {}

    /// Idempotent. Starts the fetch/rotate loop.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.restoreCached()
            while !Task.isCancelled {
                let wait = await self?.refresh() ?? 60
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// Back in the foreground: re-sync right away rather than waiting out
    /// a sleep that may have spanned several rotations.
    func resync() {
        loop?.cancel()
        loop = nil
        start()
    }

    /// Returns how long to wait before the next check.
    private func refresh() async -> Double {
        do {
            let response: Response = try await GalleryAPIClient.shared.requestJSON("/api/site/background", requiresAuth: false)
            // +1s so the next request lands after the server has rotated.
            let next = max(30, (response.refreshAfterSeconds ?? 300) + 1)
            guard let background = response.background, let url = URL(string: background.url) else {
                // Backgrounds turned off site-wide: fade the current one out.
                if current != nil { withAnimation(.easeInOut(duration: Self.crossfadeSeconds)) { current = nil } }
                UserDefaults.standard.removeObject(forKey: Self.cacheKey)
                return next
            }
            guard background.id != current?.id else { return next }
            // Load completely before swapping, so the crossfade never fades
            // to an empty frame (the web preloads with `new Image()` too).
            let image = try await ImageCache.shared.loadImage(for: url)
            show(Layer(id: background.id, image: image))
            UserDefaults.standard.set(["id": background.id, "url": background.url], forKey: Self.cacheKey)
            return next
        } catch {
            // Decorative -- stay quiet, keep the current image, try again soon.
            return 60
        }
    }

    private func restoreCached() async {
        guard current == nil,
              let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey),
              let id = cached["id"] as? Int,
              let urlString = cached["url"] as? String,
              let url = URL(string: urlString) else { return }
        let image: UIImage?
        if let hit = await ImageCache.shared.image(for: url) {
            image = hit
        } else {
            image = try? await ImageCache.shared.loadImage(for: url)
        }
        guard let image, current == nil else { return }
        show(Layer(id: id, image: image))
    }

    private func show(_ layer: Layer) {
        withAnimation(.easeInOut(duration: Self.crossfadeSeconds)) {
            current = layer
        }
    }
}

/// Full-bleed backdrop: the night gradient the app always had, with the
/// synced site background crossfading on top of it.
struct TVSiteBackdrop: View {
    @ObservedObject private var background = TVSiteBackground.shared

    var body: some View {
        ZStack {
            TVTheme.background
            if let layer = background.current {
                // Cropped to the screen (the web's `background-size: cover`)
                // without letting the image's own size stretch the stack.
                Color.clear
                    .overlay {
                        Image(uiImage: layer.image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .opacity(TVSiteBackground.strength)
                    // Keyed by id, so a new pick is a new view: SwiftUI
                    // fades the old one out while the new one fades in.
                    .id(layer.id)
                    .transition(.opacity)
            }
            // Keeps text readable over bright images; strongest at the top
            // (headings) and bottom, like the web's panel glass does.
            LinearGradient(
                colors: [Color.black.opacity(0.45), Color.black.opacity(0.15), Color.black.opacity(0.45)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: TVSiteBackground.crossfadeSeconds), value: background.current)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
