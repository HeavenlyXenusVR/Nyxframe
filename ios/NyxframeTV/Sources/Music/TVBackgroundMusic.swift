import AVFoundation
import Combine
import Foundation

/// The Apple TV's always-on soundtrack.
///
/// Plays the admin-managed background-music tracks (`/api/background-music`,
/// public -- no sign-in needed) in a shuffled loop from the moment the app
/// launches, with no interaction required, and keeps it going indefinitely:
///
/// * Every track played once per shuffle; the list is reshuffled (never
///   repeating the track that just ended first) and refreshed from the
///   server periodically so admin changes show up without a relaunch.
/// * Self-healing: a track that fails to load is skipped, a stream that
///   stalls is restarted by a watchdog, audio-session interruptions resume
///   on their own, and a server that's unreachable is retried with backoff
///   until music comes back.
/// * Video: the music fades out completely when a video starts playing and
///   fades back in when that video reaches its end mark. Pausing a video
///   keeps the music silent (the viewer is still watching); leaving the
///   video without finishing it also brings the music back, so it can never
///   get stuck silent.
///
/// The only thing that stops it is the viewer turning it off in Settings
/// (or with the remote's play/pause button while browsing).
@MainActor
final class TVBackgroundMusic: ObservableObject {
    static let shared = TVBackgroundMusic()

    enum State: Equatable {
        case idle
        case loading
        case playing
        case silencedForVideo
        case off
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTitle: String?
    @Published private(set) var trackCount = 0
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(!isEnabled, forKey: Self.disabledKey)
            isEnabled ? resumeAfterUserToggle() : stopForUserToggle()
        }
    }
    /// 0...1, persisted. Applied as the "full" level every fade targets.
    @Published var volume: Double {
        didSet {
            // Assigning inside didSet doesn't re-trigger it.
            let clamped = min(1, max(0, volume))
            if clamped != volume { volume = clamped }
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
            if !videoActive, fadeTask == nil { player.volume = Float(volume) }
        }
    }

    private static let disabledKey = "nyxframe_tv_music_disabled"
    private static let volumeKey = "nyxframe_tv_music_volume"
    private static let defaultVolume = 0.45
    private static let fadeOutSeconds = 1.2
    private static let fadeInSeconds = 2.5
    private static let catalogRefreshInterval: TimeInterval = 30 * 60
    private static let watchdogInterval: TimeInterval = 5
    private static let stallLimit: TimeInterval = 20

    private let player = AVPlayer()
    private var tracks: [BackgroundMusicTrack] = []
    private var queue: [BackgroundMusicTrack] = []
    private var lastPlayedId: Int?
    private var consecutiveFailures = 0
    private var videoActive = false
    private var started = false

    private var fadeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// True while a backoff retry is scheduled; the watchdog stands down
    /// so it can't bypass the backoff by restarting playback itself.
    private var retryPending = false
    private var watchdog: Timer?
    private var catalogRefreshedAt: Date = .distantPast
    private var notStartedSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var itemStatusObservation: NSKeyValueObservation?

    private init() {
        isEnabled = !UserDefaults.standard.bool(forKey: Self.disabledKey)
        let stored = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        volume = stored ?? Self.defaultVolume
        // Never let AVPlayer pause the soundtrack on its own to "save" a
        // network stall -- the watchdog decides what to do instead.
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        installObservers()
    }

    // MARK: Lifecycle

    /// Called once at launch. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        configureAudioSession()
        startWatchdog()
        guard isEnabled else { state = .off; return }
        Task { await loadCatalogAndPlay() }
    }

    /// App returned to the foreground -- make sure music is actually going.
    func ensurePlaying() {
        guard started, isEnabled, !videoActive else { return }
        configureAudioSession()
        if player.currentItem == nil || player.timeControlStatus == .paused {
            if tracks.isEmpty { Task { await loadCatalogAndPlay() } } else { playNext() }
        }
    }

    func toggle() { isEnabled.toggle() }

    func skip() {
        guard isEnabled, !tracks.isEmpty else { return }
        playNext()
    }

    // MARK: Catalog

    private func loadCatalogAndPlay() async {
        retryPending = false
        state = .loading
        await LiveConfigService.shared.refresh()
        do {
            let fetched = try await GalleryAPIClient.shared.backgroundMusicTracks()
            catalogRefreshedAt = Date()
            tracks = fetched
            trackCount = fetched.count
            guard !fetched.isEmpty else {
                state = .unavailable("No background music has been uploaded yet.")
                scheduleRetry(after: 5 * 60)
                return
            }
            queue.removeAll { track in !fetched.contains { $0.id == track.id } }
            guard isEnabled else { state = .off; return }
            if videoActive { state = .silencedForVideo; return }
            if player.currentItem == nil || player.timeControlStatus != .playing { playNext() }
        } catch {
            consecutiveFailures += 1
            state = .unavailable("Couldn't reach the music server. Retrying…")
            scheduleRetry(after: backoffDelay())
        }
    }

    /// Picks up tracks the admin added or removed, between songs.
    private func refreshCatalogIfStale() {
        guard Date().timeIntervalSince(catalogRefreshedAt) > Self.catalogRefreshInterval else { return }
        catalogRefreshedAt = Date()
        Task {
            guard let fetched = try? await GalleryAPIClient.shared.backgroundMusicTracks(), !fetched.isEmpty else { return }
            tracks = fetched
            trackCount = fetched.count
            queue.removeAll { track in !fetched.contains { $0.id == track.id } }
        }
    }

    private func backoffDelay() -> TimeInterval {
        min(120, 3 * pow(2, Double(max(0, consecutiveFailures - 1))))
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryPending = true
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            await self.loadCatalogAndPlay()
        }
    }

    // MARK: Playback

    private func playNext() {
        guard !tracks.isEmpty else { return }
        refreshCatalogIfStale()
        if queue.isEmpty {
            var shuffled = tracks.shuffled()
            // Don't start a new round with the song that just finished.
            if shuffled.count > 1, shuffled.last?.id == lastPlayedId {
                shuffled.swapAt(shuffled.count - 1, 0)
            }
            queue = shuffled
        }
        guard let next = queue.popLast() else { return }
        guard let url = URL(string: next.url) else {
            handleTrackFailure()
            return
        }
        lastPlayedId = next.id
        currentTitle = next.title
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            Task { @MainActor in
                guard let self, failed, self.player.currentItem === observed else { return }
                self.handleTrackFailure()
            }
        }
        player.replaceCurrentItem(with: item)
        notStartedSince = Date()
        guard isEnabled, !videoActive else {
            player.pause()
            return
        }
        player.volume = 0
        player.play()
        state = .playing
        fade(to: volume, over: Self.fadeInSeconds, thenPause: false)
    }

    private func handleTrackFailure() {
        consecutiveFailures += 1
        // Several tracks in a row failing means the server (not one file)
        // is the problem -- back off and reload the catalog instead of
        // spinning through the whole queue.
        if consecutiveFailures >= min(3, max(1, tracks.count)) {
            player.replaceCurrentItem(with: nil)
            state = .unavailable("Music stream interrupted. Reconnecting…")
            scheduleRetry(after: backoffDelay())
        } else {
            playNext()
        }
    }

    // MARK: Video interplay

    private func videoStarted() {
        videoActive = true
        guard isEnabled else { return }
        state = .silencedForVideo
        fade(to: 0, over: Self.fadeOutSeconds, thenPause: true)
    }

    private func videoFinished() {
        guard videoActive else { return }
        videoActive = false
        guard isEnabled else { return }
        if player.currentItem == nil {
            playNext()
            return
        }
        player.volume = 0
        player.play()
        state = .playing
        notStartedSince = Date()
        fade(to: volume, over: Self.fadeInSeconds, thenPause: false)
    }

    // MARK: User toggle

    private func stopForUserToggle() {
        retryTask?.cancel()
        retryPending = false
        state = .off
        fade(to: 0, over: Self.fadeOutSeconds, thenPause: true)
    }

    private func resumeAfterUserToggle() {
        guard started else { return }
        if tracks.isEmpty {
            Task { await loadCatalogAndPlay() }
            return
        }
        if videoActive { state = .silencedForVideo; return }
        if player.currentItem == nil { playNext(); return }
        player.volume = 0
        player.play()
        state = .playing
        fade(to: volume, over: Self.fadeInSeconds, thenPause: false)
    }

    // MARK: Fading

    private func fade(to target: Double, over seconds: Double, thenPause: Bool) {
        fadeTask?.cancel()
        let start = Double(player.volume)
        let steps = max(1, Int(seconds * 30))
        fadeTask = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                // Ease in-out, so the fade doesn't start or land abruptly.
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                self.player.volume = Float(start + (target - start) * eased)
            }
            guard !Task.isCancelled, let self else { return }
            if thenPause { self.player.pause() }
            self.fadeTask = nil
        }
    }

    // MARK: Observers

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let item, item === self.player.currentItem else { return }
                self.playNext()
            }
        })
        observers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let item, item === self.player.currentItem else { return }
                self.handleTrackFailure()
            }
        })
        observers.append(center.addObserver(forName: .nyxframeVideoPlaybackChanged, object: nil, queue: .main) { [weak self] note in
            let playing = (note.userInfo?["playing"] as? Bool) ?? false
            let closed = (note.userInfo?["closed"] as? Bool) ?? false
            Task { @MainActor in
                guard let self else { return }
                if playing { self.videoStarted() } else if closed { self.videoFinished() }
            }
        })
        observers.append(center.addObserver(forName: .nyxframeVideoReachedEnd, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.videoFinished() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                // Resume regardless of the "should resume" hint: this app's
                // whole point is music that never stays off by accident.
                self.configureAudioSession()
                self.ensurePlaying()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.configureAudioSession()
                self.player.replaceCurrentItem(with: nil)
                self.ensurePlaying()
            }
        })
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    /// Catches the failure modes no notification reports: a stream that
    /// buffers forever, or a player left paused by something outside this
    /// class while it should be playing.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
    }

    private func checkHealth() {
        guard isEnabled, !videoActive, !tracks.isEmpty, !retryPending else { return }
        if player.timeControlStatus == .playing {
            // Only audible music proves the stream works -- this is what
            // resets the backoff, not merely reaching the catalog.
            consecutiveFailures = 0
            notStartedSince = nil
            if state != .playing { state = .playing }
            return
        }
        // Paused while it should be audible (and not mid fade-out).
        if player.timeControlStatus == .paused, fadeTask == nil {
            if player.currentItem == nil { playNext() } else { player.play() }
            return
        }
        let since = notStartedSince ?? Date()
        notStartedSince = since
        if Date().timeIntervalSince(since) > Self.stallLimit {
            notStartedSince = Date()
            playNext()
        }
    }
}
