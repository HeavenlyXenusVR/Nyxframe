import Foundation

/// Fire-and-forget client telemetry beacons -- the iOS counterpart to
/// `frontend/src/api.js`'s `postClientDiagnostic` and its three callers
/// (`reportMediaLoadDiagnostic`/`reportMediaPlaybackDiagnostic` in
/// `utils/media.js`, and `UploadPage.jsx`'s own upload beacon). Posts to the
/// exact same three backend endpoints those hit
/// (`routes.media_load_diagnostic`/`media_playback_diagnostic`/
/// `upload_client_diagnostic` in `lua/src/routes.lua`) so the admin
/// telemetry panel sees both clients the same way.
///
/// Every call here is best-effort: wrapped in `Task.detached` with errors
/// swallowed, exactly like web's beacon "never blocks/affects the actual
/// [load/playback/upload]" contract. `GalleryAPIClient.requestJSON` already
/// does everything needed (auth header, URL building, snake_case encoding)
/// -- no separate networking path required.
enum DiagnosticsReporter {
    private struct OkResponse: Decodable { var ok: Bool }

    private static func post<B: Encodable>(_ path: String, body: B) {
        Task.detached(priority: .utility) {
            _ = try? await GalleryAPIClient.shared.requestJSON(path, body: body) as OkResponse
        }
    }

    // MARK: Image load (mirrors ResilientImage/reportMediaLoadDiagnostic)

    private struct MediaLoadBody: Encodable {
        var context: String
        var outcome: String
        var mediaKind: String
        var selectedSource: String?
        var failedSources: [String]?
        var sourceCount: Int?
    }

    static func reportMediaLoad(
        mediaId: Int, mediaKind: String, context: String, outcome: String,
        selectedSource: String? = nil, failedSources: [String]? = nil, sourceCount: Int? = nil
    ) {
        guard mediaId > 0 else { return }
        post(
            "/api/media/\(mediaId)/diagnostics/load",
            body: MediaLoadBody(
                context: context, outcome: outcome, mediaKind: mediaKind,
                selectedSource: selectedSource, failedSources: failedSources, sourceCount: sourceCount
            )
        )
    }

    // MARK: Video/HLS playback (mirrors VideoPlayer.jsx's playbackStatsRef)

    private struct MediaPlaybackBody: Encodable {
        var outcome: String
        var quality: String?
        var timeToFirstFrameMs: Int?
        var stallCount: Int
        var stallTotalMs: Int
        var qualityDowngradeCount: Int
        var usingHlsJs: Bool
    }

    static func reportMediaPlayback(
        mediaId: Int, outcome: String, quality: String?, timeToFirstFrameMs: Int?,
        stallCount: Int, stallTotalMs: Int, retryCount: Int
    ) {
        guard mediaId > 0 else { return }
        post(
            "/api/media/\(mediaId)/diagnostics/playback",
            body: MediaPlaybackBody(
                outcome: outcome, quality: quality, timeToFirstFrameMs: timeToFirstFrameMs,
                stallCount: stallCount, stallTotalMs: stallTotalMs,
                // No auto quality-downgrade concept on iOS (AVPlayer handles
                // codec compatibility itself, unlike web's hls.js fallback
                // ladder) -- retryCount is the closest iOS-native signal of
                // "playback needed help", reported here instead so it isn't
                // lost, even though it isn't a downgrade count.
                qualityDowngradeCount: retryCount, usingHlsJs: false
            )
        )
    }

    // MARK: Upload (mirrors UploadPage.jsx's post-submit beacon)

    private struct UploadDiagnosticBody: Encodable {
        var outcome: String
        var method: String
        var durationMs: Int
        var bytes: Int
        var chunkCount: Int?
        var retryCount: Int
        var errorMessage: String?
    }

    static func reportUpload(
        outcome: String, method: String, durationMs: Int, bytes: Int,
        chunkCount: Int? = nil, retryCount: Int = 0, errorMessage: String? = nil
    ) {
        post(
            "/api/media/upload/diagnostics",
            body: UploadDiagnosticBody(
                outcome: outcome, method: method, durationMs: durationMs, bytes: bytes,
                chunkCount: chunkCount, retryCount: retryCount,
                errorMessage: errorMessage.map { String($0.prefix(300)) }
            )
        )
    }
}
