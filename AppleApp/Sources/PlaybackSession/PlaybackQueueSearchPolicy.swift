import Foundation

enum QueueSearchPolicy {
    static func matches(title: String, artist: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || artist.localizedCaseInsensitiveContains(query)
    }
}
