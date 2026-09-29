import UIKit

/// Thin wrapper around UIKit's feedback generators — a native touch the web
/// app has no equivalent for. Kept to a handful of call sites (like, react,
/// follow, send, success/failure) rather than sprinkled everywhere, so it
/// stays meaningful instead of buzzy.
///
/// tvOS has no haptic hardware (and no feedback generators), so every
/// call there is a no-op -- which lets the shared view models keep
/// calling these unconditionally on both platforms.
enum Haptics {
    static func light() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func medium() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func error() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}
