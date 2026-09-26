import SwiftUI
import UIKit

struct MediaDetailView: View {
    @StateObject private var viewModel: MediaDetailViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var showingReport = false
    @State private var showingEdit = false
    @State private var showingAgeVerification = false
    @State private var showingFullScreen = false
    @State private var originalURL: URL?
    @State private var showingOriginalInApp = false
    @State private var videoController: VideoPlayerController?
    /// Seeded from this device's own last explicit pick rather than
    /// always "original": someone on a capped connection who chooses 480p
    /// means it for their connection, not for one post. Web does the same
    /// (MediaDetailPage's `getPlayerPref("quality", ...)`).
    @State private var videoQuality = PlaybackPreferences.quality
    /// True once the backend reports a generated caption track for this
    /// post, which changes WHICH manifest the player is pointed at -- see
    /// `videoQualityURL`.
    @State private var hasCaptions = false

    private static let qualityOptions: [(String, String)] = [
        ("original", "Original"),
        ("1080p", "1080p HD"),
        ("720p", "720p"),
        ("480p", "480p"),
        ("144p", "144p"),
    ]

    init(mediaId: Int) {
        _viewModel = StateObject(wrappedValue: MediaDetailViewModel(mediaId: mediaId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let media = viewModel.media {
                    mediaViewer(media)

                    Text(media.title?.nilIfEmpty ?? "Untitled")
                        .font(.title2).bold()

                    UploaderRow(media: media)

                    if let description = media.description, !description.isEmpty {
                        Text(description)
                    }

                    MediaActionBar(
                        media: media,
                        isTogglingLike: viewModel.isTogglingLike,
                        isTogglingBookmark: viewModel.isTogglingBookmark,
                        onLike: { Task { await viewModel.toggleLike() } },
                        onBookmark: { Task { await viewModel.toggleBookmark() } },
                        onReport: { showingReport = true },
                        onOpenOriginal: { openOriginal(media) }
                    )

                    ReactionTray(reactions: viewModel.reactions) { emoji in
                        Task { await viewModel.react(emoji: emoji) }
                    }

                    if session.currentUser != nil {
                        PersonalTagsSection(viewModel: viewModel)
                    }

                    Divider()
                    CommentsSection(viewModel: viewModel)

                    Divider()
                    Label("More like this", systemImage: "square.grid.2x2").font(.headline)
                    SimilarMediaRail(items: viewModel.similar)
                } else if viewModel.isLoading {
                    ProgressView().padding(.top, 80)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.media?.title ?? "Media")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
            setUpVideoControllerIfNeeded()
            if let media = viewModel.media { await loadPlaybackExtras(for: media) }
        }
        .sheet(isPresented: $showingReport) { ReportSheet(viewModel: viewModel) }
        .sheet(isPresented: $showingEdit) { MediaEditSheet(viewModel: viewModel) }
        // Owner-only, and driven off the loaded media rather than a passed-in
        // flag so it stays correct when the view model reloads the post.
        .toolbar {
            if let media = viewModel.media,
               let viewerId = session.currentUser?.id,
               media.userId == viewerId {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingEdit = true } label: { Label("Edit", systemImage: "pencil") }
                }
            }
        }
        .sheet(isPresented: $showingAgeVerification, onDismiss: { Task { await viewModel.load() } }) { AgeVerificationView() }
        // isPresented + a separately-stored URL, not .sheet(item:) -- URL
        // doesn't conform to Identifiable, and this matches the same
        // pattern StudioView/CollectionsListView already use for their own
        // "optional URL drives a sheet" cases (showingDownloadShare +
        // downloadURL).
        .sheet(isPresented: $showingOriginalInApp) {
            if let originalURL { InAppSafariView(url: originalURL) }
        }
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let media = viewModel.media {
                FullScreenMediaView(
                    media: media,
                    videoController: videoController,
                    qualityOptions: Self.qualityOptions,
                    videoQuality: videoQuality,
                    onQualityChange: { changeQuality($0, media: media) }
                )
            }
        }
        .onChange(of: viewModel.media?.id) { _ in
            videoQuality = PlaybackPreferences.quality
            hasCaptions = false
            videoController = nil
            setUpVideoControllerIfNeeded()
            if let media = viewModel.media {
                Task { await loadPlaybackExtras(for: media) }
            }
        }
        .onAppear { setUpVideoControllerIfNeeded() }
        .onDisappear { videoController?.pause() }
    }

    /// Real HLS instead of a single Range-served file: AVPlayer has native
    /// HLS support, so this is purely a URL swap. "original" points straight
    /// at that one rendition's own playlist (a fast `-c copy` remux, no
    /// re-encode -- see routes.lua's ensure_hls_variant), NOT the master
    /// playlist -- previously it did, and that's very likely why "original
    /// quality just loads forever" was reported: master.m3u8 hands AVPlayer
    /// genuine ABR across all 4 transcoded renditions, and on a cold
    /// connection/cache, AVPlayer has no bandwidth history to negotiate
    /// with, so it can end up waiting on a rendition that isn't ready yet
    /// (the backend's serve_hls_playlist 503s "still starting up" for up to
    /// 8s server-side while a transcode is in flight, and there's nothing
    /// here retrying that the way the native/hls.js error paths in
    /// VideoPlayer.jsx do). The web app hit this exact problem and
    /// deliberately reverted away from master.m3u8 for "original" -- see
    /// videoQualityUrl's comment in utils/media.js -- this brings iOS in
    /// line with that already-proven fix instead of independently
    /// rediscovering it.
    private func videoQualityURL(_ media: MediaItem, quality: String) -> URL? {
        guard let urlString = media.url, var components = URLComponents(string: urlString) else { return nil }
        let accessToken = (components.queryItems ?? []).first { $0.name == "access" }?.value
        guard components.path.hasSuffix("/file") else { return nil }
        let base = String(components.path.dropLast("/file".count))
        let rendition = (quality == "original" || quality.isEmpty || quality == "high") ? "original" : quality
        // With captions available, point at the per-quality MASTER rather
        // than the rendition playlist. AVPlayer cannot side-load a
        // subtitle file the way a browser can attach a <track> -- a
        // subtitle rendition declared in a manifest is the only route it
        // has -- and AVKit then surfaces its own caption button and
        // honours the system's Closed Captions accessibility setting for
        // free.
        //
        // This master wraps exactly ONE rendition (see
        // video_extras.serve_quality_master), so it changes nothing about
        // which video segments get fetched. That matters: the site-wide
        // master.m3u8 offers real ABR across the whole ladder, and
        // pointing iOS at THAT is what caused "original quality just
        // loads forever" and was reverted -- AVPlayer picks a level from
        // a bandwidth estimate it doesn't have yet on a cold connection.
        // The explicit quality the viewer chose stays exactly as it is.
        components.path = base + "/hls/\(rendition)/" + (hasCaptions ? "master.m3u8" : "playlist.m3u8")
        components.queryItems = accessToken.map { [URLQueryItem(name: "access", value: $0)] }
        return components.url
    }

    /// The rendition playlist for the same quality -- the document that
    /// actually 503s while a transcode is cold, which is what the
    /// controller's readiness preflight has to wait on. See
    /// `VideoPlayerController.preflightURL`.
    private func variantPlaylistURL(_ media: MediaItem, quality: String) -> URL? {
        guard hasCaptions else { return nil }
        guard let urlString = media.url, var components = URLComponents(string: urlString) else { return nil }
        let accessToken = (components.queryItems ?? []).first { $0.name == "access" }?.value
        guard components.path.hasSuffix("/file") else { return nil }
        let base = String(components.path.dropLast("/file".count))
        let rendition = (quality == "original" || quality.isEmpty || quality == "high") ? "original" : quality
        components.path = base + "/hls/\(rendition)/playlist.m3u8"
        components.queryItems = accessToken.map { [URLQueryItem(name: "access", value: $0)] }
        return components.url
    }

    /// Asks the backend whether this post has a caption track yet, and
    /// starts generating one if not. Cheap, and deliberately fire and
    /// forget: captions are a background nicety, so a failure here just
    /// means the player keeps the manifest it already has.
    private func loadPlaybackExtras(for media: MediaItem) async {
        guard media.isVideo, !hasCaptions else { return }
        guard let extras = try? await GalleryAPIClient.shared.playbackExtras(mediaId: media.id) else { return }
        guard extras.captions?.status == "ready" else { return }
        hasCaptions = true
        // Re-point the live player at the captioned manifest. setURL
        // carries the current position across (see VideoPlayerController),
        // so this is invisible beyond the caption button appearing.
        if let controller = videoController, let url = videoQualityURL(media, quality: videoQuality) {
            controller.setURL(url, quality: videoQuality, preflightURL: variantPlaylistURL(media, quality: videoQuality))
        }
    }

    // open_original_in_new_tab -- web's literal "new tab" framing doesn't
    // map 1:1 to iOS (there's no tab to stay on), so the natural
    // equivalent is "leave the app" (launch system Safari) vs. "stay in
    // the app" (an embedded SFSafariViewController sheet). This is the
    // one iOS action MediaActionBar never had at all before this -- there
    // was no "Open Original" anywhere in the app, unlike web's
    // MediaActionPanel.
    private func openOriginal(_ media: MediaItem) {
        guard let urlString = media.url, let url = URL(string: urlString) else { return }
        if session.currentUser?.userSettings?.openOriginalInNewTab == true {
            UIApplication.shared.open(url)
        } else {
            originalURL = url
            showingOriginalInApp = true
        }
    }

    private func setUpVideoControllerIfNeeded() {
        guard videoController == nil, let media = viewModel.media, media.isVideo else { return }
        guard let url = videoQualityURL(media, quality: videoQuality) else { return }
        videoController = VideoPlayerController(
            url: url,
            mediaId: media.id,
            quality: videoQuality,
            title: media.title?.nilIfEmpty ?? "Nyxframe video",
            author: media.displayName ?? media.username,
            // Doubles as the lock screen's artwork. The thumbnail, not
            // the original: this is displayed at a few hundred points and
            // gets fetched on every video, so the multi-MB source would
            // be pure waste.
            artworkURL: media.thumbUrl.flatMap(URL.init(string:)),
            preflightURL: variantPlaylistURL(media, quality: videoQuality)
        )
    }

    private func changeQuality(_ quality: String, media: MediaItem) {
        guard quality != videoQuality else { return }
        videoQuality = quality
        // Every call here comes from the quality menu, i.e. is a
        // deliberate choice -- the player never picks a rendition for
        // itself on iOS the way web's codec fallback does, so there is no
        // automatic switch that could pollute this.
        PlaybackPreferences.quality = quality
        guard let controller = videoController, let url = videoQualityURL(media, quality: quality) else { return }
        controller.setURL(url, quality: quality, preflightURL: variantPlaylistURL(media, quality: quality))
    }

    private var qualityMenu: some View {
        VideoQualityMenu(options: Self.qualityOptions, current: videoQuality) { value in
            if let media = viewModel.media { changeQuality(value, media: media) }
        }
    }

    @ViewBuilder
    private func mediaViewer(_ media: MediaItem) -> some View {
        if media.locked == true {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 36))
                Text("Age verification required for this 18+ post.")
                Button("Verify Age") { showingAgeVerification = true }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .softCard()
        } else if media.isVideo, let player = videoController {
            ZStack(alignment: .topTrailing) {
                AuthenticatedVideoPlayer(controller: player)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.md, style: .continuous))
                    .cardShadow()
                HStack(spacing: 4) {
                    qualityMenu
                    expandButton
                }
            }
        } else if let urlString = media.previewUrl?.nilIfEmpty ?? media.url, let url = URL(string: urlString) {
            // `previewUrl` is a server-resized/recompressed WEBP (capped at
            // 1920px), not the raw original `url` — this inline viewer is
            // capped to 480pt tall anyway, so fetching the full multi-MB
            // original here just makes the first paint slow for no visible
            // benefit. `FullScreenMediaView` (reached via `expandButton`
            // below) still uses the true original for full quality once the
            // viewer explicitly asks for it.
            ZStack(alignment: .topTrailing) {
                ZoomableAsyncImage(url: url, diagnostics: ImageLoadDiagnosticsContext(mediaId: media.id, mediaKind: media.mediaKind ?? "", context: "media-detail"))
                // scaledToFit alone is safe from the grid-overlap class of bug
                // (single image, not competing with siblings for layout), but an
                // extreme portrait aspect ratio could still stretch to fill most
                // of the screen — cap it so the rest of the page stays reachable.
                .frame(maxHeight: 480)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                expandButton
            }
        }
    }

    private var expandButton: some View {
        Button {
            showingFullScreen = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
        }
        .padding(8)
        .accessibilityLabel("View fullscreen")
    }
}
