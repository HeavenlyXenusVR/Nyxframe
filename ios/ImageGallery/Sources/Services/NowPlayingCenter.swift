import Foundation
import MediaPlayer
import UIKit

/// Publishes whatever video is currently playing to the system: the lock
/// screen, Control Center, CarPlay, a headset's transport buttons and the
/// hardware play/pause key on a keyboard or AirPods. This is the iOS
/// counterpart to the Media Session integration in `VideoPlayer.jsx`.
///
/// Why it matters more here than on web: the app already declares the
/// `audio` background mode and configures an `AVAudioSession` with the
/// `.playback` category (see `AppDelegate`/Info.plist) so Picture in
/// Picture keeps playing when backgrounded. Without any Now Playing info
/// registered, that backgrounded video is audio the system can name no
/// source for and offers no controls over -- the lock screen either sits
/// empty or, worse, still shows whatever played before it.
///
/// Single owner at a time, enforced by `ObjectIdentifier`: only the
/// controller that currently holds the session may update or clear it.
/// Without that, a controller being deallocated *after* the next one has
/// already taken over (ordinary when pushing from one video to another,
/// since deinit isn't ordered against the new view's setup) would wipe
/// the newer video's metadata and leave the lock screen blank.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    /// What the owning controller wants to happen for each transport
    /// control. Supplied as closures rather than having this type hold an
    /// `AVPlayer`, so the owner keeps sole responsibility for its player's
    /// lifetime and for telemetry/resume bookkeeping around a seek.
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var seek: (Double) -> Void
        var skip: (Double) -> Void
    }

    private var owner: ObjectIdentifier?
    private var handlers: Handlers?
    private var info: [String: Any] = [:]
    private var artworkTask: Task<Void, Never>?

    private init() {}

    func begin(owner newOwner: AnyObject, title: String, artist: String?, artworkURL: URL?, handlers: Handlers) {
        owner = ObjectIdentifier(newOwner)
        self.handlers = handlers
        info = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist ?? "Nyxframe",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        registerCommands()
        loadArtwork(from: artworkURL, for: ObjectIdentifier(newOwner))
    }

    /// Called from the owner's periodic time observer. The system
    /// extrapolates the scrubber from `elapsed` + `rate`, so this only has
    /// to be accurate, not frequent.
    func update(owner candidate: AnyObject, elapsed: Double, duration: Double, rate: Float) {
        guard owner == ObjectIdentifier(candidate) else { return }
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func end(owner candidate: AnyObject) {
        end(ownerId: ObjectIdentifier(candidate))
    }

    /// Identity-only variant, for a `deinit` that cannot hand its own
    /// `self` to a `@MainActor` hop.
    func end(ownerId candidate: ObjectIdentifier) {
        guard owner == candidate else { return }
        artworkTask?.cancel()
        artworkTask = nil
        owner = nil
        handlers = nil
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        // removeTarget(nil) first: these are process-wide singletons, and
        // adding a second target without dropping the previous one leaves
        // a deallocated controller's closure wired to the lock screen.
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            guard let handlers = self?.handlers else { return .noActionableNowPlayingItem }
            handlers.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let handlers = self?.handlers else { return .noActionableNowPlayingItem }
            handlers.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let handlers = self?.handlers else { return .noActionableNowPlayingItem }
            let rate = (self?.info[MPNowPlayingInfoPropertyPlaybackRate] as? Float) ?? 0
            if rate > 0 { handlers.pause() } else { handlers.play() }
            return .success
        }
        // Ten seconds to match the web player's own ±10s controls and the
        // double-tap gesture, so the two clients skip by the same amount.
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let handlers = self?.handlers else { return .noActionableNowPlayingItem }
            handlers.skip((event as? MPSkipIntervalCommandEvent)?.interval ?? 10)
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let handlers = self?.handlers else { return .noActionableNowPlayingItem }
            handlers.skip(-((event as? MPSkipIntervalCommandEvent)?.interval ?? 10))
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let handlers = self?.handlers,
                  let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            else { return .commandFailed }
            handlers.seek(position)
            return .success
        }
    }

    /// Artwork is fetched off the main actor and applied only if this
    /// owner still holds the session -- a slow thumbnail must never delay
    /// the metadata that's already available, nor land on top of a newer
    /// video's.
    private func loadArtwork(from url: URL?, for expectedOwner: ObjectIdentifier) {
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  !Task.isCancelled
            else { return }
            await MainActor.run {
                guard let self, self.owner == expectedOwner else { return }
                self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
            }
        }
    }
}
