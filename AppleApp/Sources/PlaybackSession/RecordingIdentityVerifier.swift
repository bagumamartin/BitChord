import Foundation

/// Catalogue metadata finds a candidate; decoded audio establishes identity.
/// Native verification is serialized, cancellable between jobs, and uses CPU
/// processing that remains valid for iOS background audio.
enum RecordingIdentityVerifier {
    private actor Worker {
        private var acceptedFiles: Set<String> = []
        func matches(videoID: String, reference: String, candidate: String, allowTimingEdits: Bool, urgent: Bool) async -> Bool {
            func stamp(_ path: String) -> String {
                let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
                return "\(path)|\(bytes)|\(modified)"
            }
            let key = stamp(reference) + "|" + stamp(candidate) + "|\(allowTimingEdits)"
            guard !Task.isCancelled else { return false }
            if acceptedFiles.contains(key) { return true }
            // A check playback is waiting on does not queue behind the planner;
            // the rest take their turn with the other heavy analyses.
            let align: @Sendable () -> VersionAlignmentRec? = {
                Task.isCancelled ? nil : alignVersions(songPath: reference, otherPath: candidate)
            }
            let aligned = urgent ? align() : await AnalysisTurns.take { align() }
            guard !Task.isCancelled, let result = aligned else {
                PlaybackDebugLog.shared.record("recording identity rejected: no reliable audio alignment", about: videoID)
                return false
            }
            let offsets = result.segments.map(\.offset)
            let accepted = result.confident && (allowTimingEdits || (offsets.max() ?? 0) - (offsets.min() ?? 0) <= 1)
            PlaybackDebugLog.shared.record(String(format: "recording identity accepted=%@ similarity=%.3f minimum=%.3f coverage=%.3f",
                accepted ? "true" : "false", result.similarity, result.minimumWindowSimilarity, result.coverage), about: videoID)
            if accepted && !Task.isCancelled {
                if acceptedFiles.count >= 16 { acceptedFiles.removeAll(keepingCapacity: true) }
                acceptedFiles.insert(key)
            }
            return accepted
        }
    }
    private static let worker = Worker()

    /// `urgent`: playback is waiting on the answer, so it skips the analysis
    /// turns rather than waiting out a transition plan.
    @MainActor static func matches(videoId: String, candidate: String, allowTimingEdits: Bool = false, urgent: Bool = false) async -> Bool {
        PlaybackController.retainVerificationStream(videoId)
        defer { PlaybackController.releaseVerificationStream(videoId) }
        do {
            let reference: String
            if let cached = await StreamFileCache.shared.path(for: videoId, allowQualityFallback: true, onlyOriginal: true) {
                reference = cached
            } else {
                let stream = try await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: 128)
                reference = try await PlaybackController.streamViaKtor(videoId: videoId, url: stream.url, headers: stream.headers,
                    codec: stream.mimeType.lowercased().contains("opus") ? "Opus" : "AAC", kbps: stream.kbps,
                    youtubeVideoId: videoId, durationSeconds: stream.durationSeconds, maxKbps: 128, expectedMimeType: stream.mimeType)
            }
            guard try await settled(reference), try await settled(candidate) else { return false }
            if reference == candidate { return true }
            let matched = await worker.matches(videoID: videoId, reference: reference, candidate: candidate,
                                               allowTimingEdits: allowTimingEdits, urgent: urgent)
            return matched && !Task.isCancelled
        } catch { return false }
    }
    private static func settled(_ path: String) async throws -> Bool {
        let files = FileManager.default
        while files.fileExists(atPath: path + ".grow") && !files.fileExists(atPath: path + ".complete") {
            try Task.checkCancellation()
            if files.fileExists(atPath: path + ".failed") || files.fileExists(atPath: path + ".playback-cancelled") { return false }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        return files.fileExists(atPath: path) && !files.fileExists(atPath: path + ".failed")
    }
}
