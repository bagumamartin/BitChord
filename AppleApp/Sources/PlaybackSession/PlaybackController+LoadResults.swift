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

// What happens after a load: Now Playing, durations, failures, and keeping
// the engine's next track in step.
extension PlaybackController {
    func prepareNowPlayingForPlayback(entry: QueueEntry, duration: Double, position: Double) {
        nowPlaying.prepareForPlayback(
            id: entry.id, title: entry.title, artist: entry.artist,
            duration: duration, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, position: position,
            canNext: playingIndex + 1 < queue.count || repeatMode == .all,
            canPrevious: true, canSeek: duration > 0
        )
    }

    func loadDidSucceed(
        entry: QueueEntry,
        index: Int,
        info: TrackInfoRec,
        startAt: Double = 0,
        headers: [String: String]
    ) {
        if var pending = pendingPlaybackLatency, pending.entryID == entry.id {
            let firstBufferAt = ProcessInfo.processInfo.systemUptime
            PlaybackLatencySignposts.record(
                "first-buffer", entryID: entry.id,
                elapsed: firstBufferAt - pending.startedAt
            )
            pending.firstBufferAt = firstBufferAt
            pendingPlaybackLatency = pending
        }
        NSLog("[BitChord] loaded track at %.2fs (duration %.2fs)", startAt, info.durationSeconds)
        loadingGeneration = nil
        playingIndex = index
        current = entry
        historyVideoID = youtubeVideoID(for: entry)
        let restoredStream = recoveringEntryID == entry.id
        if restoredStream {
            sourceDecisionNotes[entry.id] = "Playback restored with a fresh stream."
            recoveringEntryID = nil
        }
        engineLoadedId = entry.id
        loadedSourcePath = info.source
        loadedSourceHeaders = headers
        Self.releaseObsoleteStreams(keeping: Set([entry.id, nextEntry?.id].compactMap { $0 }))
        position = startAt
        positionSampledAt = Date()
        duration = info.durationSeconds
        repairMissingDuration(entry: entry, info: info)
        lastError = nil
        automaticLoadEntryId = nil
        automaticSkips = 0
        state = .playing
        persistSession()
        refreshArtwork(entry, source: info.source)
        fetchLyrics(for: entry)
        fetchCanvas(for: entry)
        applySpatialPreference()
        try? engine.setLoudnessMode(mode: routeAwareLoudnessMode)
        nerd = dolbyRenderer?.nerd ?? engine.nerdStats()
        try? engine.setBitPerfectEnabled(enabled: effectiveBitPerfectOutput)
        racingLossless = QualityUpgrade.isRacing(entry.id)
        if !restoredStream {
            scrobbleArmed = false
            scrobbleSent = false
            if let id = historyVideoID {
                QueueBuilderBridge.shared.rememberPlayed(videoId: id)
                PlaybackTrackerBridge.shared.onPlaying(videoId: id)
            }
            publishPresence()
            ScrobbleBridge.shared.nowPlaying(
                artist: scrobbleArtist(for: entry), title: entry.title, album: entry.albumName,
                durationSec: Swift.Int32(info.durationSeconds), positionMs: Swift.Int64(0)
            )
        }
        nowPlaying.update(
            id: entry.id, title: entry.title, artist: entry.artist,
            duration: info.durationSeconds, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: isPlaying, position: position
        )
        nowPlaying.playbackDidStart()
        widgetPublisher.publish(entry: entry, isPlaying: true,
                                canNext: playingIndex + 1 < queue.count,
                                canPrevious: index > 0)
        if dolbyRenderer == nil { lookForBetterCopy(entry, codec: info.codec, kbps: info.kbps) }
        let output = engine.outputDevice()
        let sourceKind: String
        switch resolvedOrigin[entry.id] {
        case .local: sourceKind = "local"
        case .cache: sourceKind = "cache"
        case .youtube: sourceKind = "youtube"
        case .substitute: sourceKind = "substitute"
        case .other, .none: sourceKind = "other"
        }
        let rawLoudnessOrigin = nerd?.loudnessOrigin.lowercased() ?? ""
        let loudnessOrigin: String
        if rawLoudnessOrigin.contains("youtube") {
            loudnessOrigin = "player_response"
        } else if rawLoudnessOrigin.contains("measurement") || rawLoudnessOrigin.contains("replaygain") || rawLoudnessOrigin.contains("ebu r128") {
            loudnessOrigin = "analyzed"
        } else {
            loudnessOrigin = "none"
        }
        PlaybackDebugLog.shared.record(
            "quality-start source=\(sourceKind) route_kind=\(AudioRouteState.shared.kind) claimed_quality=\(AppSettings.shared.effectiveAudioQuality(metered: NetworkQuality.shared.metered).name) claimed_max_kbps=\(NetworkQuality.shared.maxKbps) measured_codec=\(info.codec) measured_rate=\(info.sampleRate) measured_depth=\(info.bitDepth) measured_kbps=\(info.kbps) output_rate=\(output.sampleRate) output_format=\(output.sampleFormat) loudness_origin=\(loudnessOrigin) loudness_detail=\(nerd?.loudnessOrigin ?? "No measurement") loudness_db=\(currentLoudnessDb.map { String($0) } ?? "unknown") loudness_mode=\(loudnessMode) bit_perfect=\(output.bitPerfectActive)",
            about: entry.id
        )
        // The incoming source must be ready before the outgoing tail begins.
        // Waiting for the current download here made prefetch start up to eight
        // seconds late, then full analysis delayed queueing it even further.
        syncEngineQueueNext()
        scheduleSequencing()
    }

    /// Legacy cached WebM files can lack both container and saved duration.
    /// Repair metadata after playback starts, without delaying cached/offline audio.
    private func repairMissingDuration(entry: QueueEntry, info: TrackInfoRec) {
        guard duration <= 0, !OfflinePlaybackPolicy.isEnabled,
              let videoId = entry.videoId else { return }
        let generation = playGeneration
        let ceiling = ResolvePrefs.current().maxKbps
        durationRepairTask?.cancel()
        durationRepairTask = Task { [weak self] in
            guard let stream = try? await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: ceiling),
                  let seconds = stream.durationSeconds, seconds > 0, !Task.isCancelled,
                  let self, self.playGeneration == generation, self.engineLoadedId == entry.id,
                  self.loadedSourcePath == info.source, let current = self.current else { return }
            self.duration = Double(seconds)
            self.nowPlaying.update(id: current.id, title: current.title, artist: current.artist,
                duration: self.duration, artworkData: current.artworkData, thumbnailUrl: current.thumbnailUrl,
                isPlaying: self.isPlaying, position: self.position)
            self.nowPlaying.updateCommands(canNext: self.nextEntry != nil, canPrevious: true, canSeek: true)
            self.publishSmartWindow()
            await StreamFileCache.shared.storeDuration(seconds, at: info.source)
        }
    }

    func loadDidFail(entry: QueueEntry, error: Error) {
        if let pending = pendingPlaybackLatency, pending.entryID == entry.id {
            let resolved = pending.resolvedAt.map { String(format: "%.0fms", ($0 - pending.startedAt) * 1_000) } ?? "unresolved"
            PlaybackDebugLog.shared.record(
                "latency: tap→resolved \(resolved), first buffer unavailable, first audible unavailable (\(pending.cacheState), \(pending.client))",
                about: entry.id
            )
            pendingPlaybackLatency = nil
        }
        loadingGeneration = nil
        holdAfterLoad = false
        // A song this player moved to on its own is stepped over, not stopped
        // on: upstream's skipPastUnplayable, reached here only after the whole
        // recovery ladder in the resolver has already run.
        if OfflinePlaybackSourcePolicy.shouldAutoSkipFailedTrack(
                offlineEnabled: OfflinePlaybackPolicy.isEnabled
           ),
           automaticLoadEntryId == entry.id, state == .buffering, automaticSkips < 3,
           markUnplayable(entry, after: error),
           let next = nextPlayableIndex(after: playingIndex) {
            automaticSkips += 1
            PlaybackDebugLog.shared.record(
                "could not play \(entry.title) (\(error.localizedDescription)); moving on to \(queue[next].title)",
                about: entry.id
            )
            automaticLoadEntryId = queue[next].id
            loadCurrent(next, refreshAutoplay: true)
            return
        }
        automaticLoadEntryId = nil
        lastError = "Couldn't play “\(entry.title)” — \(error.localizedDescription)"
        if current?.id == entry.id {
            restoredStart = (entry.id, max(0, position))
        }
        // Somebody (pause, another load, sleep, interruption) owns the
        // transport now; their state stands and only the message is new.
        // Tearing the engine down here would stop whatever they started.
        guard state == .buffering else { return }
        state = .stopped
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        try? engine.pause()
        let engine = self.engine
        loadSubmissionGate.advance(to: playGeneration) { try? engine.stop() }
        nowPlaying.stop()
        deactivateAudioSessionIfIdle()
    }

    /// A streamed download is finished once `.complete` lands, or when it was
    /// never a stream. `.grow` without `.complete` means more analysis may help.
    private nonisolated static func fileSettled(_ path: String) -> Bool {
        let files = FileManager.default
        if files.fileExists(atPath: path + ".complete") { return true }
        if files.fileExists(atPath: path + ".grow") { return false }
        return true
    }

    private nonisolated static func fileBytes(_ path: String) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    /// A quarter more audio (or 512 KB, whichever is larger) is enough new
    /// evidence to be worth another whole-track analysis.
    private nonisolated static func grewMeaningfully(from old: Int64, to new: Int64) -> Bool {
        new - old >= max(old / 4, 512 * 1024)
    }

    /// Holds next-track preparation until this track is ~15 s in, at most 20 s,
    /// and never when the track is too short to spare the time.
    private nonisolated static func waitForOpeningToSettle(
        engine: PlayerEngine,
        outgoingDuration: Double,
        transitionSeconds: Double
    ) async throws {
        let settledAt = 15.0
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let position = engine.positionSeconds()
            if position >= settledAt { return }
            if outgoingDuration > 0, outgoingDuration - position < transitionSeconds + 60 { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Keeps the engine's pending-next pointing at the following queue entry
    /// so gapless/crossfade arming works (spec §3.1). Repeat-one without Automix
    /// arms a gapless loop of the current file.
    /// Repeat-one *with* Automix arms a self-mix into the same track.
    func syncEngineQueueNext() {
        nextPreparationTask?.cancel()
        nextPreparationTask = nil
        guard !sleepAfterTrack else { return }
        if dolbyRenderer != nil {
            nowPlaying.updateCommands(canNext: nextEntry != nil, canPrevious: current != nil, canSeek: duration > 0)
            return
        }
        nowPlaying.updateCommands(canNext: playingIndex + 1 < queue.count || repeatMode == .all, canPrevious: current != nil,
                                  canSeek: engineLoadedId != nil && duration > 0)
        // Recommendation replies can arrive before the selected song has loaded.
        // Read-ahead starts after that load, using its authoritative audio path.
        guard engineLoadedId != nil, engineLoadedId == current?.id else { return }
        Self.releaseObsoleteStreams(keeping: Set([current?.id, nextEntry?.id].compactMap { $0 }))
        queueNextRevision &+= 1
        let revision = queueNextRevision
        let gate = loadSubmissionGate
        gate.setQueueRevision(revision)
        let generation = playGeneration
        let expectedSource = loadedSourcePath ?? ""
        // Clear an obsolete prefetch now, including a voice armed but not audible.
        gate.submit(generation: generation, revision: revision) { [engine] in
            try? engine.queueNextIfCurrent(request: LoadRequest(
                source: "", title: "", artist: "", startSeconds: 0, plan: nil,
                headers: [:], claimedKbps: 0, loudnessDb: nil, durationSeconds: nil
            ), expectedSource: expectedSource)
        }
        // Upstream still measures the following track while a non-Automix
        // repeat-one loop runs, so leaving the loop is not a cold start.
        warmUpcoming(around: playingIndex, generation: generation)
        if repeatMode == .one && !automixEnabled {
            // Queue the same local recording before EOS so background audio
            // continues across the boundary without a new source lookup.
            if let repeated = repeatableCurrentSource(), let entry = current {
                let loop = TransitionPlanRec(
                    style: .gapless, bassSwap: false, bassSwapFraction: 0.7,
                    filterSweep: 0, vocalOverlap: 0, fadeSeconds: 0,
                    transitionEndSeconds: 0, cueSeconds: 0, playbackRate: 1,
                    bedFraction: 0, bedGainDb: 0, dipDepth: 0, dipWidth: 0,
                    postGlideSeconds: 0, outgoingDurationSeconds: duration,
                    reason: "repeat-one"
                )
                sourceHeadersByPath = [repeated.source: repeated.headers]
                gate.submit(generation: generation, revision: revision) { [engine] in
                    try? engine.queueNextIfCurrent(request: LoadRequest(
                        source: repeated.source, title: entry.title, artist: entry.artist,
                        startSeconds: 0, plan: loop, headers: repeated.headers,
                        claimedKbps: UInt32(clamping: repeated.kbps), loudnessDb: repeated.loudnessDb,
                        durationSeconds: repeated.durationSec.map(Double.init)
                    ), expectedSource: expectedSource)
                }
            }
            return
        }
        guard let next = nextEntry else {
            return
        }
        let nextId = next.id
        let outgoingId = current?.id
        let selfMix = repeatMode == .one || nextId == outgoingId
        // The pacing window is keyed by the transition, not the plan: this loop
        // re-plans the same pair up to twelve times as the files grow.
        let transitionPair = TransitionPair(outgoing: outgoingId ?? "", incoming: nextId)
        let engine = self.engine
        let automix = automixEnabled
        let allowMusicUnderstanding = automixPerformanceMode != "EFFICIENT"
        // The *file* the engine opened, not `current.source` — which for a
        // YouTube track is `yt:<videoId>` and not something the planner can
        // decode. Passing the identifier made `duration_of` return 0, which
        // skips the whole-track analysis, leaves `bpm` at 0, and drops the plan
        // to `Tier::Plain`. The incoming side still analysed fine, so the only
        // symptom was a plausible-looking cue sitting on top of a plain 12 s
        // crossfade — which was every transition on normal streaming playback.
        let currentSource = loadedSourcePath ?? ""
        let outgoingDuration = duration > 0 ? duration : (current?.durationSeconds ?? 0)
        let currentSourceHeaders = loadedSourceHeaders
        let repeatedSource = selfMix ? repeatableCurrentSource() : nil
        let currentText = current?.itemText ?? ""
        let nextText = next.itemText
        // A self-mix is never an album gapless splice — force a real blend.
        let albumSequential = !selfMix && !shuffleEnabled && (current?.sameAlbum(as: next) ?? false)
        let prefs = ResolvePrefs.current()
        // `.utility` is deferrable. The scheduler was holding this until the
        // song was nearly over, so the next download — and the plan that waits
        // on it — started after the blend should already have been playing.
        // Spend spare playback time on quality, but keep a short-track transition
        // out of the twelve-second preparation window.
        let fadeSeconds = automix ? max(pendingAutomixPlan?.fadeSeconds ?? 8, 8)
            : Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        let preparationBudget = PlaybackPreparationPolicy.lookupBudget(
            remainingSeconds: outgoingDuration - position, transitionSeconds: fadeSeconds
        )
        nextPreparationTask = Task.detached(priority: .userInitiated) {
            defer { MemoryRelief.soon() }
            do {
                // A handoff used to start the next track's resolve, download
                // and whole-track analysis while the blend into this track was
                // still ramping — the moment the mixer, lyric fetch, video and
                // artwork all compete too. Let the opening settle first; a
                // short track or a late queue change skips the wait.
                try await Self.waitForOpeningToSettle(
                    engine: engine, outgoingDuration: outgoingDuration,
                    transitionSeconds: fadeSeconds
                )
                let selection: ResolveOutcome
                if let repeatedSource {
                    selection = ResolveOutcome(source: repeatedSource, leftover: nil)
                } else {
                    selection = try await Self.resolveSource(next, prefs: prefs, preparationBudget: preparationBudget)
                }
                try Task.checkCancellation()
                let outcome = try await Self.bufferPreparedSource(selection, mediaId: nextId)
                let stillCurrent = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.playGeneration == generation
                        && self.nextEntry?.id == nextId
                        && self.current?.id == outgoingId
                        && self.queueNextRevision == revision
                }
                guard stillCurrent else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation, self.queueNextRevision == revision else { return }
                    self.noteResolved(next, outcome: outcome, prefs: prefs)
                    self.sourceHeadersByPath = [outcome.source.source: outcome.source.headers]
                    DownloadStore.shared.retainPlayback(paths: Set([outcome.source.source, self.loadedSourcePath ?? ""]))
                    // The better copy has to be in hand before the blend arms.
                    // Waiting until this track becomes current means the upgrade
                    // arrives during the ramp and cuts it. Skip for self-mix —
                    // the playing file is already the one being upgraded in place.
                    if !selfMix {
                        self.lookForBetterCopy(
                            next,
                            codec: outcome.source.format.codec ?? "",
                            kbps: Swift.UInt32(outcome.source.kbps)
                        )
                    }
                }
                let stillQueueTarget = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.playGeneration == generation
                        && self.nextEntry?.id == nextId
                        && self.current?.id == outgoingId
                        && self.queueNextRevision == revision
                }
                guard stillQueueTarget else { return }
                let resolved = outcome.source
                guard !PlaybackCodecCapabilities.shared.canRenderDolby(codec: resolved.codec, headers: resolved.headers) else { return }
                let incomingDuration = next.durationSeconds > 0
                    ? next.durationSeconds : Double(resolved.durationSec ?? 0)
                let declaredDuration = incomingDuration > 0 ? incomingDuration : nil
                let safetyFade = albumSequential ? 4.0 : min(
                    8.0,
                    outgoingDuration > 0 ? outgoingDuration / 3 : 8.0,
                    incomingDuration > 0 ? incomingDuration / 3 : 8.0
                )
                // Queue a real overlap as soon as the source is resolved. Beat
                // and vocal analysis can take seconds and must not be on the
                // critical path to hearing the next record under this one.
                let initialSafetyPlan: TransitionPlanRec? = automix ? TransitionPlanRec(
                    style: .equalPower, bassSwap: false, bassSwapFraction: 0.7,
                    filterSweep: 0, vocalOverlap: 0, fadeSeconds: safetyFade,
                    outgoingHoldSeconds: 0,
                    transitionEndSeconds: 0, cueSeconds: 0, playbackRate: 1,
                    bedFraction: 0, bedGainDb: 0, dipDepth: 0, dipWidth: 0,
                    postGlideSeconds: 0, outgoingDurationSeconds: outgoingDuration,
                    reason: "safety:"
                ) : nil
                let safetyPlan = initialSafetyPlan
                    .map { constrainAutomixPlanForSources(plan: $0, outgoingSource: currentSource, incomingSource: resolved.source, outgoingDuration: outgoingDuration, incomingDuration: incomingDuration) }
                guard try gate.performIfCurrent(generation: generation, revision: revision, {
                    try engine.queueNextIfCurrent(request: LoadRequest(
                    source: resolved.source, title: next.title, artist: next.artist,
                    startSeconds: 0, plan: safetyPlan, headers: resolved.headers,
                    claimedKbps: Swift.UInt32(resolved.kbps),
                    loudnessDb: resolved.loudnessDb, durationSeconds: declaredDuration
                ), expectedSource: expectedSource)
                }) != nil else { return }
                if let safetyPlan {
                    await MainActor.run { [weak self] in
                        guard let self, self.playGeneration == generation,
                              self.queueNextRevision == revision, self.current?.id == outgoingId else { return }
                        self.adoptAutomixPlan(safetyPlan)
                    }
                }
                if automix {
                    NSLog(
                        "[BitChord] automix queued %@%@ with an immediate %.1fs overlap",
                        next.title,
                        selfMix ? " (self-mix)" : "",
                        safetyPlan?.fadeSeconds ?? 0
                    )
                }
                guard automix, !currentSource.isEmpty else { return }
                let fade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
                // ResolveSource returns when the progressive intro is on disk.
                // Analyze it now against the queued safety overlap, then refresh
                // the plan as more of either file arrives while the mixer is arming.
                var attempt = 0
                var muOutgoingDone = false
                var muIncomingDone = false
                while true {
                    try Task.checkCancellation()
                    let stillPlanning = await MainActor.run { [weak self] in
                        guard let self else { return false }
                        return self.playGeneration == generation
                            && self.nextEntry?.id == nextId
                            && self.current?.id == outgoingId
                            && self.queueNextRevision == revision
                    }
                    guard stillPlanning else { return }
                    // An analysis of a file still downloading is thrown away:
                    // the cache is keyed on the file's size, so the finished
                    // file is analysed again from the top (decode, beat and
                    // vocal models), which was a second full burst of CPU for
                    // every track. The safety overlap is already queued, so
                    // while the song has a minute or more to run, wait for the
                    // finished files; only a transition that is close plans
                    // from what has arrived.
                    while !(Self.fileSettled(currentSource) && Self.fileSettled(resolved.source)) {
                        let remaining = outgoingDuration - engine.positionSeconds()
                        if outgoingDuration <= 0 || remaining < safetyFade + 60 { break }
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    // C's instrumentation: a transition is being armed against
                    // an outgoing track whose analysed tail is unknown. One line
                    // per transition says how often that happens and whether the
                    // file was still growing, which decides whether the tail
                    // ever arrives before the blend needs it.
                    if attempt == 0 {
                        await MainActor.run { [weak self] in
                            guard let self,
                                  let edges = self.regionEdgesBySource[currentSource],
                                  edges.end == nil else { return }
                            let partial = FileManager.default.fileExists(atPath: currentSource + ".grow")
                                && !FileManager.default.fileExists(atPath: currentSource + ".complete")
                            self.debugLog.record(
                                "automix: no analysed tail when the transition arms\(partial ? " (file still growing)" : " (file complete)")",
                                about: outgoingId
                            )
                        }
                    }
                    // Music Understanding (OS 27+): seed key (and, without the
                    // Neural Engine beat model, rhythm) overlays once per pair
                    // before the first plan. Sequential
                    // so we never run two Metal sessions at once (background
                    // GPU asserts abort the process).
                    //
                    // Not only on the first plan: a progressive file can only be
                    // analysed once it is complete, which is usually a replan or
                    // two later, and the incoming track is the one whose grid
                    // matters most. Each file is tried once it is complete; a
                    // seeded rhythm grid lets the native planner skip the CPU
                    // Beat This! pass for that file.
                    if MusicUnderstandingAnalyzer.isAvailable, !(muOutgoingDone && muIncomingDone) {
                        let decoder: (Double, [String: String]) -> MusicUnderstandingAnalyzer.Decode = { length, headers in
                            { path, destination in
                                engine.writeAnalysisWav(
                                    source: path, dest: destination.path, headers: headers,
                                    maxSeconds: length > 0 ? length + 5 : 0, targetRate: nil
                                )
                            }
                        }
                        var outOk = false
                        var inOk = false
                        // Each file in its own analysis turn, so a video map or
                        // the other plan never runs beside it.
                        if !muOutgoingDone {
                            let decode = decoder(outgoingDuration, currentSourceHeaders)
                            outOk = await AnalysisTurns.take {
                                await MusicUnderstandingAnalyzer.analyzeAndSeed(
                                    filePath: currentSource, allowAccelerator: allowMusicUnderstanding,
                                    decode: decode
                                )
                            }
                            muOutgoingDone = outOk || Self.fileSettled(currentSource)
                        }
                        if !muIncomingDone {
                            let decode = decoder(incomingDuration, resolved.headers)
                            let incomingSource = resolved.source
                            inOk = await AnalysisTurns.take {
                                await MusicUnderstandingAnalyzer.analyzeAndSeed(
                                    filePath: incomingSource, allowAccelerator: allowMusicUnderstanding,
                                    decode: decode
                                )
                            }
                            muIncomingDone = inOk || Self.fileSettled(resolved.source)
                        }
                        if outOk || inOk {
                            NSLog(
                                "[BitChord] Music Understanding overlay out=%@ in=%@",
                                outOk ? "yes" : "no",
                                inOk ? "yes" : "no"
                            )
                        }
                    }
                    let allowEffects = self.pacing.allowsEffect(for: transitionPair)
                    let incomingSource = resolved.source
                    let incomingHeaders = resolved.headers
                    let rawPlan = await AnalysisTurns.take {
                        engine.planAutomix(
                            outgoingPath: currentSource,
                            incomingPath: incomingSource,
                            outgoingText: currentText,
                            incomingText: nextText,
                            albumSequential: albumSequential,
                            crossfadeSeconds: fade,
                            outgoingDurationSeconds: outgoingDuration,
                            incomingDurationSeconds: incomingDuration,
                            outgoingHeaders: currentSourceHeaders,
                            incomingHeaders: incomingHeaders,
                            allowEffects: allowEffects
                        )
                    }
                    // Each plan decodes both tracks whole; hand those pages back now
                    // rather than when the whole preparation ends minutes later.
                    MemoryRelief.soon()
                    let plan = constrainAutomixPlanForSources(
                        plan: rawPlan, outgoingSource: currentSource, incomingSource: resolved.source,
                        outgoingDuration: outgoingDuration, incomingDuration: incomingDuration
                    )
                    let queued = try gate.performIfCurrent(generation: generation, revision: revision, {
                        self.pacing.note(plan.style, for: transitionPair)
                        return try engine.queueNextIfCurrent(request: LoadRequest(
                            source: resolved.source,
                            title: next.title,
                            artist: next.artist,
                            startSeconds: plan.cueSeconds,
                            plan: plan,
                            headers: resolved.headers,
                            claimedKbps: Swift.UInt32(resolved.kbps),
                            loudnessDb: resolved.loudnessDb,
                            // Not bookkeeping: the mixer schedules a transition against
                            // the end of the outgoing track, and a container that
                            // declares no length gives it nothing to schedule against —
                            // the incoming is then never armed and the queue advances by
                            // a cut. We already know the length.
                            durationSeconds: declaredDuration
                        ), expectedSource: expectedSource)
                    }) != nil
                    guard queued else { return }
                    // This synchronous query is ordered after QueueNext on the
                    // mixer command channel, so it confirms the analyzed plan
                    // reached the engine before this race is considered won.
                    let delivered = engine.pendingTrack()?.source == resolved.source
                    if delivered {
                        let shown = Self.displayAutomixReason(plan.reason)
                        NSLog(
                            "[BitChord] automix plan %d for %@%@: %@, cue %.2fs, fade %.2fs, end %.1fs — %@",
                            attempt, next.title, selfMix ? " (self-mix)" : "",
                            String(describing: plan.style),
                            plan.cueSeconds, plan.fadeSeconds, plan.transitionEndSeconds,
                            shown
                        )
                        // The transition log Automix never had: which technique each
                        // pair got and why, persisted with the rest of the playback
                        // record so "it only ever fades" can be counted, not argued.
                        PlaybackDebugLog.shared.record(
                            "automix \(Self.tierName(plan)) [plan \(attempt)] → \(next.title): "
                                + String(format: "cue %.1fs, window %.1fs, end %.1fs. ", plan.cueSeconds, plan.fadeSeconds, plan.transitionEndSeconds)
                                + (shown.isEmpty ? "no reason given" : shown),
                            about: nextId
                        )
                        await MainActor.run { [weak self] in
                            guard let self, self.queueNextRevision == revision else { return }
                            self.adoptAutomixPlan(plan)
                        }
                    }
                    // Replan after delivery too: the incoming/outgoing windows
                    // gain useful audio as progressive files grow. The mixer
                    // applies each replacement only while Arming; the file and
                    // tail guards below end this loop once further evidence is
                    // unavailable or the safety fade is about to start.
                    let settled = Self.fileSettled(currentSource) && Self.fileSettled(resolved.source)
                    if settled { return }
                    let lead = max(plan.fadeSeconds, safetyFade) + 8
                    // Each plan re-analyses a grown file from the top (decode,
                    // beat model, vocals). Replanning every two seconds repeated
                    // that work many times per transition; replan only once
                    // either file has grown meaningfully or finished.
                    let planned = (Self.fileBytes(currentSource), Self.fileBytes(resolved.source))
                    while true {
                        let remaining = outgoingDuration - engine.positionSeconds()
                        if outgoingDuration > 0, remaining < lead { return }
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        if Self.fileSettled(currentSource) && Self.fileSettled(resolved.source) { break }
                        if Self.grewMeaningfully(from: planned.0, to: Self.fileBytes(currentSource))
                            || Self.grewMeaningfully(from: planned.1, to: Self.fileBytes(resolved.source)) { break }
                    }
                    attempt += 1
                }
            } catch is CancellationError {
                return
            } catch {
                // Keep the current song playing; natural end retries with a
                // full load and reports any final failure to the listener.
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation,
                          self.queueNextRevision == revision else { return }
                    PlaybackDebugLog.shared.record("next-track preparation failed: \(error.localizedDescription)", about: nextId)
                    // Found out minutes early, so the track after it is
                    // prepared in its place and the blend still happens.
                    if self.markUnplayable(next, after: error) {
                        PlaybackDebugLog.shared.record("stepping over it; preparing the track after it instead", about: nextId)
                        self.syncEngineQueueNext()
                    }
                }
            }
        }
    }
}
