import Foundation

/// Notifications `VideoPlayerController` posts so a background soundtrack
/// can react to video playback -- shared by the iOS app (which ducks its
/// music) and the tvOS app (which fades its music out completely while a
/// video plays and back in once the video ends).
extension Notification.Name {
    /// Posted on every rate change. `userInfo["playing"]` is the new state;
    /// `userInfo["closed"] == true` marks the final post from a controller
    /// being torn down (the viewer left the video).
    static let nyxframeVideoPlaybackChanged = Notification.Name("nyxframeVideoPlaybackChanged")
    /// Posted once when a video plays through to its end mark.
    static let nyxframeVideoReachedEnd = Notification.Name("nyxframeVideoReachedEnd")
}
