import SwiftUI

struct MessagesView: View {
    @StateObject private var viewModel = MessagesListViewModel()
    @State private var showingDirect = true
    @State private var showingNewGroup = false
    @State private var newlyCreatedThread: GroupThread?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                NyxChip(title: "Direct", systemImage: "person", isSelected: showingDirect) { showingDirect = true }
                NyxChip(title: "Groups", systemImage: "person.3", isSelected: !showingDirect) { showingDirect = false }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List {
                jumpToNewThreadLink
                if viewModel.isLoading && viewModel.directThreads.isEmpty && viewModel.groupThreads.isEmpty {
                    SkeletonRowList()
                } else {
                    threadRows
                }
            }
            .listStyle(.plain)
        }
        .nyxScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewGroup = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New group chat")
            }
        }
        .sheet(isPresented: $showingNewGroup) {
            NewGroupThreadView { thread in
                newlyCreatedThread = thread
                showingDirect = false
                Task { await viewModel.load() }
            }
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
    }

    /// Hidden programmatic-navigation link for "just created a group, jump
    /// straight into it" — `navigationDestination(item:)` is iOS 17+ only, so
    /// this uses the older (iOS 13+, still functional) isActive-based
    /// initializer to stay on iOS 16. Split out of `body` to keep each
    /// individual view's expression simple for the type-checker (see the
    /// CollectionsListView fix for why that matters).
    private var jumpToNewThreadLink: some View {
        NavigationLink(
            destination: Group {
                if let thread = newlyCreatedThread {
                    GroupThreadView(threadId: thread.id, title: thread.displayName ?? thread.name ?? "Group")
                }
            },
            isActive: Binding(
                get: { newlyCreatedThread != nil },
                set: { active in if !active { newlyCreatedThread = nil } }
            )
        ) { EmptyView() }
            .hidden()
    }

    @ViewBuilder
    private var threadRows: some View {
        if showingDirect {
            ForEach(viewModel.directThreads) { thread in
                NavigationLink(destination: DirectMessageThreadView(userId: thread.userId ?? thread.id, displayName: thread.displayName ?? thread.username ?? "User")) {
                    DirectThreadRow(thread: thread)
                }
            }
            if viewModel.directThreads.isEmpty && !viewModel.isLoading {
                EmptyMessagesState(text: "No conversations yet — start one from a profile.")
            }
        } else {
            ForEach(viewModel.groupThreads) { thread in
                NavigationLink(destination: GroupThreadView(threadId: thread.id, title: thread.displayName ?? thread.name ?? "Group")) {
                    GroupThreadRow(thread: thread)
                }
            }
            if viewModel.groupThreads.isEmpty && !viewModel.isLoading {
                EmptyMessagesState(text: "No group chats yet.")
            }
        }
    }
}

private struct DirectThreadRow: View {
    let thread: MessageThread

    var body: some View {
        HStack {
            AvatarView(urlString: thread.avatarUrl, fallbackInitial: String((thread.username ?? "?").prefix(1)), size: 48)
                .overlay {
                    if let unread = thread.unreadCount, unread > 0 {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayName ?? thread.username ?? "User")
                    .font(.system(.body, design: .rounded).weight(.bold))
                if let lastMessage = thread.lastMessage {
                    Text(lastMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if thread.lastMessageAt != nil {
                    Text(DateFormatting.relative(thread.lastMessageAt)).font(.caption2).foregroundStyle(.secondary)
                }
                if let unread = thread.unreadCount, unread > 0 {
                    Text("\(unread)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

private struct GroupThreadRow: View {
    let thread: GroupThread

    var body: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(colors: [Color.accentColor, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayName ?? thread.name ?? "Group")
                    .font(.system(.body, design: .rounded).weight(.bold))
                if let lastMessage = thread.lastMessage {
                    Text(lastMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if thread.lastMessageAt != nil {
                Text(DateFormatting.relative(thread.lastMessageAt)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyMessagesState: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            ContentUnavailableCompat(title: "Quiet night", systemImage: "bubble.left.and.bubble.right", hint: text)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
