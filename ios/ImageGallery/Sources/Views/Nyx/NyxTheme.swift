import SwiftUI
import UIKit

/// "Nocturne" -- the app's visual language, named for the goddess the
/// product is named after. Night is the default mood: a deep indigo sky
/// with a faint violet glow and a scattering of stars in dark mode, and a
/// pale "dawn" lavender in light mode. The viewer's own accent color
/// (`user_settings.accent_color`, applied via `.tint` at the root) stays
/// the one saturated color on screen, so personalization still reads
/// first.
///
/// iOS-only on purpose: lives under Views/ (not Utils/, which the tvOS
/// target also compiles), since the TV app has its own focus-driven look.
enum Nyx {
    // MARK: Palette

    /// Base of the backdrop gradient (top).
    static let skyTop = dynamic(light: 0xF7F5FC, dark: 0x0A0A18)
    /// Base of the backdrop gradient (bottom).
    static let skyBottom = dynamic(light: 0xECE8F7, dark: 0x15132E)
    /// The soft glow behind headers -- moonlight in dark mode, a faint
    /// sunrise in light mode.
    static let glow = dynamic(light: 0xD9CCF5, dark: 0x3B2C7A)
    /// Secondary glow, offset from `glow` so the backdrop never reads as a
    /// flat two-stop gradient.
    static let glowAlt = dynamic(light: 0xC8E9F0, dark: 0x163A55)
    /// Raised surface tint layered under the glass material.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1A38, lightAlpha: 0.72, darkAlpha: 0.66)
    /// Hairline used on every glass edge.
    static let hairline = dynamic(light: 0x1B1640, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
    /// Muted text that still holds contrast on the backdrop.
    static let mist = dynamic(light: 0x5F5A7A, dark: 0xA9A5C9)
    /// Stars -- only drawn in dark mode, but defined for both so callers
    /// don't need to branch.
    static let star = dynamic(light: 0x8E86B8, dark: 0xF4F1FF)

    // MARK: Shape

    enum Radius {
        static let chip: CGFloat = 14
        static let card: CGFloat = 22
        static let panel: CGFloat = 28
        static let hero: CGFloat = 32
    }

    // MARK: Type

    /// Display type for screen headers -- rounded and heavy so the large
    /// titles feel like the app's own rather than stock UIKit.
    static func display(_ size: CGFloat = 32) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    /// Small all-caps eyebrow labels above headers ("TONIGHT", "YOUR VAULT").
    static let eyebrow: Font = .system(size: 11, weight: .bold, design: .rounded)

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let value = isDark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

// MARK: - Environment

/// Account-level appearance values the Nocturne components read. Passed as
/// plain environment values (set once in `RootView`) rather than reading
/// `SessionStore` as an environment object, because environment values
/// reliably reach sheets and full-screen covers too, and a missing
/// environment object there would crash instead of falling back.
private struct NyxBackdropHexKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct NyxReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `gallery_bg_color`, when the viewer set one.
    var nyxBackdropHex: String? {
        get { self[NyxBackdropHexKey.self] }
        set { self[NyxBackdropHexKey.self] = newValue }
    }

    /// `reduce_motion` from the account settings (the system setting is
    /// read separately via `accessibilityReduceMotion`).
    var nyxReduceMotion: Bool {
        get { self[NyxReduceMotionKey.self] }
        set { self[NyxReduceMotionKey.self] = newValue }
    }
}

// MARK: - Backdrop

/// The sky every Nocturne screen sits on. Honors `gallery_bg_color` when
/// the viewer set one (same override the web app applies to `--bg`),
/// otherwise draws the gradient + glows + (dark mode only) stars.
struct NyxBackdrop: View {
    var showsStars = true

    @Environment(\.nyxBackdropHex) private var backdropHex
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let hex = backdropHex, !hex.isEmpty {
            Color(hex: hex)
        } else {
            ZStack {
                LinearGradient(colors: [Nyx.skyTop, Nyx.skyBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Nyx.glow.opacity(0.55), .clear], center: UnitPoint(x: 0.12, y: -0.05), startRadius: 10, endRadius: 420)
                RadialGradient(colors: [Nyx.glowAlt.opacity(0.35), .clear], center: UnitPoint(x: 1.05, y: 0.32), startRadius: 10, endRadius: 360)
                if showsStars && colorScheme == .dark {
                    StarfieldView()
                }
            }
        }
    }
}

/// A sparse, slowly twinkling starfield. Positions are seeded so the sky
/// is the same every launch (a constellation you start to recognise, not
/// noise), and the twinkle stops entirely under Reduce Motion -- either
/// the system setting or the account's own `reduce_motion`.
struct StarfieldView: View {
    var density = 70

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.nyxReduceMotion) private var accountReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || accountReduceMotion }

    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let phase: Double
    }

    private var stars: [Star] {
        var generator = SeededGenerator(seed: 0x6E79_7866)
        return (0..<density).map { _ in
            Star(
                x: CGFloat.random(in: 0...1, using: &generator),
                y: CGFloat.random(in: 0...1, using: &generator),
                size: CGFloat.random(in: 0.6...1.9, using: &generator),
                phase: Double.random(in: 0...(2 * .pi), using: &generator)
            )
        }
    }

    var body: some View {
        let field = stars
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                for star in field {
                    let twinkle = 0.55 + 0.45 * sin(time * 0.8 + star.phase)
                    let rect = CGRect(x: star.x * size.width, y: star.y * size.height, width: star.size, height: star.size)
                    canvas.fill(Path(ellipseIn: rect), with: .color(Nyx.star.opacity(twinkle * 0.8)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Deterministic RNG for the starfield (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Moon phase

/// Tonight's actual moon phase, used as the Explore header's glyph -- a
/// small detail that makes the app feel like it knows what time it is.
/// Synodic-month arithmetic from a known new moon; accurate to within a
/// day, which is all an eight-step glyph needs.
enum MoonPhase {
    static func current(_ date: Date = Date()) -> (symbol: String, name: String) {
        let synodicMonth = 29.530588853
        let knownNewMoon = Date(timeIntervalSince1970: 947_182_440) // 2000-01-06 18:14 UTC
        let days = date.timeIntervalSince(knownNewMoon) / 86_400
        let age = days.truncatingRemainder(dividingBy: synodicMonth)
        let normalized = (age < 0 ? age + synodicMonth : age) / synodicMonth
        let index = Int((normalized * 8).rounded()) % 8
        let phases: [(String, String)] = [
            ("moonphase.new.moon", "New moon"),
            ("moonphase.waxing.crescent", "Waxing crescent"),
            ("moonphase.first.quarter", "First quarter"),
            ("moonphase.waxing.gibbous", "Waxing gibbous"),
            ("moonphase.full.moon", "Full moon"),
            ("moonphase.waning.gibbous", "Waning gibbous"),
            ("moonphase.last.quarter", "Last quarter"),
            ("moonphase.waning.crescent", "Waning crescent"),
        ]
        return phases[index]
    }
}

// MARK: - Surfaces

private struct NyxGlass: ViewModifier {
    var radius: CGFloat
    var elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Nyx.surface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Nyx.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(elevated ? 0.22 : 0), radius: 18, x: 0, y: 10)
    }
}

private struct NyxScreen: ViewModifier {
    var showsStars: Bool

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(NyxBackdrop(showsStars: showsStars).ignoresSafeArea())
    }
}

extension View {
    /// A Nocturne glass panel: material + tinted surface + hairline edge.
    func nyxGlass(radius: CGFloat = Nyx.Radius.card, elevated: Bool = false) -> some View {
        modifier(NyxGlass(radius: radius, elevated: elevated))
    }

    /// Puts a screen on the Nocturne sky. Also hides List/Form's own opaque
    /// grouped background (`scrollContentBackground`, iOS 16+), which closes
    /// the gap the root view's comment describes: list screens used to
    /// paint over any app-wide background.
    func nyxScreen(stars: Bool = false) -> some View {
        modifier(NyxScreen(showsStars: stars))
    }
}

// MARK: - Components

/// "TONIGHT" eyebrow + large rounded title, with an optional trailing
/// accessory (a "See all" link, a count).
struct NyxSectionHeader<Accessory: View>: View {
    let eyebrow: String?
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(Nyx.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(Color.accentColor)
                }
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 20)
    }
}

extension NyxSectionHeader where Accessory == EmptyView {
    init(eyebrow: String? = nil, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

/// Selectable pill used across filter shelves.
struct NyxChip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                Text(title).lineLimit(1)
            }
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().strokeBorder(Nyx.hairline, lineWidth: 1))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(NyxPressStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }
}

/// Gentle press-down scale for tappable cards and chips.
struct NyxPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Full-width primary action, accent gradient with a soft glow.
struct NyxPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isEnabled
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.secondary.opacity(0.3)))
            )
            .foregroundStyle(.white)
            .shadow(color: Color.accentColor.opacity(isEnabled ? 0.35 : 0), radius: 14, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A small glass icon button for floating toolbars over media.
struct NyxOrbButton: View {
    let systemImage: String
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(NyxPressStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// Shared thumbnail renderer for the rails and hero cards, so locked /
/// failed / loading states look identical everywhere.
struct NyxThumbnail: View {
    let item: MediaItem
    var context: String = "rail"

    var body: some View {
        if item.locked == true {
            ZStack {
                LinearGradient(colors: [Nyx.glow, Nyx.glowAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "eye.slash.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
            }
        } else if let urlString = item.thumbUrl, let url = URL(string: urlString) {
            CachedAsyncImage(url: url, diagnostics: ImageLoadDiagnosticsContext(mediaId: item.id, mediaKind: item.mediaKind ?? "", context: context)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder(icon: "photo")
                default:
                    placeholder(icon: nil)
                }
            }
        } else {
            placeholder(icon: "photo")
        }
    }

    private func placeholder(icon: String?) -> some View {
        Rectangle()
            .fill(Nyx.glow.opacity(0.35))
            .overlay {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            }
    }
}
