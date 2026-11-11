import BitChordShared

/// Device-only playback preference. Download network policy remains separate.
enum OfflinePlaybackPolicy {
    static let settingKey = OfflinePlaybackRules.settingKey
    static let unavailableMessage = OfflinePlaybackRules.unavailableMessage

    static var isEnabled: Bool {
        PlatformSettings.shared.getBoolean(key: settingKey, default: false)
    }

    static func setEnabled(_ enabled: Bool) {
        PlatformSettings.shared.putBoolean(key: settingKey, value: enabled)
    }
}
