import SwiftUI

struct MessageBubble: View {
    let body_: String
    let senderLabel: String?
    let isMine: Bool
    var createdAt: String? = nil

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            HStack {
                if isMine { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    if let senderLabel, !isMine {
                        Text(senderLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(body_)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if isMine {
                        LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else {
                        Rectangle().fill(.ultraThinMaterial).overlay(Nyx.surface)
                    }
                }
                .foregroundStyle(isMine ? .white : .primary)
                // A "tail" corner on the sender's side, so a run of
                // bubbles reads as one voice.
                .clipShape(BubbleShape(isMine: isMine))
                .overlay(BubbleShape(isMine: isMine).stroke(Nyx.hairline, lineWidth: isMine ? 0 : 1))
                if !isMine { Spacer(minLength: 40) }
            }
            if let createdAt, !createdAt.isEmpty {
                Text(DateFormatting.chatTimestamp(createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, isMine ? 0 : 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}

struct MessageComposer: View {
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .nyxGlass(radius: 22)
            Button {
                onSend()
            } label: {
                Group {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.35)))
            }
            .buttonStyle(NyxPressStyle(scale: 0.9))
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && !isSending
    }
}

/// Rounded bubble with a tighter corner at the bottom on the sender's side.
private struct BubbleShape: Shape {
    let isMine: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18
        let small: CGFloat = 5
        var path = Path()
        let tl = big
        let tr = big
        let bl = isMine ? big : small
        let br = isMine ? small : big
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }
}
