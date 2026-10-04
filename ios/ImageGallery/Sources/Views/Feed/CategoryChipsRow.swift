import SwiftUI

/// Category picker for the Explore filter shelf -- an "All" chip plus one
/// per top-level category, ending in a "More" chip that opens the full
/// `CategoryBrowserView` (which also lists subcategories). Selecting a chip
/// here only ever sets `categoryId`; picking a specific subcategory still
/// requires drilling into "More".
///
/// Lays its chips out inline (no scroll view of its own) so the shelf can
/// put it in the same horizontal scroll as the sort menu.
struct CategoryChipsRow: View {
    @Binding var selectedCategoryId: Int?
    var onSelect: (Int?) -> Void

    @State private var categories: [CategorySummary] = []

    var body: some View {
        HStack(spacing: 8) {
            NyxChip(title: "All", isSelected: selectedCategoryId == nil) {
                onSelect(nil)
            }
            ForEach(categories) { category in
                NyxChip(title: category.name, isSelected: selectedCategoryId == category.id) {
                    Haptics.light()
                    onSelect(category.id)
                }
            }
            NavigationLink(destination: CategoryBrowserView()) {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.3x3").imageScale(.small)
                    Text("More")
                }
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().strokeBorder(Nyx.hairline, lineWidth: 1))
                .foregroundStyle(Nyx.mist)
            }
        }
        .task {
            if categories.isEmpty {
                categories = (try? await GalleryAPIClient.shared.categories()) ?? []
            }
        }
    }
}
