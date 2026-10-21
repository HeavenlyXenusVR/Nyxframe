import Foundation

/// Owns "Download to device" for media detail -- the one action iOS never
/// had despite `MediaActionBar`'s Share tile existing for ages (Share just
/// hands the URL to the system sheet, which can save a photo but can't
/// reliably save a VIDEO anywhere a user can later find it without picking
/// "Save Video" from inside that sheet, and even then it lands in Photos,
/// not anywhere the gallery owns). This writes the finished file straight
/// into this app's own `Documents/` directory, which Files.app lists as a
/// "Nyxframe" folder under On My iPhone/iPad once `UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace` are set (see Info.plist) -- so
/// "download" produces a real, user-visible, app-named folder, not a save
/// into the shared Photos camera roll.
///
/// Structurally a smaller mirror of `BackgroundUploadManager`: same real
/// background `URLSession` (so locking the phone or switching apps mid-
/// download doesn't kill a multi-hundred-MB video transfer), same
/// one-JSON-file-per-download persisted state so a delegate callback
/// landing in a freshly relaunched process can still identify and finish
/// what it belongs to, same retry-with-backoff. Simpler than the upload
/// side in one respect: a download is always exactly one GET, no
/// init/chunk/finish phase machine needed.
final class BackgroundDownloadManager: NSObject, ObservableObject {
    static let shared = BackgroundDownloadManager()

    /// Live transfer progress (0...1) per download id, for a UI that's
    /// still on screen -- absent once a download finishes or fails.
    @Published private(set) var progress: [String: Double] = [:]
    /// Mirrors `BackgroundUploadManager.completionNotice` -- same toast
    /// mechanism, separate property since these are two independent
    /// singletons with no view-tree reference to each other.
    @Published var completionNotice: String?

    /// Set by `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// when `identifier` matches this manager's session.
    var backgroundCompletionHandler: (() -> Void)?

    static let sessionIdentifier = "com.imagegallery.ios.bg-download"
    private static let maxRetries = 3

    private var session: URLSession!
    private let fileManager = FileManager.default

    private override init() {
        super.init()
        try? fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // The user explicitly tapped Download -- move bytes now, not
        // whenever the system judges it an opportune low-power moment.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.shouldUseExtendedBackgroundIdleMode = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        reconcile()
    }

    // MARK: - Public API

    /// `suggestedFilename` should already carry the right extension (the
    /// call site knows whether this is the video's original container or
    /// an image) -- this manager doesn't try to infer one from the URL or
    /// response Content-Type, since a signed `?access=` URL's path is just
    /// `/api/media/<id>/download` with no extension in it at all.
    @discardableResult
    func enqueue(url: URL, suggestedFilename: String, mediaId: Int) -> String {
        let id = UUID().uuidString
        DispatchQueue.main.async { self.progress[id] = 0 }
        let download = ManagedDownload(
            id: id, mediaId: mediaId, remoteURL: url, suggestedFilename: suggestedFilename,
            enqueuedAt: Date()
        )
        saveState(download)
        startTask(for: download)
        return id
    }

    // MARK: - Persisted state

    private struct ManagedDownload: Codable {
        let id: String
        let mediaId: Int
        let remoteURL: URL
        let suggestedFilename: String
        var currentTaskIdentifier: Int?
        var retryCount: Int = 0
        let enqueuedAt: Date
    }

    private var stateDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingDownloads", isDirectory: true)
    }
    private func statePath(_ id: String) -> URL { stateDirectory.appendingPathComponent("\(id).json") }

    /// The actual destination -- this app's real `Documents/` directory,
    /// which is what `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace`
    /// expose to Files.app. Flat, not a subfolder: Files.app already shows
    /// this whole directory AS the app-named "Nyxframe" folder, so nesting
    /// another folder inside it would just read as "Nyxframe > Nyxframe".
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func loadState(_ id: String) -> ManagedDownload? {
        guard let data = try? Data(contentsOf: statePath(id)) else { return nil }
        return try? JSONDecoder().decode(ManagedDownload.self, from: data)
    }

    private func saveState(_ download: ManagedDownload) {
        guard let data = try? JSONEncoder().encode(download) else { return }
        try? data.write(to: statePath(download.id), options: .atomic)
    }

    private func allPersistedIds() -> [String] {
        (try? fileManager.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil))?
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
    }

    private func findDownload(forTask taskIdentifier: Int) -> ManagedDownload? {
        for id in allPersistedIds() {
            if let download = loadState(id), download.currentTaskIdentifier == taskIdentifier { return download }
        }
        return nil
    }

    private func cleanup(_ id: String) {
        try? fileManager.removeItem(at: statePath(id))
    }

    /// Picks a destination that doesn't clobber an existing file of the
    /// same name -- "video.mp4", "video (1).mp4", "video (2).mp4", ...
    /// matching the convention Finder/Files itself uses for a save
    /// conflict, so a second download of something already saved doesn't
    /// silently overwrite it.
    private func uniqueDestination(for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = documentsDirectory.appendingPathComponent(filename)
        var attempt = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)"
            candidate = documentsDirectory.appendingPathComponent(numbered)
            attempt += 1
        }
        return candidate
    }

    // MARK: - Reconciliation (app launch / long background stretch)

    private func reconcile() {
        let ids = allPersistedIds()
        guard !ids.isEmpty else { return }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let liveTaskIds = Set(tasks.map(\.taskIdentifier))
            for id in ids {
                guard let download = self.loadState(id) else { continue }
                // Matches BackgroundUploadManager's own 24h abandon window.
                if Date().timeIntervalSince(download.enqueuedAt) > 24 * 3600 {
                    self.cleanup(id)
                    continue
                }
                if let currentTaskId = download.currentTaskIdentifier, liveTaskIds.contains(currentTaskId) {
                    continue // Genuinely still in flight -- leave it alone.
                }
                DispatchQueue.main.async { self.progress[id] = 0 }
                self.startTask(for: download)
            }
        }
    }

    // MARK: - Transfer

    private func startTask(for download: ManagedDownload) {
        let task = session.downloadTask(with: download.remoteURL)
        var updated = download
        updated.currentTaskIdentifier = task.taskIdentifier
        saveState(updated)
        task.resume()
    }

    // MARK: - Completion handling

    private func finishSuccessfully(download: ManagedDownload, savedTo url: URL) {
        DispatchQueue.main.async { [weak self] in
            self?.progress[download.id] = nil
            self?.completionNotice = "Saved \"\(url.lastPathComponent)\" to the Nyxframe folder in Files."
        }
        cleanup(download.id)
    }

    private func markFailed(download: ManagedDownload, error: Error) {
        var download = download
        download.retryCount += 1
        if download.retryCount <= Self.maxRetries {
            saveState(download)
            let delaySeconds = Double(download.retryCount) * 2.0
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                self?.startTask(for: download)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.progress[download.id] = nil
            self?.completionNotice = "Download failed: \(error.localizedDescription)"
        }
        cleanup(download.id)
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let download = findDownload(forTask: downloadTask.taskIdentifier), totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let id = download.id
        DispatchQueue.main.async { [weak self] in self?.progress[id] = fraction }
    }

    /// Delivered on a background thread, and the temp file at `location` is
    /// deleted the instant this method returns -- it has to be moved
    /// synchronously, right here, not handed off to a `Task` first.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let download = findDownload(forTask: downloadTask.taskIdentifier) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            markFailed(download: download, error: GalleryAPIError.http(status: http.statusCode, message: "Server returned status \(http.statusCode)."))
            return
        }
        do {
            let filename = Self.filename(from: downloadTask.response) ?? download.suggestedFilename
            let destination = uniqueDestination(for: filename)
            try fileManager.moveItem(at: location, to: destination)
            finishSuccessfully(download: download, savedTo: destination)
        } catch {
            markFailed(download: download, error: error)
        }
    }

    /// `/api/media/{id}/download` (see `M.download_media` in `routes.lua`)
    /// always sets a real `Content-Disposition: attachment;
    /// filename="..."` with the post's actual original filename -- prefer
    /// that over the caller's guess, which is only a generic
    /// "nyxframe_<id>.<ext>" built without knowing the real one.
    private static func filename(from response: URLResponse?) -> String? {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
              let range = disposition.range(of: "filename=\"") else { return nil }
        let rest = disposition[range.upperBound...]
        guard let endQuote = rest.firstIndex(of: "\"") else { return nil }
        let name = String(rest[rest.startIndex..<endQuote])
        return name.isEmpty ? nil : name
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let download = findDownload(forTask: task.taskIdentifier) else { return }
        // A successful download's completion also fires this delegate
        // method with `error == nil` -- already handled (and the state
        // file already cleaned up) by `didFinishDownloadingTo` above, so
        // only a genuine transfer error reaches here.
        markFailed(download: download, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
