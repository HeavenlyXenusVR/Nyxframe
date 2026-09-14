import Foundation

/// Owns the actual byte transfer for every upload, on a real background
/// `URLSession` -- the same mechanism Photos/Files uploads use -- instead of
/// the ordinary foreground session `GalleryAPIClient` uses for everything
/// else. Before this, `UploadViewModel.submit()` awaited
/// `GalleryAPIClient.uploadMedia`/`uploadMediaChunked` directly: locking the
/// phone or switching apps mid-transfer killed the upload outright, since a
/// plain foreground `URLSessionConfiguration.default` task doesn't survive
/// the app being suspended. This manager exists so that no longer happens --
/// once `enqueue` is called, the transfer keeps running independent of
/// whether the app stays open, exactly like web's upload flow doesn't
/// require the browser tab to stay focused for the bytes to keep moving.
///
/// **Everything here is designed to survive the app process being killed
/// outright**, not just backgrounded -- a background `URLSessionTask`'s
/// delegate callbacks can fire in a *freshly relaunched* process with zero
/// in-memory state, so nothing here relies on captured closures or awaited
/// continuations to learn how an upload turned out. All state lives in one
/// JSON file per upload under `Application Support/PendingUploads/<id>/`
/// (not `/tmp` -- that can be purged under disk pressure, which this state
/// must survive), and every delegate callback re-reads that file, acts, and
/// re-writes it -- a reducer, not a linear function. `reconcile()` (called
/// from `init`) re-issues fresh transfer tasks for anything the OS lost
/// track of across a very long background stretch or a plain cold launch.
///
/// Deliberately NOT `@MainActor`: `URLSessionTaskDelegate`/
/// `URLSessionDataDelegate` are plain synchronous protocols delivered on
/// the session's own serial delegate queue (guaranteed serial -- passing
/// `delegateQueue: nil` at construction makes `URLSession` create one), so
/// every callback below already runs one-at-a-time with no need for actor
/// isolation; `@Published` properties are always mutated via an explicit
/// `DispatchQueue.main.async` hop, the same pattern `VideoPlayerController`
/// already uses for its own KVO callbacks.
///
/// Only ONE upload is ever actually in flight at a time by design (matches
/// `UploadView`, which only ever has one file picked) -- the persisted
/// state is still keyed by id/directory rather than a single flat file
/// purely so a second upload started before the first fully drains (e.g.
/// right after backgrounding) can't corrupt the first's state.
final class BackgroundUploadManager: NSObject, ObservableObject {
    static let shared = BackgroundUploadManager()

    /// Live transfer progress (0...1) per upload id, for a UI that's still
    /// on screen -- `nil`/absent once an upload finishes or fails.
    @Published private(set) var progress: [String: Double] = [:]
    /// A finished/failed upload's outcome, surfaced the same way
    /// `UploadRecoveryService.recoveredMessage` already is (see
    /// `ImageGalleryApp.swift`'s matching alert) -- a second, sibling
    /// notice property rather than reaching into that other object, since
    /// this manager is a plain singleton with no view-tree reference to it.
    @Published var completionNotice: String?

    /// Set by `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// -- calling this tells iOS this process is done reacting to queued
    /// background-session events and can be suspended again.
    var backgroundCompletionHandler: (() -> Void)?

    /// Above this, an upload goes through the chunked init/chunk/finish
    /// flow instead of one direct multipart POST.
    ///
    /// BUGFIX 2026-09-14: was 60MB (this deployment's Cloudflare tunnel
    /// hard-413s any single request body over ~100MB regardless of the
    /// server's own configured limit, so 60MB was sized only against
    /// THAT). Confirmed live alongside the chunk-size fix
    /// (`lua/src/routes.lua`'s `M.upload_chunk_init`, 20MB -> 4MB): the
    /// direct path sends the whole file as ONE request with no chunking at
    /// all, so it's exposed to the exact same failure mode -- Cloudflare's
    /// edge gives up on a request after ~120s regardless of body size, and
    /// a backgrounded transfer (iOS deliberately throttles background
    /// network priority) can take far longer than that to move even a
    /// "small" 60MB file. Dropped to 10MB, comfortably below what a
    /// throttled background connection can be expected to move within
    /// 120s -- everything above this now gets the chunked path's per-chunk
    /// resilience (retry a failed 4MB piece, not the whole file) instead.
    static let chunkedThresholdBytes = 10 * 1024 * 1024
    private static let maxRetries = 3

    private var session: URLSession!
    private let fileManager = FileManager.default
    /// Accumulates each task's response body across possibly-many
    /// `didReceive` calls -- safe as a plain dictionary (no lock) because
    /// the session's serial delegate queue guarantees these callbacks,
    /// same as every other delegate method here, never run concurrently
    /// with each other.
    private var responseBuffers: [Int: Data] = [:]

    private override init() {
        super.init()
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        excludeRootDirectoryFromBackup()
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.imagegallery.ios.bg-upload")
        // The user explicitly tapped Publish -- this should start moving
        // bytes right away, not whenever the system decides it's an
        // opportune, low-power moment (that's what `isDiscretionary` gates).
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        reconcile()
    }

    // MARK: - Public API

    /// Hands a picked file off to be transferred in the background and
    /// returns an id immediately -- callers (`UploadViewModel`) don't await
    /// completion here; that's the entire point. `sourceURL` must already
    /// be a file on disk (not in-memory `Data`) -- `UploadViewModel` writes
    /// a picked image to a temp file before calling this, same as it
    /// already did for a picked video.
    ///
    /// BUGFIX (confirmed live, 2026-09-14): the copy of `sourceURL` into
    /// this manager's own storage used to happen inside a `Task.detached`,
    /// racing `UploadView`'s button action, which calls
    /// `viewModel.reset()` (deleting the picked file) immediately after
    /// this returns. When the detached copy lost that race, the source was
    /// already gone by the time it ran -- `copyItem` against a missing
    /// file just silently produced nothing usable, and the resulting
    /// multipart body went out with an empty file field. Confirmed live:
    /// two uploads both 400'd with "Upload is empty" after the background
    /// transfer actually completed (~125s each). Copying synchronously
    /// here, on the caller's thread, before returning, closes the window
    /// completely -- by the time `enqueue` returns, the source is safely
    /// duplicated and the caller is free to delete its own copy.
    @discardableResult
    func enqueue(sourceURL: URL, filename: String, mimeType: String, fields: GalleryAPIClient.UploadFields) -> String {
        let id = UUID().uuidString
        progress[id] = 0
        do {
            try fileManager.createDirectory(at: uploadDirectory(id), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: sourcePath(id))
        } catch {
            DiagnosticsReporter.reportUpload(outcome: "error", method: "unknown", durationMs: 0, bytes: 0, errorMessage: "Could not prepare upload: \(error.localizedDescription)")
            progress[id] = nil
            completionNotice = "Could not start the upload: \(error.localizedDescription)"
            return id
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let totalSize = (try? self.fileManager.attributesOfItem(atPath: self.sourcePath(id).path)[.size] as? Int) ?? nil ?? 0
            let formFields = GalleryAPIClient.shared.uploadForm(fields)
            let fieldsJSON = (try? JSONEncoder().encode(formFields)) ?? Data()
            let phase: ManagedUpload.Phase = totalSize > Self.chunkedThresholdBytes ? .initializingChunked : .sendingSmall
            let upload = ManagedUpload(
                id: id, filename: filename, mimeType: mimeType, fieldsJSON: fieldsJSON, totalSize: totalSize,
                phase: phase, enqueuedAt: Date()
            )
            self.saveState(upload)
            await self.advance(id: id)
        }
        return id
    }

    // MARK: - Persisted state

    private struct ManagedUpload: Codable {
        enum Phase: String, Codable {
            case sendingSmall
            case initializingChunked
            case sendingChunks
            case finishingChunked
        }

        let id: String
        let filename: String
        let mimeType: String
        let fieldsJSON: Data
        let totalSize: Int
        var phase: Phase

        // Chunked-path only:
        var sessionId: String?
        var chunkSize: Int?
        var nextChunkIndex: Int = 0
        var chunksSent: Int = 0

        /// Correlates a live `URLSessionTask` back to this record -- the
        /// only way a delegate callback (possibly in a freshly relaunched
        /// process) knows which persisted upload it belongs to.
        var currentTaskIdentifier: Int?
        var retryCount: Int = 0
        let enqueuedAt: Date
    }

    private var rootDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingUploads", isDirectory: true)
    }
    private func uploadDirectory(_ id: String) -> URL { rootDirectory.appendingPathComponent(id, isDirectory: true) }
    private func statePath(_ id: String) -> URL { uploadDirectory(id).appendingPathComponent("state.json") }
    private func sourcePath(_ id: String) -> URL { uploadDirectory(id).appendingPathComponent("source") }
    private func chunkPath(_ id: String, _ index: Int) -> URL { uploadDirectory(id).appendingPathComponent("chunk_\(index).bin") }
    private func smallBodyPath(_ id: String) -> URL { uploadDirectory(id).appendingPathComponent("body.multipart") }
    private func finishBodyPath(_ id: String) -> URL { uploadDirectory(id).appendingPathComponent("finish.json") }

    private func excludeRootDirectoryFromBackup() {
        var url = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func loadState(_ id: String) -> ManagedUpload? {
        guard let data = try? Data(contentsOf: statePath(id)) else { return nil }
        return try? JSONDecoder().decode(ManagedUpload.self, from: data)
    }

    private func saveState(_ upload: ManagedUpload) {
        guard let data = try? JSONEncoder().encode(upload) else { return }
        try? data.write(to: statePath(upload.id), options: .atomic)
    }

    private func allPersistedIds() -> [String] {
        (try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil))?.map { $0.lastPathComponent } ?? []
    }

    private func findUpload(forTask taskIdentifier: Int) -> ManagedUpload? {
        for id in allPersistedIds() {
            if let upload = loadState(id), upload.currentTaskIdentifier == taskIdentifier { return upload }
        }
        return nil
    }

    private func cleanup(_ id: String) {
        try? fileManager.removeItem(at: uploadDirectory(id))
    }

    // MARK: - Reconciliation (app launch / long background stretch)

    /// Cross-checks every persisted upload against the session's actual
    /// live tasks -- one whose `currentTaskIdentifier` isn't there anymore
    /// (the OS discarded it, or this is a cold non-background-event
    /// launch) gets a fresh task issued for its current phase instead of
    /// being silently abandoned.
    private func reconcile() {
        let ids = allPersistedIds()
        guard !ids.isEmpty else { return }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let liveTaskIds = Set(tasks.map(\.taskIdentifier))
            for id in ids {
                guard var upload = self.loadState(id) else { continue }
                // Matches the server's own upload-job TTL convention
                // (routes.lua's upload_chunk_storage.job_prune, 24h) --
                // nothing legitimate should still be pending this long.
                if Date().timeIntervalSince(upload.enqueuedAt) > 24 * 3600 {
                    self.cleanup(id)
                    continue
                }
                if let currentTaskId = upload.currentTaskIdentifier, liveTaskIds.contains(currentTaskId) {
                    continue // Genuinely still in flight -- leave it alone.
                }
                upload.currentTaskIdentifier = nil
                self.saveState(upload)
                DispatchQueue.main.async { self.progress[id] = 0 }
                Task.detached(priority: .utility) { await self.advance(id: id) }
            }
        }
    }

    // MARK: - Reducer: given an id, figure out the next step and do it

    private func advance(id: String) async {
        guard var upload = loadState(id) else { return }
        switch upload.phase {
        case .sendingSmall:
            startSmallUploadTask(upload: upload)
        case .initializingChunked:
            // The one foreground call in this whole flow: small, fast, and
            // the app is definitionally active right after the user tapped
            // Submit. Only the actual byte transfer that follows needs
            // background-transfer resilience.
            do {
                let response = try await GalleryAPIClient.shared.uploadInit(totalSize: upload.totalSize, filename: upload.filename)
                upload.sessionId = response.sessionId
                upload.chunkSize = response.chunkSize
                upload.phase = .sendingChunks
                saveState(upload)
                await advance(id: id)
            } catch {
                markFailed(upload: upload, error: error)
            }
        case .sendingChunks:
            startNextChunkTask(upload: upload)
        case .finishingChunked:
            startFinishTask(upload: upload)
        }
    }

    private func startSmallUploadTask(upload: ManagedUpload) {
        do {
            let boundary = "ImageGallery-\(UUID().uuidString)"
            let bodyURL = try composeSmallMultipartBody(upload: upload, boundary: boundary)
            var request = try GalleryAPIClient.shared.baseRequest(path: "/api/media", method: "POST", query: nil, requiresAuth: true)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: bodyURL)
            var updated = upload
            updated.currentTaskIdentifier = task.taskIdentifier
            saveState(updated)
            task.resume()
        } catch {
            markFailed(upload: upload, error: error)
        }
    }

    private func startNextChunkTask(upload: ManagedUpload) {
        guard let sessionId = upload.sessionId, let chunkSize = upload.chunkSize else {
            markFailed(upload: upload, error: GalleryAPIError.http(status: 0, message: "Missing upload session."))
            return
        }
        do {
            let chunkURL = try writeChunkFile(upload: upload, index: upload.nextChunkIndex, chunkSize: chunkSize)
            var request = try GalleryAPIClient.shared.baseRequest(
                path: "/api/media/upload/chunk", method: "POST",
                query: ["session_id": sessionId, "index": String(upload.nextChunkIndex)], requiresAuth: true
            )
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: chunkURL)
            var updated = upload
            updated.currentTaskIdentifier = task.taskIdentifier
            saveState(updated)
            task.resume()
        } catch {
            markFailed(upload: upload, error: error)
        }
    }

    private func startFinishTask(upload: ManagedUpload) {
        do {
            var fields = (try? JSONDecoder().decode([String: String].self, from: upload.fieldsJSON)) ?? [:]
            fields["session_id"] = upload.sessionId
            let bodyData = try JSONEncoder().encode(fields)
            let bodyURL = finishBodyPath(upload.id)
            try bodyData.write(to: bodyURL, options: .atomic)
            var request = try GalleryAPIClient.shared.baseRequest(path: "/api/media/upload/finish", method: "POST", query: nil, requiresAuth: true)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: bodyURL)
            var updated = upload
            updated.currentTaskIdentifier = task.taskIdentifier
            saveState(updated)
            task.resume()
        } catch {
            markFailed(upload: upload, error: error)
        }
    }

    // MARK: - Body composition

    /// Same multipart wire format `GalleryAPIClient.upload`'s `.fileURL`
    /// branch produces (identical boundary/header shape) -- the backend's
    /// `httpd.lua` multipart parser doesn't care which client built it, but
    /// keeping the shape identical is one less thing to get wrong.
    private func composeSmallMultipartBody(upload: ManagedUpload, boundary: String) throws -> URL {
        // Defense in depth: a zero-byte (or missing) source here means
        // something upstream is broken -- fail loudly and let markFailed's
        // retry/give-up path handle it, instead of silently building and
        // sending a structurally-valid-but-empty multipart body the way
        // this did before `enqueue`'s copy race was fixed (confirmed live:
        // that produced a real "Upload is empty" 400 after a full
        // background transfer, not an immediate local failure).
        let sourceSize = (try? fileManager.attributesOfItem(atPath: sourcePath(upload.id).path)[.size] as? Int) ?? nil ?? 0
        guard sourceSize > 0 else {
            throw GalleryAPIError.http(status: 0, message: "The file to upload is missing or empty.")
        }
        let fields = (try? JSONDecoder().decode([String: String].self, from: upload.fieldsJSON)) ?? [:]
        let bodyURL = smallBodyPath(upload.id)
        fileManager.createFile(atPath: bodyURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: bodyURL)
        var head = Data()
        for (key, value) in fields {
            head.append("--\(boundary)\r\n".data(using: .utf8)!)
            head.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            head.append("\(value)\r\n".data(using: .utf8)!)
        }
        head.append("--\(boundary)\r\n".data(using: .utf8)!)
        head.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(upload.filename)\"\r\n".data(using: .utf8)!)
        head.append("Content-Type: \(upload.mimeType)\r\n\r\n".data(using: .utf8)!)
        try writer.write(contentsOf: head)
        let reader = try FileHandle(forReadingFrom: sourcePath(upload.id))
        while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try reader.close()
        try writer.write(contentsOf: "\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        try writer.close()
        return bodyURL
    }

    private func writeChunkFile(upload: ManagedUpload, index: Int, chunkSize: Int) throws -> URL {
        let reader = try FileHandle(forReadingFrom: sourcePath(upload.id))
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(index * chunkSize))
        guard let data = try reader.read(upToCount: chunkSize), !data.isEmpty else {
            throw GalleryAPIError.http(status: 0, message: "Could not read the next chunk to upload.")
        }
        let url = chunkPath(upload.id, index)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func cleanupChunkFile(id: String, index: Int) {
        try? fileManager.removeItem(at: chunkPath(id, index))
    }

    // MARK: - Completion handling

    private func handleSuccess(upload: ManagedUpload, responseData: Data) async {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        switch upload.phase {
        case .sendingSmall:
            do {
                _ = try decoder.decode(MediaUploadResponse.self, from: responseData)
                finishSuccessfully(upload: upload, method: "direct")
            } catch {
                markFailed(upload: upload, error: error)
            }

        case .sendingChunks:
            var updated = upload
            updated.nextChunkIndex += 1
            updated.chunksSent += 1
            updated.retryCount = 0
            let sentSoFar = updated.nextChunkIndex * (updated.chunkSize ?? 0)
            if sentSoFar >= updated.totalSize {
                updated.phase = .finishingChunked
            }
            saveState(updated)
            cleanupChunkFile(id: updated.id, index: updated.nextChunkIndex - 1)
            await advance(id: updated.id)

        case .finishingChunked:
            struct FinishAck: Decodable { var status: String; var jobId: String? }
            do {
                let ack = try decoder.decode(FinishAck.self, from: responseData)
                guard let jobId = ack.jobId else {
                    markFailed(upload: upload, error: GalleryAPIError.http(status: 0, message: "Unexpected response finishing upload."))
                    return
                }
                // From here on, this is EXACTLY the existing recovery path:
                // PendingUploadJobStore + UploadRecoveryService's foreground
                // poll resolve this the same way whether the job id came
                // from this background transfer or (previously) an inline
                // awaited one. Nothing past this point changes.
                PendingUploadJobStore.add(jobId: jobId, filename: upload.filename)
                finishSuccessfully(upload: upload, method: "chunked")
            } catch {
                markFailed(upload: upload, error: error)
            }

        case .initializingChunked:
            break // Unreachable: this phase never itself produces a task completion.
        }
    }

    private func finishSuccessfully(upload: ManagedUpload, method: String) {
        let durationMs = Int(Date().timeIntervalSince(upload.enqueuedAt) * 1000)
        DiagnosticsReporter.reportUpload(
            outcome: "success", method: method, durationMs: durationMs, bytes: upload.totalSize,
            chunkCount: upload.chunksSent > 0 ? upload.chunksSent : nil, retryCount: upload.retryCount
        )
        let filename = upload.filename
        let queuedForProcessing = method == "chunked"
        DispatchQueue.main.async { [weak self] in
            self?.progress[upload.id] = nil
            self?.completionNotice = queuedForProcessing
                ? "\"\(filename)\" queued — we'll let you know when it's ready."
                : "\"\(filename)\" finished uploading."
        }
        cleanup(upload.id)
    }

    private func markFailed(upload: ManagedUpload, error: Error) {
        var upload = upload
        upload.retryCount += 1
        if upload.retryCount <= Self.maxRetries {
            saveState(upload)
            let delaySeconds = Double(upload.retryCount) * 2.0
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                await self?.advance(id: upload.id)
            }
            return
        }
        let durationMs = Int(Date().timeIntervalSince(upload.enqueuedAt) * 1000)
        let method = upload.phase == .sendingSmall ? "direct" : "chunked"
        DiagnosticsReporter.reportUpload(
            outcome: "error", method: method, durationMs: durationMs, bytes: upload.totalSize,
            chunkCount: upload.chunksSent > 0 ? upload.chunksSent : nil, retryCount: upload.retryCount,
            errorMessage: error.localizedDescription
        )
        let filename = upload.filename
        DispatchQueue.main.async { [weak self] in
            self?.progress[upload.id] = nil
            self?.completionNotice = "Upload of \"\(filename)\" failed: \(error.localizedDescription)"
        }
        cleanup(upload.id)
    }
}

// MARK: - URLSessionTaskDelegate / URLSessionDataDelegate

extension BackgroundUploadManager: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let upload = findUpload(forTask: task.taskIdentifier) else { return }
        let base = upload.phase == .sendingChunks ? upload.nextChunkIndex * (upload.chunkSize ?? 1) : 0
        let overallSent = base + Int(totalBytesSent)
        let fraction = upload.totalSize > 0 ? min(1.0, Double(overallSent) / Double(upload.totalSize)) : 0
        let id = upload.id
        DispatchQueue.main.async { [weak self] in self?.progress[id] = fraction }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBuffers[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        let buffered = responseBuffers.removeValue(forKey: taskId) ?? Data()
        let response = task.response
        Task.detached(priority: .utility) { [weak self] in
            guard let self, let upload = self.findUpload(forTask: taskId) else { return }
            if let error {
                self.markFailed(upload: upload, error: error)
                return
            }
            do {
                try GalleryAPIClient.shared.validate(response ?? URLResponse(), data: buffered)
            } catch {
                self.markFailed(upload: upload, error: error)
                return
            }
            await self.handleSuccess(upload: upload, responseData: buffered)
        }
    }

    /// iOS calls this once every queued delegate event for this background
    /// session has been replayed to this (possibly freshly relaunched)
    /// process -- the signal to call the completion handler `AppDelegate`
    /// stashed, telling the system this process is done and can suspend.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
