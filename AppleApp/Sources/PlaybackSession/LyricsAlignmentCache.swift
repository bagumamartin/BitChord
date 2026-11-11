import Foundation
import BitChordShared

/// Small process-local LRU-ish cache. Inputs include the selected provider,
/// source file identity and exact lyric text, so edits/provider changes cannot
/// accidentally reuse timings from another document.
@MainActor
enum LyricsAlignmentCache {
    private static let capacity = 24
    private static var values: [String: [LyricLineDto]] = [:]
    private static var order: [String] = []

    static func key(trackId: String, provider: String?, source: String, lines: [LyricLineDto]) -> String {
        var hasher = Hasher()
        hasher.combine(trackId)
        hasher.combine(provider)
        hasher.combine(source)
        for line in lines { combine(line, into: &hasher) }
        return String(hasher.finalize())
    }

    private static func combine(_ line: LyricLineDto, into hasher: inout Hasher) {
            hasher.combine(line.text)
            hasher.combine(line.timeMs)
            hasher.combine(line.endMs)
            hasher.combine(line.sungUntilMs)
            hasher.combine(String(describing: line.alignment))
            for word in line.words {
                hasher.combine(word.text)
                hasher.combine(word.startMs)
                hasher.combine(word.endMs)
            }
            if let background = line.background { combine(background, into: &hasher) }
    }

    static func value(for key: String) -> [LyricLineDto]? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    static func insert(_ lines: [LyricLineDto], for key: String) {
        values[key] = lines
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }
}
