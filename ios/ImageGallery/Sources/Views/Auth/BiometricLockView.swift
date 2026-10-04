import SwiftUI

struct BiometricLockView: View {
    @EnvironmentObject private var biometricLock: BiometricLockService

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.45), .clear], center: .center, startRadius: 4, endRadius: 80))
                    .frame(width: 160, height: 160)
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.white, Color.accentColor], startPoint: .top, endPoint: .bottom))
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Nyxframe is asleep")
                    .font(Nyx.display(26))
                Text("Your gallery is locked while you're away.")
                    .font(.subheadline)
                    .foregroundStyle(Nyx.mist)
            }
            Spacer()
            Button {
                Task { await biometricLock.attemptUnlock() }
            } label: {
                Label("Unlock with \(biometricLock.biometryLabel)", systemImage: "faceid")
            }
            .buttonStyle(NyxPrimaryButtonStyle())
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                NyxBackdrop(showsStars: false)
                StarfieldView(density: 110)
            }
            .ignoresSafeArea()
        )
    }
}

/// Shown while the session bootstraps -- the moon mark breathing on the
/// night sky instead of a bare "Loading..." spinner.
struct LaunchVeilView: View {
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, Color.accentColor], startPoint: .top, endPoint: .bottom))
                .scaleEffect(breathe ? 1.06 : 0.94)
                .opacity(breathe ? 1 : 0.7)
            ProgressView()
                .tint(Nyx.mist)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                NyxBackdrop(showsStars: false)
                StarfieldView(density: 110)
            }
            .ignoresSafeArea()
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
