import Foundation
import Observation

/// Each row observes its own activity; byte updates do not republish the queue.
@MainActor @Observable
final class DownloadActivity {
    enum Phase { case queued, waitingForNetwork, waitingForWiFi, resolving, transferring, verifying, saved, failed, cancelled }
    var phase: Phase = .queued
    var received: Int64 = 0
    var total: Int64? = nil
    var detail: String? = nil
    private var lastPublishedAt: TimeInterval = 0

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }
    var label: String {
        switch phase {
        case .queued: return "Queued"
        case .waitingForNetwork: return "Waiting for network"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .resolving: return "Finding audio"
        case .verifying: return "Verifying recording"
        case .transferring:
            return fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading"
        case .saved: return "Downloaded"
        case .failed: return "Download failed"
        case .cancelled: return "Download cancelled"
        }
    }
    func update(received: Int64, total: Int64?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishedAt >= 0.2 || (total.map { received >= $0 } ?? false) || phase != .transferring else { return }
        lastPublishedAt = now
        self.received = max(0, received)
        self.total = total.flatMap { $0 > 0 ? $0 : nil }
        phase = .transferring
    }
}

typealias DownloadProgressHandler = @Sendable (Int64, Int64?) -> Void

protocol DownloadBackend: Sendable {
    func resolve(_ entry: QueueEntry, quality: String) async throws -> String
    func resolve(_ entry: QueueEntry, quality: String, youtubeFallback: Bool) async throws -> String
    func transfer(id: String, url: String, headers: [String: String], progress: @escaping DownloadProgressHandler) async throws -> String
    func restoreTransfer(id: String, progress: @escaping DownloadProgressHandler) async throws -> String?
    func hasCompletedTransfer(id: String) -> Bool
    func cancel(id: String)
    func pause(id: String)
    func finish(id: String)
    func verify(path: String, entry: QueueEntry, provider: String) async throws
}
extension DownloadBackend {
    func resolve(_ entry: QueueEntry, quality: String, youtubeFallback: Bool) async throws -> String { try await resolve(entry, quality: quality) }
    func restoreTransfer(id: String, progress: @escaping DownloadProgressHandler) async throws -> String? { nil }
    func hasCompletedTransfer(id: String) -> Bool { false }
    func pause(id: String) { cancel(id: id) }
    func finish(id: String) {}
    func verify(path: String, entry: QueueEntry, provider: String) async throws {}
}
