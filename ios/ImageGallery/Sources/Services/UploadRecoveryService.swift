import Foundation

/// Resolves upload finish jobs orphaned by the app being killed while
/// `GalleryAPIClient.uploadMediaChunked` was still waiting on one (see
/// `PendingUploadJobStore`'s doc comment). Checked from `RootView` at
/// launch and on every return to foreground -- mirrors web's `Shell.jsx`
/// polling the same job-status endpoint from its own persisted queue on an
/// interval; this app only needs to check on activity transitions since
/// the common case (app stays open) is already fully handled by
/// `uploadMediaChunked`'s own in-process polling and never reaches here.
/// Cheap no-op when `PendingUploadJobStore` is empty, which is true almost
/// always.
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
