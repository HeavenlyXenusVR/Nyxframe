import SwiftUI

/// Avatar+name navigable card for the post's creator.
/// `media.userAvatarUrl` is already a full URL (populated by the backend's
/// `_with_urls` on the media detail response), unlike a comment's
/// `userAvatarPath` — no client-side reconstruction needed here.
struct UploaderRow: View {
    let media: MediaItem

    var body: some View {
        if let username = media.username {
            NavigationLink(destination: ProfileView(username: username)) {
                HStack(spacing: 12) {
                    AvatarView(urlString: media.userAvatarUrl, fallbackInitial: String((media.displayName ?? username).prefix(1)), size: 42)
                        .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5).padding(-3))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.displayName ?? username)
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                        Text("@\(username)").font(.caption).foregroundStyle(Nyx.mist)
                    }
                    Spacer()
                    Text("View")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(NyxPressStyle(scale: 0.98))
            .accessibilityLabel("Uploaded by \(media.displayName ?? username)")
        }
    }
}
