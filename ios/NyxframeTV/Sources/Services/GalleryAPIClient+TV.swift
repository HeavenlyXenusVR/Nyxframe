import Foundation

/// Endpoints only the TV app uses. Kept here rather than in the shared
/// client so the iOS target's surface doesn't change.
extension GalleryAPIClient {
    private struct TagCloudResponse: Decodable {
        struct Entry: Decodable { var tag: String; var count: Int? }
        var tags: [Entry]
    }

    /// The site's most-used tags (`GET /api/tags`, the same list the web
    /// app's tag cloud shows), most popular first.
    func popularTags() async throws -> [String] {
        let response: TagCloudResponse = try await requestJSONCached("/api/tags", ttl: 10 * 60, requiresAuth: false)
        return response.tags.map(\.tag)
    }
}
