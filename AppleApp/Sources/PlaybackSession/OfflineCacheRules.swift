import Foundation

/// Small policy helpers kept independent of app frameworks so transfer and
/// offline-mode invariants can be checked in the standalone verification suite.
struct CacheGeneration: Equatable, Sendable {
    private(set) var value: UInt64 = 0

    mutating func advance() { value &+= 1 }
    func accepts(_ token: UInt64) -> Bool { token == value }
}

enum CacheClearPolicy {
    static func pathsToDeferDeletion(audioPaths: Set<String>, activeReaderPaths: Set<String>) -> Set<String> {
        audioPaths.intersection(activeReaderPaths)
    }

    static func removingRepublishedPath(_ path: String, from pendingPaths: Set<String>) -> Set<String> {
        pendingPaths.subtracting([path])
    }
}

enum DownloadResumeSignature {
    static func make(url: String, headers: [String: String], allowsCellular: Bool) -> String {
        let normalizedHeaders = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { $0.key.lowercased() + ":" + $0.value }
            .joined(separator: "|")
        return url + "|cellular=" + (allowsCellular ? "allowed" : "blocked") + "|" + normalizedHeaders
    }
}

enum RetryBatchDisposition: Equatable {
    case started(count: Int)
    case waitingForWiFi(count: Int)
    case waitingForNetwork(count: Int)
    case noFailedJobs
}

enum DownloadRetryPolicy {
    static func disposition(failedCount: Int, connected: Bool, metered: Bool, wifiOnly: Bool) -> RetryBatchDisposition {
        guard failedCount > 0 else { return .noFailedJobs }
        guard connected else { return .waitingForNetwork(count: failedCount) }
        guard metered && wifiOnly else { return .started(count: failedCount) }
        return .waitingForWiFi(count: failedCount)
    }
}

enum OfflinePlaybackRules {
    static let settingKey = "offline_playback"
    static let unavailableMessage = "Offline playback is on, and this track has no downloaded or cached audio. Connect to the internet or turn off Play saved audio only."
}
