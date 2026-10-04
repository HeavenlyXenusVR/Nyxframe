import SwiftUI

/// The floating navigation dock: a glass capsule with the four
/// destinations either side of a raised "create" orb. The selected
/// destination grows into a labelled pill (a matched-geometry highlight
/// slides between them), so the dock stays compact without hiding where
/// you are.
struct OrbitDock: View {
    let selection: AppTab
    let inboxBadge: Int
    let onSelect: (AppTab) -> Void
    let onCreate: () -> Void

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 4) {
            item(.explore)
            item(.library)
            createOrb
            item(.inbox)
            item(.you)
        }
        .padding(6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Nyx.surface))
        )
        .overlay(Capsule().strokeBorder(Nyx.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func item(_ tab: AppTab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { onSelect(tab) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        if tab == .inbox && inboxBadge > 0 {
                            Text(inboxBadge > 99 ? "99+" : "\(inboxBadge)")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.pink, in: Capsule())
                                .offset(x: 10, y: -8)
                        }
                    }
                if isSelected {
                    Text(tab.title)
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, isSelected ? 14 : 10)
            .frame(height: 46)
            .frame(maxWidth: isSelected ? nil : .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.16))
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(NyxPressStyle(scale: 0.92))
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab == .inbox && inboxBadge > 0 ? "\(inboxBadge) unread" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var createOrb: some View {
        Button {
            Haptics.medium()
            onCreate()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    Circle().fill(
                        AngularGradient(
                            colors: [Color.accentColor, Color.purple, Color.indigo, Color.accentColor],
                            center: .center
                        )
                    )
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: Color.accentColor.opacity(0.5), radius: 12, x: 0, y: 4)
        }
        .buttonStyle(NyxPressStyle(scale: 0.88))
        .padding(.horizontal, 4)
        .accessibilityLabel("Create a post")
    }
}
