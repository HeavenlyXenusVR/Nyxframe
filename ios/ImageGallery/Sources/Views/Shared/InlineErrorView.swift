import SwiftUI

/// An inline failure with a way out of it.
///
/// Every browsing screen rendered its error as `Text(errorMessage)
/// .foregroundStyle(.red)` and nothing else -- the same dead end the web
/// app had before `Notice` grew an `onRetry`. That matters more here than
/// it looks: this backend is reached through a tunnel whose origin
/// rotates, and `LiveConfigService` re-points the app at the new one in
/// the background, so a failed load is very often already recoverable by
/// the time the viewer reads the message. Without a retry the only way
/// forward is force-quitting the app, or knowing that pull-to-refresh
/// exists on the screens that happen to have it.
struct InlineErrorView: View {
    let message: String
    let retry: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                guard !isRetrying else { return }
                isRetrying = true
                Task {
                    await retry()
                    isRetrying = false
                }
            } label: {
                if isRetrying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Retry").font(.footnote.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRetrying)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .softCard()
        .padding(.horizontal)
    }
}
