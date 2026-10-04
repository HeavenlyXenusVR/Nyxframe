import SwiftUI

/// Placeholder tiles shown while a grid's first page is loading, in the
/// same staggered rhythm as `MasonryGrid` so the layout doesn't jump when
/// real tiles arrive.
struct SkeletonGridView: View {
    var lanes: Int = 2
    var count: Int = 10

    @State private var pulse = false

    private static let heights: [CGFloat] = [1.25, 1, 1.33, 1.5, 1, 0.8]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<max(1, lanes), id: \.self) { lane in
                VStack(spacing: 12) {
                    ForEach(0..<(count / max(1, lanes)), id: \.self) { row in
                        RoundedRectangle(cornerRadius: Nyx.Radius.card, style: .continuous)
                            .fill(Nyx.glow.opacity(pulse ? 0.45 : 0.2))
                            .aspectRatio(1 / Self.heights[(lane * 3 + row) % Self.heights.count], contentMode: .fit)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .accessibilityLabel("Loading")
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
