import Foundation

enum PlaybackHandoffPolicy {
    static func acceptsRepeatOne(
        title: String,
        artist: String,
        sourceIsArmed: Bool,
        currentTitle: String?,
        currentArtist: String?
    ) -> Bool {
        guard sourceIsArmed else { return false }
        guard let currentTitle, let currentArtist else { return false }
        return title == currentTitle && artist == currentArtist
    }
}
