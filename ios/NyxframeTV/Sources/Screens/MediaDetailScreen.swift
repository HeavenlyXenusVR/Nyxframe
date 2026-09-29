import SwiftUI

/// One post. `siblings` is the list it was opened from, so Previous/Next
/// walk through the same feed without backing out.
struct MediaDetailScreen: View {
    let siblings: [Int]
    @State private var currentId: Int

    init(mediaId: Int, siblings: [Int]) {
        self.siblings = siblings
        _currentId = State(initialValue: mediaId)
    }

    var body: some View {
        MediaDetailContent(
            mediaId: currentId,
            previousId: neighbor(-1),
            nextId: neighbor(1),
            onNavigate: { currentId = $0 }
        )
        .id(currentId)
    }

    private func neighbor(_ offset: Int) -> Int? {
        guard let index = siblings.firstIndex(of: currentId) else { return nil }
        let target = index + offset
        return siblings.indices.contains(target) ? siblings[target] : nil
    }
}

private struct MediaDetailContent: View {
    let mediaId: Int
    let previousId: Int?
    let nextId: Int?
    let onNavigate: (Int) -> Void

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var navigator: TVNavigator
    @StateObject private var viewModel: MediaDetailViewModel
    @State private var playingVideo = false
    @State private var viewingImage = false
    @State private var commentDraft = ""

    private static let reactions = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    init(mediaId: Int, previousId: Int?, nextId: Int?, onNavigate: @escaping (Int) -> Void) {
        self.mediaId = mediaId
        self.previousId = previousId
        self.nextId = nextId
        self.onNavigate = onNavigate
        _viewModel = StateObject(wrappedValue: MediaDetailViewModel(mediaId: mediaId))
    }

    var body: some View {
        Group {
            if let media = viewModel.media {
                content(media)
            } else if viewModel.isLoading || viewModel.errorMessage == nil {
                TVLoadingView()
            } else {
                TVMessageView(systemImage: "exclamationmark.triangle", title: "Couldn't open this post", message: viewModel.errorMessage) {
                    Task { await viewModel.load() }
                }
            }
        }
        .tvScreenBackground()
        .task { await viewModel.load() }
        .fullScreenCover(isPresented: $playingVideo) {
            if let media = viewModel.media { TVVideoPlayerScreen(media: media) }
        }
        .fullScreenCover(isPresented: $viewingImage) {
            if let media = viewModel.media { TVImageViewer(media: media) }
        }
    }

    // MARK: Layout

    private func content(_ media: MediaItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                HStack(alignment: .top, spacing: 60) {
                    stage(media)
                        .frame(width: 1060, height: 596)
                    info(media)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focusSection()

                actions(media)
                comments(media)
                TVMediaShelf(title: "More like this", items: viewModel.similar) { item, all in
                    navigator.openMedia(item, in: all)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
    }

    @ViewBuilder
    private func stage(_ media: MediaItem) -> some View {
        if media.locked == true {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    VStack(spacing: 16) {
                        Image(systemName: "lock.fill").font(.system(size: 64))
                        Text("18+ post").font(.title3.bold())
                        Text(session.currentUser == nil
                             ? "Sign in with an age-verified account to view it."
                             : "Verify your age on the Nyxframe website to view it.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(40)
                )
        } else {
            Button {
                if media.isVideo { playingVideo = true } else { viewingImage = true }
            } label: {
                ZStack {
                    CachedAsyncImage(url: (media.isVideo ? media.thumbUrl : (media.previewUrl?.nilIfEmpty ?? media.url)).flatMap(URL.init(string:))) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFit()
                        default: Color.white.opacity(0.05)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.5))
                    Image(systemName: media.isVideo ? "play.circle.fill" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: media.isVideo ? 120 : 44))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 12)
                }
            }
            .buttonStyle(.card)
            .accessibilityLabel(media.isVideo ? "Play video" : "View full screen")
        }
    }

    private func info(_ media: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(media.title?.nilIfEmpty ?? "Untitled")
                .font(.title.bold())
                .lineLimit(3)
            if let username = media.username {
                TVUserChip(username: username, displayName: media.displayName, avatarUrl: media.userAvatarUrl,
                           subtitle: DateFormatting.relative(media.createdAt))
            }
            if let description = media.description?.nilIfEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(6)
            }
            HStack(spacing: 28) {
                stat("heart.fill", media.likeCount ?? 0)
                stat("eye", media.views ?? 0)
                stat("text.bubble", viewModel.comments.count)
                if let category = media.categoryName {
                    Label(([category] + (media.subcategoryNames ?? [])).joined(separator: " / "), systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let tags = media.tags, !tags.isEmpty {
                Text(tags.prefix(12).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(TVTheme.accent)
                    .lineLimit(2)
            }
            if let source = media.sourceUrl?.nilIfEmpty {
                Label(source, systemImage: "link").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func stat(_ icon: String, _ value: Int) -> some View {
        Label(value.compactString, systemImage: icon).font(.callout).foregroundStyle(.secondary)
    }

    private func actions(_ media: MediaItem) -> some View {
        HStack(spacing: 24) {
            if let previousId {
                Button { onNavigate(previousId) } label: { Label("Previous", systemImage: "chevron.left") }
            }
            if session.currentUser != nil {
                Button {
                    Task { await viewModel.toggleLike() }
                } label: {
                    Label(media.likedByMe == true ? "Liked" : "Like", systemImage: media.likedByMe == true ? "heart.fill" : "heart")
                }
                .disabled(viewModel.isTogglingLike)
                Button {
                    Task { await viewModel.toggleBookmark() }
                } label: {
                    Label(media.bookmarkedByMe == true ? "Saved" : "Save", systemImage: media.bookmarkedByMe == true ? "bookmark.fill" : "bookmark")
                }
                .disabled(viewModel.isTogglingBookmark)
                ForEach(Self.reactions, id: \.self) { emoji in
                    let count = viewModel.reactions.counts?[emoji] ?? 0
                    Button {
                        Task { await viewModel.react(emoji: emoji) }
                    } label: {
                        Text(count > 0 ? "\(emoji) \(count)" : emoji)
                    }
                    .tint(viewModel.reactions.myReaction == emoji ? TVTheme.accent : nil)
                }
            }
            Spacer(minLength: 0)
            if let nextId {
                Button { onNavigate(nextId) } label: { Label("Next", systemImage: "chevron.right") }
            }
        }
        .focusSection()
    }

    private func comments(_ media: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Comments").font(.title3.bold())
            if media.commentsEnabled == false {
                Text("Comments are turned off for this post.").foregroundStyle(.secondary)
            } else {
                if session.currentUser != nil {
                    HStack(spacing: 20) {
                        if let target = viewModel.replyTarget {
                            Button {
                                viewModel.replyTarget = nil
                            } label: {
                                Label("Replying to \(target.displayName ?? target.username ?? "comment")", systemImage: "xmark")
                            }
                        }
                        TextField(viewModel.replyTarget == nil ? "Add a comment" : "Write a reply", text: $commentDraft)
                            .onSubmit(postComment)
                        Button("Post", action: postComment)
                            .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if viewModel.comments.isEmpty {
                    Text("No comments yet.").foregroundStyle(.secondary)
                }
                ForEach(viewModel.topLevelComments) { comment in
                    TVCommentRow(comment: comment, canReply: session.currentUser != nil) { viewModel.replyTarget = comment }
                    ForEach(viewModel.replies(to: comment)) { reply in
                        TVCommentRow(comment: reply, canReply: false) {}
                            .padding(.leading, 80)
                    }
                }
            }
        }
        .focusSection()
    }

    private func postComment() {
        let body = commentDraft
        commentDraft = ""
        Task { await viewModel.postComment(body: body) }
    }
}

private struct TVCommentRow: View {
    let comment: Comment
    let canReply: Bool
    let onReply: () -> Void

    var body: some View {
        Button {
            if canReply { onReply() }
        } label: {
            HStack(alignment: .top, spacing: 20) {
                TVAvatar(urlString: comment.userAvatarPath, name: comment.displayName ?? comment.username ?? "?", size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(comment.displayName ?? comment.username ?? "User").font(.callout.bold())
                        Text(DateFormatting.relative(comment.createdAt)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(comment.body).font(.callout)
                    if canReply {
                        Text("Select to reply").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

/// Full-screen still image, sized to the TV. GIFs show their first frame.
struct TVImageViewer: View {
    let media: MediaItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CachedAsyncImage(url: (media.url?.nilIfEmpty ?? media.previewUrl).flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: Image(systemName: "photo").font(.system(size: 80)).foregroundStyle(.secondary)
                default: ProgressView()
                }
            }
            .ignoresSafeArea()
        }
        .focusable()
        .onExitCommand { dismiss() }
    }
}
