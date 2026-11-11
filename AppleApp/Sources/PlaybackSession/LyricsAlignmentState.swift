import Foundation

/// What the player can honestly tell the listener about local word timing.
enum LyricsAlignmentState: Equatable {
    case idle
    case permissionNeeded
    case languageUnavailable
    case deviceUnavailable
    case analyzing
    case partial
    case complete
    case noMatch
    case audioUnavailable
    case failed

    var message: String? {
        switch self {
        case .idle: nil
        case .permissionNeeded: "Speech Recognition permission is needed. Tap Retry to request it or enable it in Settings."
        case .languageUnavailable: "No supported speech language matches these lyrics."
        case .deviceUnavailable: "On-device speech recognition is unavailable for this language."
        case .analyzing: "Analyzing locally…"
        case .partial: "Some lines synced locally; other lines remain untimed."
        case .complete: "Lyrics synced locally."
        case .noMatch: "No lyric words matched the audio confidently."
        case .audioUnavailable: "Audio could not be read for local syncing."
        case .failed: "Local lyric syncing failed."
        }
    }

    var canRetry: Bool {
        switch self {
        case .languageUnavailable, .deviceUnavailable, .analyzing, .idle: false
        case .permissionNeeded, .partial, .complete, .noMatch, .audioUnavailable, .failed: true
        }
    }
}
