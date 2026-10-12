import SwiftUI

/// Owner-only "what changed, and when" panel -- mirrors web's
/// `MediaEditHistory` (components/media.jsx). Lives behind a
/// `DisclosureGroup` in `MediaDetailView`'s info panel; the view model
/// fetches lazily on first expand (see `loadEditHistoryIfNeeded`).
struct MediaEditHistoryView: View {
    @ObservedObject var viewModel: MediaDetailViewModel
    @State private var categories: [CategorySummary] = []

    var body: some View {
        Group {
            if let error = viewModel.editHistoryError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            } else if let entries = viewModel.editHistory {
                if entries.isEmpty {
                    Text("No edits yet.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .task {
            await viewModel.loadEditHistoryIfNeeded()
            if categories.isEmpty { categories = (try? await GalleryAPIClient.shared.categories()) ?? [] }
        }
    }

    private func entryRow(_ entry: EditHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.displayName?.nilIfEmpty ?? entry.username ?? "User")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(DateFormatting.relative(entry.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(entry.changes.keys).sorted(), id: \.self) { field in
                if let change = entry.changes[field] {
                    Text("\(Self.fieldLabel(field)): \(displayValue(field: field, value: change.from)) → \(displayValue(field: field, value: change.to))")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
            }
        }
        .padding(10)
        .softCard(radius: Metrics.Radius.sm)
    }

    /// Keys here are camelCase -- `.convertFromSnakeCase` rewrites the
    /// backend's `category_id`/`is_adult` change keys on the way in, same
    /// as it does every other response field. See `EditHistoryEntry`'s
    /// header comment.
    private static let fieldLabels: [String: String] = [
        "title": "Title",
        "description": "Description",
        "tags": "Tags",
        "categoryId": "Category",
        "visibility": "Visibility",
        "isAdult": "18+ flag",
    ]

    private static func fieldLabel(_ field: String) -> String {
        fieldLabels[field] ?? field
    }

    private func displayValue(field: String, value: JSONValue) -> String {
        switch value {
        case .null:
            return "(empty)"
        case .string(let s):
            if s.isEmpty { return "(empty)" }
            if field == "tags" {
                if let data = s.data(using: .utf8),
                   let tags = try? JSONDecoder().decode([String].self, from: data) {
                    return tags.isEmpty ? "(none)" : tags.joined(separator: ", ")
                }
                return s
            }
            if field == "categoryId" {
                if let match = categories.first(where: { String($0.id) == s }) { return match.name }
                return "#\(s)"
            }
            return s
        case .number(let n):
            if field == "categoryId" {
                let id = Int(n)
                if let match = categories.first(where: { $0.id == id }) { return match.name }
                return "#\(id)"
            }
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b):
            return b ? "Yes" : "No"
        }
    }
}
