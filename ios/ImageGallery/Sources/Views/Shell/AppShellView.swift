import Combine
import SwiftUI
import UIKit

/// The four places the dock can take you. Creating isn't one of them --
/// it's an action, so the dock's center orb opens it as a sheet over
/// whatever you were looking at instead of making it a destination you
/// have to leave.
enum AppTab: String, CaseIterable, Identifiable {
    case explore
    case library
    case inbox
    case you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: return "Explore"
        case .library: return "Library"
        case .inbox: return "Inbox"
        case .you: return "You"
        }
    }

    var icon: String {
        switch self {
        case .explore: return "sparkles"
        case .library: return "books.vertical"
        case .inbox: return "tray"
        case .you: return "person.crop.circle"
        }
    }

    var selectedIcon: String {
        switch self {
        case .explore: return "sparkles"
        case .library: return "books.vertical.fill"
        case .inbox: return "tray.fill"
        case .you: return "person.crop.circle.fill"
        }
    }
}

/// The signed-in app. Replaces the old five-tab `TabView`
/// (Discover/Messages/Studio/Upload/Profile) with four destinations and a
/// floating dock:
///
/// - **Explore** -- the feed, with search, trending and "on this day".
/// - **Library** -- everything you've kept: collections, likes, follows,
///   trending and categories.
/// - **Inbox** -- notifications and messages together, since both answer
///   "what happened while I was away".
/// - **You** -- your profile, Studio, friend requests and settings.
///
/// Each destination keeps its own `NavigationStack`, built the first time
/// it's visited and kept alive afterwards (so switching back preserves
/// scroll position and pushed screens, the way a `TabView` did). Using a
/// custom container rather than `TabView` with a hidden bar is what lets
/// the dock float, hide on immersive screens, and step aside for the
/// keyboard.
struct AppShellView: View {
    @EnvironmentObject private var quickActionRouter: QuickActionRouter
    @EnvironmentObject private var unreadCounts: UnreadCountsService

    @StateObject private var dock = DockController()
    @State private var selection: AppTab = .explore
    @State private var mounted: Set<AppTab> = [.explore]
    /// Bumped when the already-selected tab is tapped again, which
    /// rebuilds that tab's stack -- back to its root, scrolled to the top.
    @State private var stackIds: [AppTab: UUID] = [:]
    @State private var inboxSegment: InboxView.Segment = .activity
    @State private var showingCreate = false
    @State private var keyboardVisible = false

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases) { tab in
                if mounted.contains(tab) {
                    NavigationStack {
                        root(for: tab)
                    }
                    .id(stackIds[tab])
                    .environment(\.dockTab, tab)
                    .environment(\.nyxTabIsActive, selection == tab)
                    .opacity(selection == tab ? 1 : 0)
                    .allowsHitTesting(selection == tab)
                    .accessibilityHidden(selection != tab)
                }
            }
        }
        .environment(\.dockController, dock)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsDock {
                OrbitDock(
                    selection: selection,
                    inboxBadge: unreadCounts.notifications + unreadCounts.messages,
                    onSelect: select,
                    onCreate: { showingCreate = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showsDock)
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                UploadView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingCreate = false }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: quickActionRouter.pendingDestination) { destination in
            guard let destination else { return }
            route(to: destination)
            quickActionRouter.pendingDestination = nil
        }
        .onAppear {
            // A quick action that launched the app cold lands here before
            // onChange can observe it.
            if let destination = quickActionRouter.pendingDestination {
                route(to: destination)
                quickActionRouter.pendingDestination = nil
            }
        }
    }

    private var showsDock: Bool {
        !keyboardVisible && !dock.isHidden(in: selection)
    }

    @ViewBuilder
    private func root(for tab: AppTab) -> some View {
        switch tab {
        case .explore: FeedView()
        case .library: LibraryView()
        case .inbox: InboxView(segment: $inboxSegment)
        case .you: YouView()
        }
    }

    private func select(_ tab: AppTab) {
        Haptics.light()
        if tab == selection {
            stackIds[tab] = UUID()
        } else {
            mounted.insert(tab)
            selection = tab
        }
    }

    private func route(to destination: QuickActionRouter.Destination) {
        switch destination {
        case .discover:
            mounted.insert(.explore)
            selection = .explore
        case .messages:
            inboxSegment = .messages
            mounted.insert(.inbox)
            selection = .inbox
        case .activity:
            inboxSegment = .activity
            mounted.insert(.inbox)
            selection = .inbox
        case .you:
            mounted.insert(.you)
            selection = .you
        case .upload:
            showingCreate = true
        }
    }
}

// MARK: - Dock visibility

/// Tracks which on-screen views have asked for the dock to step aside
/// (media detail, chat threads), per tab, so a hidden-dock screen left
/// open in one tab doesn't hide the dock in another.
@MainActor
final class DockController: ObservableObject {
    @Published private var requests: [AppTab: Set<UUID>] = [:]

    func isHidden(in tab: AppTab) -> Bool {
        !(requests[tab]?.isEmpty ?? true)
    }

    func hide(_ token: UUID, in tab: AppTab) {
        requests[tab, default: []].insert(token)
    }

    func release(_ token: UUID, in tab: AppTab) {
        requests[tab]?.remove(token)
    }
}

private struct DockControllerKey: EnvironmentKey {
    static let defaultValue: DockController? = nil
}

private struct DockTabKey: EnvironmentKey {
    static let defaultValue: AppTab = .explore
}

private struct TabIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var dockController: DockController? {
        get { self[DockControllerKey.self] }
        set { self[DockControllerKey.self] = newValue }
    }

    var dockTab: AppTab {
        get { self[DockTabKey.self] }
        set { self[DockTabKey.self] = newValue }
    }

    /// False while this view's tab is kept alive in the background. Views
    /// that play media read it to pause, since a background tab's views
    /// never get `onDisappear`.
    var nyxTabIsActive: Bool {
        get { self[TabIsActiveKey.self] }
        set { self[TabIsActiveKey.self] = newValue }
    }
}

private struct HidesDock: ViewModifier {
    @Environment(\.dockController) private var dock
    @Environment(\.dockTab) private var tab
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { dock?.hide(token, in: tab) }
            .onDisappear { dock?.release(token, in: tab) }
    }
}

extension View {
    /// Hides the floating dock while this view is on screen. A no-op
    /// outside the shell (sheets, previews).
    func hidesDock() -> some View {
        modifier(HidesDock())
    }
}
