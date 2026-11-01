import Foundation
import BitChordShared

extension PlaybackController {
    func pollStreamRecovery() {
        if let pending = deferredNetworkRecovery {
            guard NetworkQuality.shared.connected else { return }
            deferredNetworkRecovery = nil
            if current?.id == pending.entryID, playGeneration == pending.generation, state == .buffering {
                engineLoadedId = nil
                streamRecovery.select(pending.entryID, resetAttempts: true)
                SourceResolverBridge.shared.refreshPlaybackSources()
                if let entry = current, let videoID = youtubeVideoID(for: entry) { PlayerBridge.shared.forgetPlaybackUrl(videoId: videoID) }
                loadCurrent(playingIndex, startAt: pending.position, refreshAutoplay: false, freshResolution: true)
                return
            }
        }
        // The range downloader waits for connectivity at its current offset.
        // An outage must not consume the two source-recovery attempts.
        guard NetworkQuality.shared.connected else { return }
        if streamRecoveryPathChanges != NetworkQuality.shared.pathChanges {
            streamRecoveryPathChanges = NetworkQuality.shared.pathChanges
            if let entry = current { streamRecovery.select(entry.id, resetAttempts: false) }
        }
        if state == .paused {
            _ = streamRecovery.observe(position: playbackPosition, now: ProcessInfo.processInfo.systemUptime, playing: false, bufferedFrames: 0)
            return // Keep source failures queued until the listener resumes.
        }
        for failure in engine.drainSourceErrors() {
            if recoverInterruptedStream(source: failure.source, explanation: "The audio stream failed; requesting a fresh stream.") { return }
            if failure.source == loadedSourcePath { stopAfterFailedRecovery(source: failure.source) }
        }
        let stalled = streamRecovery.observe(
            position: playbackPosition, now: ProcessInfo.processInfo.systemUptime,
            playing: state == .playing && !smartMixInProgress && dolbyRenderer == nil,
            bufferedFrames: engine.outputHealth().bufferedFrames
        )
        if stalled, let source = loadedSourcePath {
            if !recoverInterruptedStream(source: source, explanation: "The stream stopped delivering audio; requesting a fresh stream.") {
                stopAfterFailedRecovery(source: source)
            }
        }
    }

    private func stopAfterFailedRecovery(source: String) {
        guard let entry = current, source == loadedSourcePath,
              PlaybackRecoveryPolicy.canRecover(entrySource: entry.source, loadedSource: source, origin: resolvedOrigin[entry.id]?.rawValue),
              duration <= 0 || playbackPosition < duration - 3 else { return }
        wakeGrowingReader(source)
        let at = playbackPosition
        pausePlayback()
        engineLoadedId = nil
        restoredStart = (entry.id, at)
        recoveryNeedsFreshResolution = true
        lastError = "Playback could not be restored automatically. Press Play to retry."
        sourceDecisionNotes[entry.id] = lastError
    }

    private func wakeGrowingReader(_ source: String) {
        if source.hasPrefix("/"), FileManager.default.fileExists(atPath: source + ".grow") {
            try? Data().write(to: URL(fileURLWithPath: source + ".playback-cancelled"), options: .atomic)
        }
    }

    @discardableResult
    func recoverInterruptedStream(source: String, explanation: String) -> Bool {
        guard source == loadedSourcePath, let entry = current,
              PlaybackRecoveryPolicy.canRecover(entrySource: entry.source, loadedSource: source, origin: resolvedOrigin[entry.id]?.rawValue),
              engineLoadedId == entry.id,
              state == .playing || state == .stopped,
              queue.indices.contains(playingIndex), queue[playingIndex].id == entry.id,
              !smartMixInProgress, dolbyRenderer == nil else { return false }
        let at = playbackPosition
        if !NetworkQuality.shared.connected {
            deferredNetworkRecovery = (entry.id, at, playGeneration)
            state = .buffering
            lastError = "Waiting for the network to return."
            return true
        }
        guard streamRecovery.claimRetry(position: at, duration: duration) else { return false }
        wakeGrowingReader(source)
        recoveringEntryID = entry.id
        sourceDecisionNotes[entry.id] = explanation
        debugLog.record(explanation, about: entry.id)
        QualityUpgrade.forget(entry.id)
        // A fresh resolution bypasses growing/completed playback caches and clears
        // only issued URLs, preserving local downloads and the user's source order.
        SourceResolverBridge.shared.refreshPlaybackSources()
        if let videoId = youtubeVideoID(for: entry) { PlayerBridge.shared.forgetPlaybackUrl(videoId: videoId) }
        engineLoadedId = nil
        loadCurrent(playingIndex, startAt: max(0, at - 0.25), refreshAutoplay: false, freshResolution: true)
        return true
    }
}
