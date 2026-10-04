import SwiftUI

/// `ContentUnavailableView` is iOS 17+; this app's deployment target is iOS 16,
/// so a tiny compatibility shim covers the empty-state look on iOS 16 devices.
/// `hint` and `action` were added for the same reason the web app's
/// EmptyState grew them: an empty screen that only states the fact is a
/// dead end, and the most common causes here (a filter, the shortest
/// trending window, an account with nothing in it yet) all have an
/// obvious next step the viewer can't otherwise find.
///
/// Nocturne treatment: the glyph sits in a soft accent halo, like a moon
/// in haze, so empty states read as part of the sky rather than an error.
struct ContentUnavailableCompat<Action: View>: View {
    let title: String
    let systemImage: String
    var hint: String? = nil
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear], center: .center, startRadius: 2, endRadius: 48))
                    .frame(width: 96, height: 96)
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.system(.headline, design: .rounded))
                .multilineTextAlignment(.center)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Nyx.mist)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            action()
                .padding(.top, 4)
        }
    }
}

/// The common case: a bare empty state with nothing to offer. Keeps
/// every existing call site working unchanged, and makes `action` an
/// `EmptyView`, which contributes no layout to the stack above.
extension ContentUnavailableCompat where Action == EmptyView {
    init(title: String, systemImage: String, hint: String? = nil) {
        self.init(title: title, systemImage: systemImage, hint: hint) { EmptyView() }
    }
}
