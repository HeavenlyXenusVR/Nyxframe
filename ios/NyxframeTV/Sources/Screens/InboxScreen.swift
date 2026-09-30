import SwiftUI

/// Notifications, friend requests and conversations.
struct InboxScreen: View {
    enum Section: String, CaseIterable, Identifiable {
        case notifications = "Notifications"
        case messages = "Messages"
        case requests = "Friend Requests"
        var id: String { rawValue }
    }

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var unreadCounts: UnreadCountsService
    @State private var section: Section = .notifications

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .bottom) {
                    Text("Inbox").font(.system(size: 64, weight: .heavy))
                    Spacer()
                    HStack(spacing: 16) {
                        ForEach(Section.allCases) { option in
                            TVPill(title: title(for: option), isSelected: section == option) { section = option }
                        }
                    }
                }
                .focusSection()

                if session.currentUser == nil {
                    TVSignInPrompt(reason: "Notifications, messages and friend requests live here once you're signed in.")
                } else {
                    switch section {
                    case .notifications: NotificationsList()
                    case .messages: ConversationsList()
                    case .requests: FriendRequestsList()
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvScreenBackground()
    }

    private func title(for option: Section) -> String {
        switch option {
        case .notifications: return unreadCounts.notifications > 0 ? "Notifications (\(unreadCounts.notifications))" : "Notifications"
        case .messages: return unreadCounts.messages > 0 ? "Messages (\(unreadCounts.messages))" : "Messages"
        case .requests: return "Friend Requests"
        }
    }
}

// MARK: - Notifications

private struct NotificationsList: View {
    @EnvironmentObject private var navigator: TVNavigator
    @EnvironmentObject private var unreadCounts: UnreadCountsService
    @StateObject private var viewModel = NotificationsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.unreadCount > 0 {
                Button {
                    Task {
                        await viewModel.markAllRead()
                        await unreadCounts.refresh()
                    }
                } label: {
                    Label("Mark all as read", systemImage: "checkmark.circle")
                }
            }
            if viewModel.isLoading && viewModel.items.isEmpty {
                TVLoadingView()
            } else if viewModel.items.isEmpty {
                TVMessageView(systemImage: "bell", title: "You're all caught up", message: viewModel.errorMessage)
            }
            ForEach(viewModel.items) { item in
                Button {
                    Task {
                        await viewModel.markRead(item)
                        await unreadCounts.refresh()
                    }
                    open(item)
                } label: {
                    HStack(spacing: 24) {
                        TVAvatar(urlString: item.actorAvatarUrl, name: item.actorDisplayName ?? item.actorUsername ?? "N", size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.text(for: item)).font(.callout.weight(item.readAt == nil ? .bold : .regular))
                            Text(DateFormatting.relative(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if item.readAt == nil {
                            Circle().fill(TVTheme.accent).frame(width: 14, height: 14)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .focusSection()
        .task { await viewModel.load() }
    }

    private func open(_ item: NotificationItem) {
        switch item.kind {
        case "follow", "friend_accept":
            if let username = item.actorUsername { navigator.push(.user(username)) }
        case "message":
            if let actorId = item.actorId {
                navigator.push(.directMessages(userId: actorId, name: item.actorDisplayName ?? item.actorUsername ?? "Conversation"))
            }
        case "friend_request":
            break
        default:
            if let mediaId = item.mediaId { navigator.push(.media(id: mediaId, siblings: [mediaId])) }
        }
    }
}

// MARK: - Conversations

private struct ConversationsList: View {
    @EnvironmentObject private var navigator: TVNavigator
    @StateObject private var viewModel = MessagesListViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.isLoading && viewModel.directThreads.isEmpty && viewModel.groupThreads.isEmpty {
                TVLoadingView()
            } else if viewModel.directThreads.isEmpty && viewModel.groupThreads.isEmpty {
                TVMessageView(systemImage: "message", title: "No conversations yet",
                              message: viewModel.errorMessage ?? "Open someone's profile and choose Message to start one.")
            }
            ForEach(viewModel.groupThreads) { thread in
                let name = thread.displayName ?? thread.name ?? "Group"
                Button {
                    navigator.push(.groupThread(id: thread.id, name: name))
                } label: {
                    row(avatar: nil, name: name, preview: thread.lastMessage ?? "\(thread.members?.count ?? 0) members", when: thread.lastMessageAt, unread: 0, group: true)
                }
            }
            ForEach(viewModel.directThreads) { thread in
                let name = thread.displayName ?? thread.username ?? "Conversation"
                Button {
                    navigator.push(.directMessages(userId: thread.userId ?? thread.id, name: name))
                } label: {
                    row(avatar: thread.avatarUrl, name: name, preview: thread.lastMessage ?? "", when: thread.lastMessageAt, unread: thread.unreadCount ?? 0, group: false)
                }
            }
        }
        .focusSection()
        .task { await viewModel.load() }
    }

    private func row(avatar: String?, name: String, preview: String, when: String?, unread: Int, group: Bool) -> some View {
        HStack(spacing: 24) {
            if group {
                Image(systemName: "person.3.fill").font(.title3).frame(width: 64, height: 64).background(TVTheme.accent.opacity(0.3), in: Circle())
            } else {
                TVAvatar(urlString: avatar, name: name, size: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.callout.bold())
                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if unread > 0 {
                Text("\(unread)").font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 4).background(TVTheme.accent, in: Capsule())
            }
            Text(DateFormatting.relative(when)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Friend requests

private struct FriendRequestsList: View {
    @StateObject private var viewModel = FriendRequestsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if viewModel.isLoading && viewModel.incoming.isEmpty && viewModel.outgoing.isEmpty {
                TVLoadingView()
            } else if viewModel.incoming.isEmpty && viewModel.outgoing.isEmpty {
                TVMessageView(systemImage: "person.2", title: "No pending friend requests", message: viewModel.errorMessage)
            }
            if !viewModel.incoming.isEmpty {
                Text("Received").font(.title3.bold())
                ForEach(viewModel.incoming) { request in
                    HStack(spacing: 24) {
                        personLabel(request.user)
                        Spacer()
                        Button("Accept") { Task { await viewModel.respond(request, action: "accept") } }
                            .disabled(viewModel.busyId == request.id)
                        Button("Decline") { Task { await viewModel.respond(request, action: "decline") } }
                            .disabled(viewModel.busyId == request.id)
                    }
                    .focusSection()
                }
            }
            if !viewModel.outgoing.isEmpty {
                Text("Sent").font(.title3.bold())
                ForEach(viewModel.outgoing) { request in
                    HStack(spacing: 24) {
                        personLabel(request.user)
                        Spacer()
                        Button("Cancel Request") { Task { await viewModel.respond(request, action: "cancel") } }
                            .disabled(viewModel.busyId == request.id)
                    }
                    .focusSection()
                }
            }
        }
        .task { await viewModel.load() }
    }

    private func personLabel(_ user: GalleryUser?) -> some View {
        HStack(spacing: 20) {
            TVAvatar(urlString: user?.avatarUrl, name: user?.displayName ?? user?.username ?? "?", size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(user?.displayName ?? user?.username ?? "Someone").font(.callout.bold())
                if let username = user?.username { Text("@\(username)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Threads

/// One direct-message conversation, refreshed every few seconds while open.
struct DirectMessageScreen: View {
    let userId: Int
    let name: String
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel: DirectMessageThreadViewModel

    init(userId: Int, name: String) {
        self.userId = userId
        self.name = name
        _viewModel = StateObject(wrappedValue: DirectMessageThreadViewModel(userId: userId))
    }

    var body: some View {
        TVChatView(
            title: name,
            messages: viewModel.messages.map { TVChatLine(id: $0.id, body: $0.body, mine: $0.senderId == session.currentUser?.id, author: nil, createdAt: $0.createdAt) },
            isLoading: viewModel.isLoading,
            isSending: viewModel.isSending,
            errorMessage: viewModel.errorMessage,
            onSend: { await viewModel.send($0) },
            onRefresh: { await viewModel.refreshSilently() }
        )
        .task { await viewModel.load() }
    }
}

struct GroupThreadScreen: View {
    let threadId: Int
    let name: String
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel: GroupThreadViewModel

    init(threadId: Int, name: String) {
        self.threadId = threadId
        self.name = name
        _viewModel = StateObject(wrappedValue: GroupThreadViewModel(threadId: threadId))
    }

    var body: some View {
        TVChatView(
            title: name,
            messages: viewModel.messages.map {
                TVChatLine(id: $0.id, body: $0.body, mine: $0.senderId == session.currentUser?.id,
                           author: $0.displayName ?? $0.username, createdAt: $0.createdAt)
            },
            isLoading: viewModel.isLoading,
            isSending: viewModel.isSending,
            errorMessage: viewModel.errorMessage,
            onSend: { await viewModel.send($0) },
            onRefresh: { await viewModel.refreshSilently() }
        )
        .task { await viewModel.load() }
    }
}

struct TVChatLine: Identifiable {
    let id: Int
    let body: String
    let mine: Bool
    let author: String?
    let createdAt: String?
}

private struct TVChatView: View {
    let title: String
    let messages: [TVChatLine]
    let isLoading: Bool
    let isSending: Bool
    let errorMessage: String?
    let onSend: (String) async -> Bool
    let onRefresh: () async -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(.system(size: 52, weight: .heavy))
            HStack(spacing: 20) {
                TextField("Write a message", text: $draft)
                    .onSubmit(send)
                Button {
                    send()
                } label: {
                    Label(isSending ? "Sending…" : "Send", systemImage: "paperplane.fill")
                }
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .focusSection()
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if isLoading && messages.isEmpty { TVLoadingView() }
                        ForEach(messages) { line in
                            HStack {
                                if line.mine { Spacer(minLength: 300) }
                                // Focusable so the remote can scroll back
                                // through a long conversation.
                                Button {} label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let author = line.author, !line.mine {
                                            Text(author).font(.caption.bold()).foregroundStyle(TVTheme.accent)
                                        }
                                        Text(line.body).font(.callout)
                                        Text(DateFormatting.chatTimestamp(line.createdAt)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                                    .background(line.mine ? TVTheme.accent.opacity(0.35) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                                }
                                .buttonStyle(.plain)
                                if !line.mine { Spacer(minLength: 300) }
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.last?.id) { _, last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                .onAppear {
                    if let last = messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 40)
        .tvScreenBackground()
        .task {
            // Poll for new messages while the conversation is open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { break }
                await onRefresh()
            }
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending else { return }
        Task {
            if await onSend(text) { draft = "" }
        }
    }
}
