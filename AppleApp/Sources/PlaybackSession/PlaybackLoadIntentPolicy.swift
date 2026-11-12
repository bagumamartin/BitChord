/// Keeps a quality reload from changing the listener's play/pause choice.
enum PlaybackLoadIntentPolicy {
    static func shouldHoldQualityReload(shouldResumePlayback: Bool) -> Bool {
        !shouldResumePlayback
    }
}
