import AVKit
import SwiftUI

/// Renders whatever `VideoPlayerController` is currently playing. The
/// controller (and its `AVPlayer`) is owned by the caller so the same
/// playback session can be shared across the inline and fullscreen
/// presentations of a video -- see `VideoPlayerController`.
struct AuthenticatedVideoPlayer: View {
    @ObservedObject var controller: VideoPlayerController

    var body: some View {
        Group {
            if let errorMessage = controller.errorMessage {
                // AVKit's own "can't play" glyph gives no indication of *why* —
                // surface the real AVPlayerItem error instead of leaving the
                // viewer to guess (network vs. auth vs. an unsupported codec
                // all look identical otherwise).
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                    Text("Couldn't play this video").font(.subheadline.weight(.semibold))
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button("Try Again") { controller.retry() }
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else if let player = controller.player {
                VideoPlayer(player: player)
                    .overlay(alignment: .topTrailing) { watermark }
                    .overlay(alignment: .topLeading) { resumeChip }
            } else {
                Color.black.overlay(ProgressView())
            }
        }
        .onAppear { controller.startIfNeeded() }
    }

    /// Auto-resuming silently is disorienting ("why did this start in the
    /// middle?") and a blocking "Resume?" prompt in front of the video is
    /// worse, so this resumes immediately and offers one tap to undo --
    /// the same bargain the web player's `.vp-resume-chip` strikes.
    /// Bottom-leading would collide with AVKit's transport controls, so
    /// it sits opposite the watermark.
    @ViewBuilder
    private var resumeChip: some View {
        if let resumedFrom = controller.resumedFrom {
            HStack(spacing: 8) {
                Text("Resumed from \(Self.timestamp(resumedFrom))")
                    .font(.caption2.weight(.semibold))
                Button {
                    controller.startOver()
                } label: {
                    Label("Start over", systemImage: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.35), in: Capsule())
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(12)
            .transition(.opacity)
            // Self-dismissing: it is an acknowledgement, not a control,
            // and leaving it parked over the video would be worse than
            // never showing it. Keyed on the value so a later resume
            // (a quality switch reattaching, say) restarts the timer
            // rather than inheriting the first one's remaining time.
            .task(id: resumedFrom) {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                controller.dismissResumeNotice()
            }
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Matches the web player's `.vp-watermark` (VideoPlayer.jsx): the same
    /// fixed brand mark regardless of the viewer's own accent-color
    /// customization, since this identifies the *site's* player, not the
    /// user's theme. Top-trailing, same as web -- AVKit's native transport
    /// controls sit bottom-center/tap-to-toggle, so this corner stays clear.
    private var watermark: some View {
        HStack(spacing: 6) {
            LinearGradient(
                colors: [Color(hex: "#37c9a7"), Color(hex: "#6ec7ff"), Color(hex: "#ffcf6a")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Nyxframe")
                .font(.caption2.weight(.bold))
        }
        .padding(.vertical, 5)
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .foregroundStyle(.white.opacity(0.82))
        .background(.black.opacity(0.5), in: Capsule())
        .padding(14)
        .allowsHitTesting(false)
    }
}
