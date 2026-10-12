import Combine
import Foundation

@MainActor
final class MediaDetailViewModel: ObservableObject {
    @Published var media: MediaItem?
    @Published var comments: [Comment] = []
    @Published var reactions = ReactionsSummary(counts: [:], myReaction: nil)
    @Published var similar: [MediaItem] = []
    @Published var personalTags: [String] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var replyTarget: Comment?
    @Published var isTogglingLike = false
    @Published var isTogglingBookmark = false
    /// "N people viewing this now" -- nil until the first heartbeat lands,
    /// mirrors web's `viewingNow` (MediaDetailPage.jsx) staying null rather
    /// than 0 before that, so `MediaDetailView` can tell "no data yet" from
    /// "confirmed nobody else is here" and keep the badge hidden either way.
    @Published var viewingNow: Int?
    @Published var editHistory: [EditHistoryEntry]?
    @Published var editHistoryError: String?

    let mediaId: Int
    private let api = GalleryAPIClient.shared
    private var heartbeatTask: Task<Void, Never>?

    init(mediaId: Int) {
        self.mediaId = mediaId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let detail = try await api.mediaDetail(id: mediaId)
            media = detail.media
            comments = detail.comments ?? []
            reactions = detail.reactions ?? ReactionsSummary(counts: [:], myReaction: nil)
            similar = detail.similar ?? []
            personalTags = detail.personalTags ?? []
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func toggleLike() async {
        guard let media, !isTogglingLike else { return }
        isTogglingLike = true
        defer { isTogglingLike = false }
        do {
            self.media = try await api.setLiked(mediaId: media.id, liked: !(media.likedByMe ?? false))
            Haptics.light()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func toggleBookmark() async {
        guard let media, !isTogglingBookmark else { return }
        isTogglingBookmark = true
        defer { isTogglingBookmark = false }
        do {
            self.media = try await api.setBookmarked(mediaId: media.id, bookmarked: !(media.bookmarkedByMe ?? false))
            Haptics.light()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func react(emoji: String) async {
        guard let media else { return }
        do {
            reactions = try await api.react(mediaId: media.id, emoji: emoji)
            Haptics.light()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func postComment(body: String) async {
        guard let media, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let comment = try await api.addComment(mediaId: media.id, body: body, parentCommentId: replyTarget?.id)
            comments.append(comment)
            replyTarget = nil
            Haptics.light()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Same one-emoji-toggle semantics as `react(emoji:)` above, just
    /// keyed by comment id. Patches the one affected row in `comments`
    /// in place rather than re-fetching the whole post.
    func reactToComment(_ comment: Comment, emoji: String) async {
        do {
            let reactions = try await api.reactToComment(commentId: comment.id, emoji: emoji)
            if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[index].reactions = reactions
            }
            Haptics.light()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Starts (or restarts) the "N people viewing this now" heartbeat --
    /// mirrors web's `useLiveRefresh(sendViewingHeartbeat, { interval:
    /// 15_000, immediate: true })`. `MediaDetailView` calls `stop` when the
    /// tab holding this screen goes inactive (same reasoning as its video
    /// pause -- someone who switched tabs isn't actively viewing either)
    /// and `start` again when it comes back.
    func startViewingHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let count = await self.api.sendViewingHeartbeat(mediaId: self.mediaId)
                if Task.isCancelled { return }
                self.viewingNow = count
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopViewingHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Owner-only, lazily loaded the first time the Edit History
    /// disclosure is expanded -- mirrors web's `MediaEditHistory`, which
    /// fetches eagerly on mount but sits behind its own collapsed
    /// `<details>` already; gating the fetch itself on first expansion is
    /// the iOS-side equivalent since there's no "mounted but collapsed"
    /// state for a SwiftUI `DisclosureGroup`.
    func loadEditHistoryIfNeeded() async {
        guard editHistory == nil else { return }
        do {
            editHistory = try await api.mediaEditHistory(mediaId: mediaId)
        } catch {
            if !error.isCancellation { editHistoryError = error.localizedDescription }
        }
    }

    func deleteComment(_ comment: Comment) async {
        do {
            try await api.deleteComment(id: comment.id)
            comments.removeAll { $0.id == comment.id }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func addPersonalTag(_ tag: String) async {
        guard let media, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            personalTags = try await api.addPersonalTag(mediaId: media.id, tag: tag)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func removePersonalTag(_ tag: String) async {
        guard let media else { return }
        do {
            personalTags = try await api.removePersonalTag(mediaId: media.id, tag: tag)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func report(reason: String, details: String?) async -> Bool {
        guard let media else { return false }
        do {
            try await api.reportMedia(mediaId: media.id, reason: reason, details: details)
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return false
        }
    }

    /// Full post edit. Echoes the post's current control values back
    /// unchanged alongside the edited fields -- `PATCH /api/media/:id`
    /// replaces the record rather than patching named keys, so anything not
    /// sent is reset to its default (visibility back to public, 18+ silently
    /// cleared). See GalleryAPIClient.UpdateMediaBody.
    func updatePost(
        title: String,
        description: String,
        tags: [String],
        categoryId: Int,
        subcategoryIds: [Int],
        subcategoryNames: [String],
        isAdult: Bool
    ) async -> Bool {
        guard let media else { return false }
        do {
            let updated = try await api.updateMedia(mediaId: media.id, body: .init(
                title: title,
                description: description,
                tags: tags,
                categoryId: categoryId,
                subcategoryIds: subcategoryIds,
                subcategoryNames: subcategoryNames,
                isAdult: isAdult,
                visibility: media.visibility ?? "public",
                commentsEnabled: media.commentsEnabled ?? true,
                downloadsEnabled: media.downloadsEnabled ?? true,
                pinned: media.pinnedAt != nil
            ))
            self.media = updated
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return false
        }
    }

    /// Top-level comments with their replies nested, mirroring the web app's
    /// `MediaDetailPage.jsx` comment-threading logic.
    var topLevelComments: [Comment] {
        comments.filter { $0.parentCommentId == nil }
    }

    func replies(to comment: Comment) -> [Comment] {
        comments.filter { $0.parentCommentId == comment.id }
    }
}
