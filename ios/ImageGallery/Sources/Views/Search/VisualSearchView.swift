import PhotosUI
import SwiftUI
import UIKit

/// Reverse/visual image search -- mirrors web's `VisualSearchPage.jsx`.
/// Reached either from Search's camera-icon toolbar button (fresh image
/// pick) or from a post's "Find visually similar" link (`seedMediaId`,
/// which skips the picker and searches immediately on appear).
struct VisualSearchView: View {
    @StateObject private var viewModel: VisualSearchViewModel

    init(seedMediaId: Int? = nil) {
        _viewModel = StateObject(wrappedValue: VisualSearchViewModel(seedMediaId: seedMediaId))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.seedMediaId == nil {
                    picker
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                if viewModel.isLoading {
                    ProgressView().padding(.top, 24)
                } else if viewModel.hasSearched {
                    if viewModel.items.isEmpty {
                        ContentUnavailableCompat(
                            title: "No visually similar posts found",
                            systemImage: "camera.viewfinder"
                        )
                        .padding(.top, 24)
                    } else {
                        NyxMediaGrid(items: viewModel.items)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .nyxScreen()
        .navigationTitle("Visual search")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadSeedIfNeeded() }
        .onChange(of: viewModel.pickerItem) { _ in
            Task { await viewModel.handlePickerSelection() }
        }
    }

    private var picker: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $viewModel.pickerItem, matching: .images) {
                ZStack {
                    if let data = viewModel.previewData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .overlay {
                                VStack(spacing: 10) {
                                    Image(systemName: "camera.viewfinder").font(.system(size: 34))
                                    Text("Choose a reference image").font(.subheadline.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                            }
                    }
                }
            }
            .buttonStyle(.plain)

            if viewModel.previewData != nil {
                Button("Clear", role: .destructive) { viewModel.reset() }
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 16)
    }
}
