import Foundation

/// A successful scope acquisition is balanced exactly once, after the last
/// scan or playback reader releases its reference.
final class SecurityScopedResourceLease: @unchecked Sendable {
    let url: URL
    private let acquired: Bool
    private let stop: @Sendable (URL) -> Void

    init(
        url: URL,
        start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.url = url.standardizedFileURL
        self.stop = stop
        acquired = start(url)
    }

    func covers(_ source: String?) -> Bool {
        guard let source, !source.isEmpty else { return false }
        let candidate: URL
        if source.hasPrefix("/") { candidate = URL(fileURLWithPath: source) }
        else if let parsed = URL(string: source), parsed.isFileURL { candidate = parsed }
        else { return false }
        let folder = url.pathComponents
        let components = candidate.standardizedFileURL.pathComponents
        return components.count >= folder.count && Array(components.prefix(folder.count)) == folder
    }

    deinit {
        if acquired { stop(url) }
    }
}
