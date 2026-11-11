import Foundation

/// Pure source check so offline playback can be verified without platform settings.
enum OfflinePlaybackSourcePolicy {
    static func shouldAutoSkipFailedTrack(offlineEnabled: Bool) -> Bool {
        !offlineEnabled
    }

    static func blocksUncachedSource(source: String, isLocal: Bool, offlineEnabled: Bool) -> Bool {
        guard offlineEnabled else { return false }
        guard isLocal else { return true }
        if source.hasPrefix("file://") || source.hasPrefix("/") { return false }
        return true
    }
}
