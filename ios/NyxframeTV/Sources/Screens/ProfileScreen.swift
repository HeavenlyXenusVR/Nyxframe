import SwiftUI

/// A creator's public profile: identity, stats, social actions, their
/// posts, collections and friends.
struct ProfileScreen: View {
    let username: String
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var navigator: TVNavigator
    @StateObject private var viewModel: ProfileViewModel
    @State private var confirmingBlock = false

    init(username: String) {
        self.username = username
        _viewModel = StateObject(wrappedValue: ProfileViewModel(username: username))
    }

    var body: some View {
        Group {
            if let user = viewModel.user {
                content(user)
            } else if viewModel.isLoading || viewModel.errorMessage == nil {
                TVLoadingView()
            } else {
                TVMessageView(systemImage: "person.crop.circle.badge.exclamationmark", title: "Couldn't load @\(username)", message: viewModel.errorMessage) {
                    Task { await viewModel.load() }
                }
            }
        }
        .tvScreenBackground()
        .task { await viewModel.load() }
        .confirmationDialog("Block @\(username)?", isPresented: $confirmingBlock) {
            Button("Mute") { Task { await viewModel.setBlock(kind: "mute", active: true) } }
            Button("Block", role: .destructive) { Task { await viewModel.setBlock(kind: "block", active: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Muting hides their posts from your feeds. Blocking also stops them contacting you.")
        }
    }

    private func content(_ user: GalleryUser) -> some View {
        let isSelf = session.currentUser?.id == user.id
        let accent = Color(hex: user.profileColor ?? Appearance.defaultAccentHex)
        return ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                HStack(alignment: .center, spacing: 48) {
                    TVAvatar(urlString: user.avatarUrl, name: user.displayName ?? user.username, size: 220)
                        .overlay(Circle().stroke(accent, lineWidth: 6))
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            Text(user.displayName?.nilIfEmpty ?? user.username).font(.system(size: 56, weight: .heavy))
                            if user.discordVerifiedAt != nil {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(accent).font(.title2)
                            }
                        }
                        Text("@\(user.username)" + (user.profileHeadline?.nilIfEmpty.map { " · \($0)" } ?? ""))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Circle().fill(user.isOnline == true ? Color.green : Color.gray).frame(width: 14, height: 14)
                            Text(user.isOnline == true ? "Online" : "Inactive").font(.caption).foregroundStyle(.secondary)
                            if let joined = DateFormatting.joined(user.createdAt) {
                                Text("· Joined \(joined)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let bio = user.bio?.nilIfEmpty {
                            Text(bio).font(.callout).lineLimit(4)
                        }
                        HStack(spacing: 36) {
                            stat("Posts", user.mediaCount ?? viewModel.media.count)
                            stat("Followers", user.followerCount ?? 0)
                            stat("Following", user.followingCount ?? 0)
                            stat("Friends", user.friendCount ?? viewModel.friends.count)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !isSelf, session.currentUser != nil {
                    HStack(spacing: 24) {
                        Button {
                            Task { await viewModel.setFollowing(!(user.followedByMe ?? false)) }
                        } label: {
                            Label(user.followedByMe == true ? "Following" : "Follow", systemImage: user.followedByMe == true ? "checkmark" : "plus")
                        }
                        Button {
                            Task { await viewModel.sendFriendRequest() }
                        } label: {
                            Label(friendLabel(user.friendStatus), systemImage: "person.2")
                        }
                        .disabled(["friends", "pending_out", "self"].contains(user.friendStatus ?? ""))
                        Button {
                            navigator.push(.directMessages(userId: user.id, name: user.displayName ?? user.username))
                        } label: {
                            Label("Message", systemImage: "message")
                        }
                        Button(role: .destructive) {
                            confirmingBlock = true
                        } label: {
                            Label("Mute or Block", systemImage: "hand.raised")
                        }
                    }
                    .focusSection()
                }

                if viewModel.media.isEmpty {
                    Text("No public posts yet.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("Posts").font(.title3.bold())
                            Spacer()
                            let stills = viewModel.media.filter { !$0.isVideo && $0.locked != true }
                            if !stills.isEmpty {
                                Button {
                                    navigator.push(.slideshow(items: stills))
                                } label: {
                                    Label("Slideshow", systemImage: "play.rectangle.on.rectangle")
                                }
                            }
                        }
                        .focusSection()
                        TVMediaGrid(items: viewModel.media) { item, all in navigator.openMedia(item, in: all) }
                    }
                }

                if !viewModel.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Collections").font(.title3.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 32) {
                                ForEach(viewModel.collections) { collection in
                                    TVCollectionCard(collection: collection) { navigator.push(.collection(collection.id)) }
                                }
                            }
                            .padding(.vertical, 24)
                        }
                        .scrollClipDisabled()
                    }
                    .focusSection()
                }

                if !viewModel.friends.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Friends").font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 24)], alignment: .leading, spacing: 16) {
                            ForEach(viewModel.friends) { friend in
                                TVUserChip(username: friend.username, displayName: friend.displayName, avatarUrl: friend.avatarUrl)
                            }
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.compactString).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func friendLabel(_ status: String?) -> String {
        switch status {
        case "friends": return "Friends"
        case "pending_out": return "Request sent"
        case "pending_in": return "Accept request"
        default: return "Add friend"
        }
    }
}

struct TVCollectionCard: View {
    let collection: CollectionSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CachedAsyncImage(url: collection.coverUrl.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default:
                        ZStack {
                            TVTheme.accent.opacity(0.2)
                            Image(systemName: collection.isSmart == true ? "wand.and.stars" : "folder").font(.largeTitle)
                        }
                    }
                }
                .frame(width: 340, height: 191)
                .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name).font(.callout.bold()).lineLimit(1)
                    Text(collection.isSmart == true ? "Smart collection" : (collection.isPublic == false ? "Private" : "Collection"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
            }
        }
        .buttonStyle(.card)
    }
}
