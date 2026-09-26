import Foundation

/// Device-local playback preferences and resume positions -- the iOS half
/// of web's `frontend/src/utils/playerPrefs.js`, deliberately kept to the
/// same thresholds and the same "never syncs to the server" rule so the
/// two clients behave alike without either becoming the other's source of
/// truth. These are device-shaped settings: the quality a phone on
/// cellular wants isn't the one a desktop wants, and where *this* device
/// got to in a video isn't something another device should inherit.
///
/// Everything here is best-effort. A `UserDefaults` miss, a decode failure
/// on data written by an older build, a wiped container -- all of them
/// have to come back as "no preference" rather than as an error, because
/// nothing about playback may depend on this succeeding.
enum PlaybackPreferences {
    private static let qualityKey = "playback_quality"
    private static let resumeKey = "playback_resume_positions"

    /// Bounded so a heavy browsing session can't grow this entry without
    /// limit; trimmed oldest-first by last save.
    private static let maxResumeEntries = 240
    /// Below this, "resuming" is indistinguishable from starting over.
    private static let minResumeSeconds: Double = 15
    /// Past this fraction the viewer has effectively finished the video.
    private static let maxResumeFraction: Double = 0.95
    /// A short clip has no "pick up where I left off" problem worth solving.
    private static let minResumableDuration: Double = 90

    // MARK: Quality

    /// Only ever written from an explicit pick in the quality menu -- never
    /// from a fallback the player chose for itself -- for the same reason
    /// web's MediaDetailPage gates this behind `userInitiated`.
    static var quality: String {
        get { UserDefaults.standard.string(forKey: qualityKey) ?? "original" }
        set { UserDefaults.standard.set(newValue, forKey: qualityKey) }
    }

    // MARK: Resume positions

    private struct ResumeEntry: Codable {
        var t: Double
        var d: Double
        var at: Double
    }

    private static func readAll() -> [String: ResumeEntry] {
        guard let data = UserDefaults.standard.data(forKey: resumeKey),
              let decoded = try? JSONDecoder().decode([String: ResumeEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func writeAll(_ entries: [String: ResumeEntry]) {
        var trimmed = entries
        if trimmed.count > maxResumeEntries {
            let doomed = trimmed
                .sorted { $0.value.at < $1.value.at }
                .prefix(trimmed.count - maxResumeEntries)
            for entry in doomed { trimmed.removeValue(forKey: entry.key) }
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: resumeKey)
    }

    /// Seconds to resume at, or nil when there's nothing worth resuming.
    static func resumePosition(mediaId: Int) -> Double? {
        guard mediaId > 0, let entry = readAll()[String(mediaId)] else { return nil }
        return entry.t >= minResumeSeconds ? entry.t : nil
    }

    /// Records progress, or removes the entry once the position stops
    /// being worth resuming from (too near the start, too near the end,
    /// clip too short) -- so watching something out cleans up after
    /// itself instead of leaving a stale near-the-end resume behind.
    static func saveResumePosition(mediaId: Int, time: Double, duration: Double) {
        guard mediaId > 0, time.isFinite, duration.isFinite, duration > 0 else { return }
        var entries = readAll()
        let key = String(mediaId)
        let worthKeeping = duration >= minResumableDuration
            && time >= minResumeSeconds
            && time <= duration * maxResumeFraction
        if worthKeeping {
            entries[key] = ResumeEntry(t: time.rounded(.down), d: duration.rounded(.down), at: Date().timeIntervalSince1970)
        } else {
            guard entries.removeValue(forKey: key) != nil else { return }
        }
        writeAll(entries)
    }

    static func clearResumePosition(mediaId: Int) {
        guard mediaId > 0 else { return }
        var entries = readAll()
        guard entries.removeValue(forKey: String(mediaId)) != nil else { return }
        writeAll(entries)
    }
}
