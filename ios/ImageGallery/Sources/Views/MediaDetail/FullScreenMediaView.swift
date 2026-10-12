import SwiftUI

/// Edge-to-edge presentation of a single media item's image/video, reached
/// via the expand button on `MediaDetailView` — the inline viewer there is
/// capped to a modest height so the rest of the page stays reachable, which
/// left no way to see a photo/video at full quality/size.
///
/// Also hosts "Play all" -- web's Lightbox auto-advance with play/pause and
/// speed control, scoped to images: `slideshowItems` (when it has more than
/// one entry) drives a swipeable, auto-advancing sequence instead of the
/// single static `media`. Video stays on the original single-item path
/// below unconditionally -- `MediaDetailView` never builds a multi-item
/// list for a video post (see its call site's comment), since swiping
/// across several videos would need a fresh `VideoPlayerController` (HLS
/// quality ladder, lock-screen Now Playing, etc.) per item, and that's a
/// lot of machinery for a feature real slideshow tools don't apply to
/// video either.
struct FullScreenMediaView: View {
    let media: MediaItem
    var slideshowItems: [MediaItem] = []
    /// Passed in from `MediaDetailView` so opening fullscreen doesn't spin up
    /// a second, disconnected `AVPlayer` -- both presentations play through
    /// this one controller.
    var videoController: VideoPlayerController?
    /// Previously missing entirely -- this view had no quality picker at
    /// all, so the expand button silently traded away the ability to
    /// change quality the moment you actually wanted the bigger view.
    /// Passed through from MediaDetailView rather than owned here, since
    /// both presentations share the one videoController and need to stay
    /// in sync about which rendition is playing.
    var qualityOptions: [(String, String)] = []
    var videoQuality: String = "original"
    var onQualityChange: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex = 0
    @State private var isPlaying = false
    @State private var slideSeconds: Double = 5

    private static let speeds: [Double] = [3, 5, 10, 15]

    private var isSlideshow: Bool { !media.isVideo && slideshowItems.count > 1 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Group {
                if isSlideshow {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(slideshowItems.enumerated()), id: \.offset) { index, item in
                            slide(item).tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                } else if media.isVideo, let videoController {
                    AuthenticatedVideoPlayer(controller: videoController)
                } else if let urlString = media.url, let url = URL(string: urlString) {
                    ZoomableAsyncImage(url: url, diagnostics: ImageLoadDiagnosticsContext(mediaId: media.id, mediaKind: media.mediaKind ?? "", context: "fullscreen"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 4) {
                if media.isVideo, !qualityOptions.isEmpty, let onQualityChange {
                    VideoQualityMenu(options: qualityOptions, current: videoQuality, onSelect: onQualityChange)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding()
                .accessibilityLabel("Close fullscreen")
            }

            if isSlideshow {
                VStack {
                    Spacer()
                    slideshowBar
                }
            }
        }
        .statusBarHidden()
        // Re-arms on every index/speed/play change so each slide gets its
        // own full interval -- same shape as web's Lightbox effect and
        // tvOS's SlideshowScreen. Stops (doesn't loop) at the last item.
        .task(id: "\(currentIndex)|\(isPlaying)|\(slideSeconds)") {
            guard isSlideshow, isPlaying else { return }
            try? await Task.sleep(nanoseconds: UInt64(slideSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if currentIndex >= slideshowItems.count - 1 {
                isPlaying = false
                return
            }
            withAnimation { currentIndex += 1 }
        }
    }

    private func slide(_ item: MediaItem) -> some View {
        Group {
            if let urlString = item.url, let url = URL(string: urlString) {
                ZoomableAsyncImage(url: url, diagnostics: ImageLoadDiagnosticsContext(mediaId: item.id, mediaKind: item.mediaKind ?? "", context: "fullscreen-slideshow"))
            } else {
                Color.clear
            }
        }
    }

    private var slideshowBar: some View {
        HStack(spacing: 14) {
            Text("\(currentIndex + 1) / \(slideshowItems.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            Button {
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play all", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityLabel(isPlaying ? "Pause slideshow" : "Play all")

            Menu {
                ForEach(Self.speeds, id: \.self) { seconds in
                    Button {
                        slideSeconds = seconds
                    } label: {
                        if slideSeconds == seconds {
                            Label("\(Int(seconds))s", systemImage: "checkmark")
                        } else {
                            Text("\(Int(seconds))s")
                        }
                    }
                }
            } label: {
                Label("\(Int(slideSeconds))s", systemImage: "speedometer")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityLabel("Slideshow speed")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 28)
    }
}
