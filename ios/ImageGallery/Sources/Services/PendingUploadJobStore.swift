import Foundation

/// Persists background-finish job pointers to `UserDefaults` -- mirrors
/// web's `frontend/src/uploadJobs.js` (localStorage under
/// `image_gallery_pending_upload_jobs`). `BackgroundUploadManager` calls
/// `add` the moment a chunked upload's `/api/media/upload/finish` transfer
/// succeeds and hands back a job id -- from that point, resolving it is
/// entirely `UploadRecoveryService`'s job, checked on every launch/
/// foreground transition (`ImageGalleryApp.swift`). A non-empty read here
/// just means "there's a server-side finish job whose outcome hasn't been
/// shown to the user yet" -- it says nothing about whether the underlying
/// upload itself is still in flight (that's `BackgroundUploadManager`'s own
/// state, tracked separately).
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
