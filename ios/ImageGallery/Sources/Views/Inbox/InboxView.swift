import SwiftUI

/// Notifications and messages in one place. Both answer the same
/// question -- "what happened while I was away?" -- and splitting them
/// across a tab and a toolbar bell (as before) meant checking two places
/// to answer it.
struct InboxView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case activity
        case messages

        var id: String { rawValue }
        var title: String { self == .activity ? "Activity" : "Messages" }
        var icon: String { self == .activity ? "bell" : "bubble.left.and.bubble.right" }
    }

    @Binding var segment: Segment
    @EnvironmentObject private var unreadCounts: UnreadCountsService
    @Namespace private var selectionNamespace

    var body: some View {
        Group {
            switch segment {
            case .activity: NotificationsView()
            case .messages: MessagesView()
            }
        }
        // An inset (not a VStack sibling) so the list stays the screen's
        // primary scroll view and the large title still collapses.
        .safeAreaInset(edge: .top, spacing: 0) { segmentBar }
        .navigationTitle("Inbox")
    }

    private var segmentBar: some View {
        HStack(spacing: 4) {
            ForEach(Segment.allCases) { value in
                let isSelected = segment == value
                let count = value == .activity ? unreadCounts.notifications : unreadCounts.messages
                Button {
                    Haptics.light()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { segment = value }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? value.icon + ".fill" : value.icon)
                        Text(value.title)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.pink, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(isSelected ? Color.primary : Nyx.mist)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Nyx.surface)
                                .overlay(Capsule().strokeBorder(Nyx.hairline, lineWidth: 1))
                                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
                                .matchedGeometryEffect(id: "segment", in: selectionNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
