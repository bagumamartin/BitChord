import Foundation
import BitChordShared
import os
#if os(iOS)
import UIKit
#if DEBUG
import AVFoundation
#endif
#else
import AppKit
#endif

// Loading a queue entry into the engine, including Dolby Atmos.
extension PlaybackController {
    func loadCurrent(_ index: Int, startAt: Double? = nil, refreshAutoplay: Bool = true, freshResolution: Bool = false, reuseCurrentSource: Bool = false) {
        guard queue.indices.contains(index) else { return }
        startEngineIfNeeded()
        let engineStartupTask = self.engineStartupTask
        let entry = queue[index]
        deferredNetworkRecovery = nil
        let repeatedSource = reuseCurrentSource && current?.id == entry.id ? repeatableCurrentSource() : nil
        let requiresFreshResolution = freshResolution || (recoveryNeedsFreshResolution && current?.id == entry.id)
        if current?.id == entry.id, playingIndex == index, engineLoadedId == entry.id,
           state == .buffering || state == .playing {
            return
        }
        let latencyStartedAt = ProcessInfo.processInfo.systemUptime
        pendingPlaybackLatency = PlaybackLatencySample(
            entryID: entry.id, startedAt: latencyStartedAt, initialPosition: startAt ?? 0
        )
        PlaybackLatencySignposts.record("tap", entryID: entry.id, elapsed: 0)
        let latencyRecorder: PlaybackLatencyRecorder = { [weak self] resolvedAt, cacheState, client in
            await MainActor.run { [weak self] in
                guard let self, var sample = self.pendingPlaybackLatency,
                      sample.entryID == entry.id else { return }
                sample.resolvedAt = resolvedAt
                sample.cacheState = cacheState
                sample.client = client
                self.pendingPlaybackLatency = sample
                PlaybackLatencySignposts.record(
                    "resolved", entryID: entry.id, elapsed: resolvedAt - sample.startedAt
                )
            }
        }
        durationRepairTask?.cancel()
        recoveryNeedsFreshResolution = false
        if !freshResolution { recoveringEntryID = nil }
        streamRecovery.select(entry.id, resetAttempts: !freshResolution)
        nextPreparationTask?.cancel()
        nextPreparationTask = nil
        playGeneration += 1
        let generation = playGeneration
        Self.releaseObsoleteStreams(keeping: [entry.id])
        resumeGeneration &+= 1
        // A manual selection stops the outgoing voice at once: the listener
        // asked for a different song, not a few more seconds of this one.
        // (Automatic advances never come through here — they ride the
        // engine's armed blend via handoff.) The replacement then loads on
        // the expedited path below: resolve, probe and open, but no Automix
        // analysis — planning a DJ blend for a tap would hold the cut for
        // seconds, and a tap means now.
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        try? engine.pause()
        let stoppingEngine = engine
        loadSubmissionGate.advance(to: generation) { try? stoppingEngine.stop() }
        upgradeFor = nil
        racingLossless = false
        smartMixInProgress = false
        smartTransitionWindow = nil
        pendingAutomixPlan = nil
        mixFadeUntil = nil
        analysisTier = nil
        analysisConfidence = nil
        analysisSources = nil
        automixCueSeconds = nil
        let wasAudible = state == .playing || (state == .paused && engineLoadedId != nil)
        playingIndex = index
        current = entry
        historyVideoID = youtubeVideoID(for: entry)
        let outgoingPosition = position
        position = startAt ?? 0
        duration = 0
        lastError = nil
        state = .buffering
        holdAfterLoad = false
        loadingGeneration = generation
        if refreshAutoplay {
            maybeAutoplay(force: true)
        } else {
            maybeAutoplay(lowWaterRefill: true)
        }
        nowPlaying.updateCommands(canNext: playingIndex + 1 < queue.count || repeatMode == .all, canPrevious: true, canSeek: false)
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        loadedSourcePath = nil
        loadedSourceHeaders = [:]
        sourceHeadersByPath.removeAll(keepingCapacity: true)
        nowPlaying.update(
            id: entry.id, title: entry.title, artist: entry.artist,
            duration: 0, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: false, position: position
        )
        widgetPublisher.publish(entry: entry, isPlaying: false,
                                canNext: index + 1 < queue.count,
                                canPrevious: index > 0)
        persistSession()
        // Start read-ahead after this selection has loaded (syncEngineQueueNext).
        // Rapid Next taps must not start four speculative resolver walks ahead
        // of the track the listener is actually waiting for.
        if wasAudible && !requiresFreshResolution {
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(outgoingPosition))
        }
        let engine = self.engine
        let loadSubmissionGate = self.loadSubmissionGate
        let prefs = ResolvePrefs.current()
        let resume = startAt ?? 0
        let task = Task.detached(priority: .utility) {
            do {
                // In particular, after a cold restore the output task and the
                // track resolver used to race. A quick local/cache resolve
                // could send LoadTrack before the engine had an output stream;
                // the UI then had lyrics and a playing state without audio.
                try await engineStartupTask?.value
                let outcome: ResolveOutcome
                if let repeatedSource {
                    outcome = ResolveOutcome(source: repeatedSource, leftover: nil)
                    await latencyRecorder(ProcessInfo.processInfo.systemUptime, "cached", "repeat")
                } else {
                    let selected = try await Self.resolveSource(
                        entry, prefs: prefs, freshResolution: requiresFreshResolution, latencyResolved: latencyRecorder
                    )
                    outcome = try await Self.bufferPreparedSource(selected, mediaId: entry.id)
                }
                let stillCurrent = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard stillCurrent else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    self.noteResolved(entry, outcome: outcome, prefs: prefs)
                }
                let resolved = outcome.source
                if PlaybackCodecCapabilities.shared.canRenderDolby(codec: resolved.codec, headers: resolved.headers) {
                    _ = try await AudioSessionManager.activate(preferredSampleRate: nil)
                    try await self.loadDolby(resolved, entry: entry, index: index, start: resume, generation: generation)
                    return
                }
                // Manual loads cut: no Automix planning on this path. The
                // blend machinery (safety overlap, analysis, re-plan) belongs
                // to the background prefetcher, whose armed track a manual
                // Next promotes directly via trySkipToArmed. Planning here as
                // well would hold an explicit tap for the seconds analysis
                // costs — and a tap means now.
                let start = resume
                // Inspect the resolved source before loading it so the output
                // can request its native clock family (44.1 or 48 kHz) and, on
                // eligible macOS routes, open an exact integer stream before
                // the first decoded samples reach the mixer. Probe failures do
                // not prevent ordinary playback.
                let sourceFormat = try? engine.probeAudioSource(
                    source: resolved.source,
                    headers: resolved.headers
                )
                let currentAfterProbe = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard currentAfterProbe else { return }
                let matchRate = PlatformSettings.shared.getBoolean(
                    key: "match_source_sample_rate", default: true
                )
                let sessionFormat = try await AudioSessionManager.activate(
                    preferredSampleRate: matchRate
                        ? sourceFormat.map { Double($0.sampleRate) }
                        : nil
                )
                let currentAfterActivation = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard currentAfterActivation else { return }
                let loadRequest = LoadRequest(
                    source: resolved.source,
                    title: entry.title,
                    artist: entry.artist,
                    startSeconds: start,
                    plan: nil,
                    headers: resolved.headers,
                    claimedKbps: Swift.UInt32(resolved.kbps),
                    loudnessDb: resolved.loudnessDb,
                    // Not bookkeeping: the mixer schedules a transition against
                    // the end of the outgoing track, and a container that
                    // declares no length gives it nothing to schedule against —
                    // the incoming is then never armed and the queue advances by
                    // a cut. We already know the length.
                    durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : resolved.durationSec.map(Double.init)
                )
                // Engine setup and the command submission share one serial
                // lane. If another selection arrives after this request passes
                // the gate, its load is submitted after this one; if it arrives
                // first, this older generation is discarded here.
                guard let info = try loadSubmissionGate.performIfCurrent(generation: generation, {
                    do {
                        try engine.prepareTrackOutput(
                            sourceRate: sourceFormat?.sampleRate ?? 0,
                            sourceChannels: sourceFormat?.channels ?? 0,
                            sourceBitDepth: sourceFormat?.bitDepth ?? 0,
                            codec: sourceFormat?.codec ?? "",
                            losslessPcm: sourceFormat?.losslessPcm ?? false,
                            matchSourceRate: matchRate,
                            sessionRate: sessionFormat?.rate,
                            sessionChannels: sessionFormat?.channels
                        )
                    } catch {
                        NSLog("[BitChord] track output preparation failed; continuing with current output: \(error)")
                    }
                    guard loadSubmissionGate.isCurrent(generation) else { return nil as TrackInfoRec? }
                    return try engine.loadTrackPaused(request: loadRequest)
                }), let info else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    do {
                        self.prepareNowPlayingForPlayback(entry: entry, duration: info.durationSeconds, position: resume)
                        let hold = self.holdAfterLoad
                        if !hold { try engine.play() }
                        self.currentLoudnessDb = resolved.loudnessDb
                        self.loadDidSucceed(
                            entry: entry, index: index, info: info,
                            startAt: resume, headers: resolved.headers
                        )
                        if hold { self.settleHeldLoad() }
                    } catch {
                        self.loadDidFail(entry: entry, error: error)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    self.loadDidFail(entry: entry, error: error)
                }
            }
        }
#if os(iOS)
        playbackStartTask = task
#else
        _ = task
#endif
    }

    private func loadDolby(_ source: ResolvedSource, entry: QueueEntry, index: Int, start: Double, generation: UInt64) async throws {
        guard playGeneration == generation else { return }
        let renderer = AppleDolbyRenderer()
        renderer.volume = targetOutputGain
        renderer.rate = Float(playbackRate)
        dolbyRenderer = renderer
        applySpatialPreference()
        do {
            let info = try await renderer.prepare(source: source.source, title: entry.title, artist: entry.artist,
                codec: source.codec, headers: source.headers, startAt: start, claimedKbps: UInt32(max(0, source.kbps)))
            guard playGeneration == generation, dolbyRenderer === renderer else { renderer.stop(); return }
            renderer.onEnd = { [weak self, weak renderer] in
                guard let self, self.playGeneration == generation, self.dolbyRenderer === renderer else { return }
                self.handleTrackEnded(.natural, source: source.source)
            }
            renderer.onFailure = { [weak self, weak renderer] in
                guard let self, self.playGeneration == generation, self.dolbyRenderer === renderer else { return }
                self.pausePlayback()
                self.lastError = "The Dolby source stopped serving playable audio."
            }
            prepareNowPlayingForPlayback(entry: entry, duration: info.durationSeconds, position: start)
            let hold = holdAfterLoad
            if !hold { renderer.play() }
            loadDidSucceed(entry: entry, index: index, info: info, startAt: start, headers: [:])
            if hold { settleHeldLoad() }
        } catch {
            renderer.stop()
            if dolbyRenderer === renderer { dolbyRenderer = nil }
            throw error
        }
    }
}
