import Foundation

/// Persists background-finish job pointers to `UserDefaults` -- mirrors
/// web's `frontend/src/uploadJobs.js` (localStorage under
/// `image_gallery_pending_upload_jobs`). Exists so an app killed while
/// `GalleryAPIClient.uploadMediaChunked`'s `pollUploadJob` loop is still
/// waiting on a large upload's background finish job doesn't lose track of
/// it -- `UploadRecoveryService` checks this on next launch/foreground and
/// resolves whatever's left behind. Entries are written right before
/// polling starts and removed as soon as polling resolves in the normal
/// (app-stays-open) case, so under normal operation this stays empty; a
/// non-empty read here specifically means "the app didn't get to see how
/// an upload turned out."
enum PendingUploadJobStore {
    private static let defaultsKey = "pending_upload_jobs"

    struct Job: Codable {
        var jobId: String
        var filename: String
        var queuedAt: Date
    }

    static func all() -> [Job] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Job].self, from: data)) ?? []
    }

    static func add(jobId: String, filename: String) {
        var jobs = all().filter { $0.jobId != jobId }
        jobs.append(Job(jobId: jobId, filename: filename, queuedAt: Date()))
        save(jobs)
    }

    static func remove(jobId: String) {
        save(all().filter { $0.jobId != jobId })
    }

    private static func save(_ jobs: [Job]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
