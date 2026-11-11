import Foundation

struct ImportedPlaylistTrack {
    init(
        id: String, title: String, artist: String, sourceTitle: String,
        sourceArtist: String, album: String?, durationText: String?,
        videoId: String?, thumbnailUrl: String?
    ) {}
}

struct QueueEntry {
    static func formatDuration(_ seconds: Double) -> String { "\(Int(seconds))" }
}

struct SearchHit {
    var isTrack = true
    var title = ""
    var resolvedArtist = ""
    var durationText: String?
    var videoId = ""
    var thumbnailUrl: String?
}

final class InnertubeSearch {
    static let shared = InnertubeSearch()
    func search(_ query: String, scope: String) async throws -> [SearchHit] { [] }
}

enum TrackMatch {
    struct Candidate {
        init(title: String, artist: String, durationText: String?) {}
    }
    struct Target {
        init(title: String, artist: String, durationSec: Double?) {}
    }
    static func bestIndex(in candidates: [Candidate], target: Target) -> Int? { nil }
    static func seconds(of value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
