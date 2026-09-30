import SwiftUI
import UIKit

/// Ambient mode: full-screen photos that cross-fade with a slow Ken Burns
/// drift, while the soundtrack keeps playing. Keeps the TV awake while
/// it's running. Remote: left/right skip, Play/Pause pauses the slideshow.
struct SlideshowScreen: View {
    let items: [MediaItem]

    @State private var index = 0
    @State private var paused = false
    @State private var zoomed = false
    @State private var showCaption = true

    private static let interval: UInt64 = 9_000_000_000

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            if let item = current {
                CachedAsyncImage(url: (item.url?.nilIfEmpty ?? item.previewUrl).flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .scaleEffect(zoomed ? 1.08 : 1.0)
                            .animation(.linear(duration: 9), value: zoomed)
                    case .failure:
                        Image(systemName: "photo").font(.system(size: 80)).foregroundStyle(.secondary)
                    default:
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .id(item.id)
                .transition(.opacity.animation(.easeInOut(duration: 1.4)))

                if showCaption {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title?.nilIfEmpty ?? "Untitled").font(.title2.bold())
                        HStack(spacing: 16) {
                            Text(item.displayName ?? item.username ?? "Nyxframe")
                            Text("\(index + 1) of \(items.count)")
                            if paused { Label("Paused", systemImage: "pause.fill") }
                            TVNowPlayingBadge()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    .padding(60)
                    .transition(.opacity)
                }
            } else {
                TVMessageView(systemImage: "photo.on.rectangle", title: "No photos to show")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            default: withAnimation { showCaption.toggle() }
            }
        }
        .onPlayPauseCommand { paused.toggle() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            zoomed = true
            preloadNext()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: "\(index)|\(paused)") {
            guard !paused, items.count > 1 else { return }
            try? await Task.sleep(nanoseconds: Self.interval)
            guard !Task.isCancelled else { return }
            step(1)
        }
    }

    private var current: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 1.4)) {
            index = (index + delta + items.count) % items.count
        }
        zoomed = false
        DispatchQueue.main.async { zoomed = true }
        preloadNext()
    }

    private func preloadNext() {
        guard !items.isEmpty else { return }
        let next = items[(index + 1) % items.count]
        if let url = (next.url?.nilIfEmpty ?? next.previewUrl).flatMap(URL.init(string:)) {
            ImageCache.shared.preload(urls: [url])
        }
    }
}
