import Foundation

final class ScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct ScopeChecks {
    static func main() {
        let started = ScopeCounter(), stopped = ScopeCounter()
        var selected: SecurityScopedResourceLease? = SecurityScopedResourceLease(
            url: URL(fileURLWithPath: "/tmp/library"),
            start: { _ in started.increment(); return true },
            stop: { _ in stopped.increment() }
        )
        precondition(selected!.covers("/tmp/library/song.flac"))
        precondition(selected!.covers("file:///tmp/library/song.flac"))
        precondition(!selected!.covers("/tmp/library-other/song.flac"))
        precondition(!selected!.covers("https://example.invalid/song.flac"))
        precondition(!selected!.covers("/tmp/library/../outside.flac"))
        var playback = selected
        selected = nil
        precondition(started.value == 1 && stopped.value == 0)
        precondition(playback!.covers("/tmp/library/song.flac"))
        playback = nil
        precondition(stopped.value == 1)
        do {
            let failed = SecurityScopedResourceLease(
                url: URL(fileURLWithPath: "/tmp/unscoped"),
                start: { _ in false }, stop: { _ in stopped.increment() }
            )
            withExtendedLifetime(failed) {}
        }
        precondition(stopped.value == 1)
        print("PASS scope balance, playback retention, failed acquisition, and path boundaries")
    }
}
