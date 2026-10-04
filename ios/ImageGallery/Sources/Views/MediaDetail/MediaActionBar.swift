import SwiftUI

/// A row of equal-width action tiles (like, save, share, more), with
/// view/download/file-size counts demoted to a lighter caption line
/// underneath (comment count stays visible via the Comments section
/// header below, so isn't duplicated here).
struct MediaActionBar: View {
    let media: MediaItem
    let isTogglingLike: Bool
    let isTogglingBookmark: Bool
    let onLike: () -> Void
    let onBookmark: () -> Void
    let onReport: () -> Void
    let onOpenOriginal: () -> Void

    @State private var likeBounce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                actionTile(
                    icon: media.likedByMe == true ? "heart.fill" : "heart",
                    caption: (media.likeCount ?? 0) > 0 ? "\(media.likeCount ?? 0)" : "Like",
                    active: media.likedByMe == true,
                    activeTint: .pink,
                    action: onLike
                )
                .scaleEffect(likeBounce ? 1.12 : 1.0)
                .disabled(isTogglingLike)
                .accessibilityLabel(media.likedByMe == true ? "Unlike" : "Like")

                actionTile(
                    icon: media.bookmarkedByMe == true ? "bookmark.fill" : "bookmark",
                    caption: media.bookmarkedByMe == true ? "Saved" : "Save",
                    active: media.bookmarkedByMe == true,
                    activeTint: Color.accentColor,
                    action: onBookmark
                )
                .disabled(isTogglingBookmark)

                if let downloadUrl = media.downloadUrl, let url = URL(string: downloadUrl) {
                    ShareLink(item: url) {
                        tileLabel(icon: "square.and.arrow.up", caption: "Share", active: false, activeTint: .accentColor)
                    }
                    .buttonStyle(NyxPressStyle())
                }

                Menu {
                    Button {
                        onOpenOriginal()
                    } label: {
                        Label("Open Original", systemImage: "arrow.up.forward.square")
                    }
                    Button(role: .destructive, action: onReport) {
                        Label("Report", systemImage: "flag")
                    }
                } label: {
                    tileLabel(icon: "ellipsis", caption: "More", active: false, activeTint: .accentColor)
                }
                .accessibilityLabel("More options")
            }

            HStack(spacing: 14) {
                Label("\(media.views ?? 0)", systemImage: "eye")
                Label("\(media.downloads ?? 0)", systemImage: "arrow.down.circle")
                if let fileSize = media.fileSize {
                    Label(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file), systemImage: "internaldrive")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Nyx.mist)
        }
        .onChange(of: media.likedByMe) { _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.4)) { likeBounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { likeBounce = false }
            }
        }
    }

    private func actionTile(icon: String, caption: String, active: Bool, activeTint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tileLabel(icon: icon, caption: caption, active: active, activeTint: activeTint)
        }
        .buttonStyle(NyxPressStyle())
    }

    private func tileLabel(icon: String, caption: String, active: Bool, activeTint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            Text(caption)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(active ? activeTint.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(active ? activeTint.opacity(0.5) : Nyx.hairline, lineWidth: 1)
        )
        .foregroundStyle(active ? activeTint : Color.primary)
    }
}
