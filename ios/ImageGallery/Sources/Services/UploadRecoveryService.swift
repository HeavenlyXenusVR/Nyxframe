import Foundation

/// Resolves the server-side finish jobs `BackgroundUploadManager` hands off
/// to `PendingUploadJobStore` once a chunked upload's transfer finishes
/// (see that store's doc comment) -- this is the ONLY thing that ever polls
/// `uploadJobStatus`; `BackgroundUploadManager` itself never does, it just
/// records the job id and moves on. Checked from `RootView` at launch, on
/// every return to foreground, AND right after
/// `BackgroundUploadManager.shared.completionNotice` changes (a chunked
/// upload's transfer finishing is exactly the moment a fresh job appears
/// here worth checking promptly, rather than waiting for the next
/// unrelated foreground transition) -- mirrors web's `Shell.jsx` polling
/// the same job-status endpoint from its own persisted queue on an
/// interval. Cheap no-op when `PendingUploadJobStore` is empty, which is
/// true almost always.
@MainActor
final class UploadRecoveryService: ObservableObject {
    @Published var recoveredMessage: String?

    private let api = GalleryAPIClient.shared
    private var isChecking = false

    func checkPendingJobs() async {
        guard !isChecking else { return }
        let jobs = PendingUploadJobStore.all()
        guard !jobs.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        for job in jobs {
            do {
                let status = try await api.uploadJobStatus(jobId: job.jobId)
                switch status.status {
                case "done":
                    PendingUploadJobStore.remove(jobId: job.jobId)
                    recoveredMessage = "\"\(job.filename)\" finished uploading."
                case "error":
                    PendingUploadJobStore.remove(jobId: job.jobId)
                    recoveredMessage = "Upload of \"\(job.filename)\" failed: \(status.detail ?? "unknown error")"
                default:
                    // Still processing -- leave it for the next foreground
                    // check rather than looping here.
                    break
                }
            } catch {
                // Job lookup itself failed (expired past the 24h server-side
                // TTL, or a network blip) -- drop it rather than retrying
                // forever, same call web's Shell.jsx makes for the same
                // failure mode. The upload already ran (or is running)
                // server-side regardless of whether anyone's still watching
                // for the result; losing just the notice isn't losing the
                // upload.
                PendingUploadJobStore.remove(jobId: job.jobId)
            }
        }
    }
}
