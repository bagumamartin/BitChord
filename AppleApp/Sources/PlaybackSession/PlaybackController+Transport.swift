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

// Transport: play/pause, next and previous, repeat, shuffle and seeking.
extension PlaybackController {
    func audioInterruptionBegan() {
        guard isPlaying || isBuffering else { return }
        pausePlayback(releaseAudioSession: true)
        wasInterrupted = true
    }

    func audioInterruptionEnded(shouldResume: Bool) {
        let resumePending = wasInterrupted
        wasInterrupted = false
        guard resumePending, shouldResume, state == .paused else { return }
        togglePlayPause()
    }

    func togglePlayPause() {
        // A manual Play supersedes interruption recovery. Otherwise the later
        // interruption-ended event can toggle already resumed audio back off.
        wasInterrupted = false
        noteLocalIntent()
        startEngineIfNeeded()
        if state == .buffering {
            // Pausing a track that is still loading keeps the load: the bytes
            // and the resolved URL are the expensive part, and throwing them
            // away made the next tap start from nothing.
            holdAfterLoad = true
            state = .paused
            nowPlaying.updateRate(0, position: position)
            VideoPlayback.shared.transportClockChanged()
            return
        }
        if holdAfterLoad, loadingGeneration == playGeneration {
            holdAfterLoad = false
            state = .buffering
            return
        }
        if current == nil {
            if !queue.isEmpty { loadCurrent(min(playingIndex, queue.count - 1), refreshAutoplay: false) }
            return
        }
        if engineLoadedId != current?.id {
            // Only when it is still the track the position was saved for.
            let start = restoredStart.flatMap { $0.entryId == current?.id ? $0.position : nil }
            restoredStart = nil
            let fresh = recoveryNeedsFreshResolution
            if fresh, let current { streamRecovery.select(current.id, resetAttempts: true) }
            loadCurrent(playingIndex, startAt: start, refreshAutoplay: false, freshResolution: fresh)
            return
        }
        if isPlaying {
            pausePlayback()
        } else {
            // The session may have been interrupted or deactivated while this
            // loaded track was paused. Reactivate it off the main thread before
            // releasing the output callback; a cold restored track takes the
            // load path above, which already waits for activation before open.
            resumeGeneration &+= 1
            let generation = resumeGeneration
            let selection = playGeneration
            let gate = loadSubmissionGate
            let usesDolby = dolbyRenderer != nil
            // Reflect intent immediately so a second tap cancels this resume.
            state = .playing
            let engine = self.engine
            let retainedActiveSession = AudioSessionManager.isActive
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                // The engine still owns the loaded source here. Its current
                // format snapshot is enough to prepare the output after the
                // audio session has been reactivated.
                let sourceFormat = engine.nerdStats()
                let matchRate = PlatformSettings.shared.getBoolean(
                    key: "match_source_sample_rate", default: true
                )
                let sessionFormat: AudioSessionManager.Format?
                do {
                    sessionFormat = try await AudioSessionManager.activate(
                        preferredSampleRate: matchRate
                            ? (sourceFormat.sampleRate > 0 ? Double(sourceFormat.sampleRate) : nil)
                            : nil,
                        // Re-arbitrating the route on every resume is what made
                        // Mac resume slow and clicky; a route change is caught
                        // by the route observer, not by un-pausing.
                        restartRouting: false
                    )
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.resumeGeneration == generation,
                              self.playGeneration == selection else { return }
                        self.audioActivationFailed(error)
                    }
                    return
                }
                do {
                    _ = try gate.performIfCurrent(generation: selection) {
                        if usesDolby { return }
                        // Keep the output's buffered audio and decoder history
                        // when the hardware format still agrees; rebuilding
                        // would discard that ring and re-seek AAC.
                        let output = engine.outputDevice()
#if os(iOS)
                        let formatAgrees = sessionFormat.map {
                            Double(output.sampleRate) == $0.rate && output.channels == $0.channels
                        } ?? false
#else
                        // macOS has no session format; the output opened for
                        // this track's rate is still right for it.
                        let formatAgrees = !matchRate || sourceFormat.sampleRate == 0
                            || output.sampleRate == sourceFormat.sampleRate
#endif
                        if retainedActiveSession, AudioSessionManager.isActive,
                           output.started, formatAgrees {
                            let message = "resume retained output \(output.sampleRate) Hz / \(output.channels) ch"
                            PlaybackDebugLog.shared.record(message)
                            NSLog("[BitChord] %@", message)
                            return
                        }
                        try engine.prepareTrackOutput(
                            sourceRate: sourceFormat.sampleRate,
                            sourceChannels: sourceFormat.channels,
                            sourceBitDepth: sourceFormat.bitDepth,
                            codec: sourceFormat.codec,
                            losslessPcm: ["FLAC", "ALAC", "PCM", "PCM Float"].contains(sourceFormat.codec),
                            matchSourceRate: matchRate,
                            sessionRate: sessionFormat?.rate,
                            sessionChannels: sessionFormat?.channels
                        )
                    }
                } catch {
                    NSLog("[BitChord] resume output preparation failed; continuing with current output: \(error)")
                }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.resumeGeneration == generation,
                          self.playGeneration == selection, self.isPlaying,
                          self.current?.id == self.engineLoadedId,
                          let entry = self.current
                    else { return }
                    do {
                        self.prepareNowPlayingForPlayback(entry: entry, duration: self.duration, position: self.position)
                        if let renderer = self.dolbyRenderer { renderer.play() } else { try engine.play() }
                        self.state = .playing
                        let speed = Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
                        self.playbackRate = speed.isFinite ? min(max(speed, 0.5), 2.0) : 1.0
                        self.positionSampledAt = Date()
                        self.nowPlaying.updateRate(speed, position: self.position)
                        self.nowPlaying.playbackDidStart()
                        VideoPlayback.shared.transportClockChanged()
                    } catch {
                        self.nowPlaying.updateRate(0, position: self.position)
                        self.state = .paused
                        VideoPlayback.shared.transportClockChanged()
                        self.lastError = "Audio output could not resume: \(error)"
                    }
                }
            }
#if os(iOS)
            playbackStartTask = task
#else
            _ = task
#endif
        }
    }

    /// A load that finished after the listener paused it: loaded, not audible.
    func settleHeldLoad() {
        holdAfterLoad = false
        try? engine.pause()
        VideoPlayback.shared.transportClockChanged()
        dolbyRenderer?.pause()
        state = .paused
        positionSampledAt = Date()
        nowPlaying.updateRate(0, position: position)
        persistSession()
    }

    func pausePlayback(releaseAudioSession: Bool = false) {
        deferredNetworkRecovery = nil
        resumeGeneration &+= 1
        wasInterrupted = false
        let loading = state == .buffering
        if !loading { position = playbackPosition }
        dolbyRenderer?.pause()
        positionSampledAt = Date()
        state = .paused
        VideoPlayback.shared.transportClockChanged()
        #if os(macOS)
        Task { await HeadphoneRouting.shared.releaseWhenIdle() }
        #endif
        try? engine.pause()
        if loading {
            playGeneration &+= 1
            dolbyRenderer?.stop()
            dolbyRenderer = nil
            engineLoadedId = nil
            let engine = self.engine
            loadSubmissionGate.advance(to: playGeneration) { try? engine.stop() }
        }
        nowPlaying.updateRate(0, position: position)
        persistSession()
        // Ordinary pause is a resumable media session. On iOS deactivation
        // drops native eligibility and invalidates RemoteIO; on macOS it gives
        // up the route, which resume then has to win back. Keep it until
        // playback is abandoned (macOS lets go after 30 idle seconds anyway).
        if releaseAudioSession || loading {
            deactivateAudioSessionIfIdle()
        } else {
            debugLog.record("paused playback retains audio session active=\(AudioSessionManager.isActive)")
        }
    }

    func deactivateAudioSessionIfIdle() {
        let intent = resumeGeneration
        Task { [weak self] in
            guard let self, self.resumeGeneration == intent,
                  !self.isPlaying, !self.isBuffering else { return }
            await AudioSessionManager.deactivate()
            // A play/pause/load that landed *during* the deactivation wins:
            // the guard above ran before the await, so without this the call
            // pulls the session out from under a playing engine and strands
            // it on a dead unit — "paused, never reengages". Come back up
            // whenever the intent moved on or anything is audible.
            if self.isPlaying || self.isBuffering {
                let recoveryIntent = self.resumeGeneration
                let selection = self.playGeneration
                do {
                    _ = try await AudioSessionManager.activate()
                    if self.resumeGeneration == recoveryIntent, self.playGeneration == selection, self.isPlaying {
                        self.nowPlaying.requestPrimaryIfPossible(reason: "deactivation recovery")
                    }
                } catch {
                    guard self.resumeGeneration == recoveryIntent, self.playGeneration == selection else { return }
                    self.audioActivationFailed(error)
                }
            }
        }
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func advanceToNext(userInitiated: Bool) {
        if userInitiated { noteLocalIntent() }
        guard !queue.isEmpty else { return }
        let target: Int
        if let next = nextPlayableIndex(after: playingIndex) {
            target = next
        } else if userInitiated, playingIndex + 1 < queue.count {
            // Asked for by name: a stepped-over track still gets its ask.
            target = playingIndex + 1
        } else if repeatMode == .all {
            target = 0
        } else {
            return
        }
        // The upcoming track is armed while its predecessor plays
        // (syncEngineQueueNext), so a skip promotes it instantly instead of
        // re-resolving it over the network. Falls through to a full load
        // when nothing is armed.
        if trySkipToArmed(target) {
            if userInitiated {
                maybeAutoplay(force: true)
            } else {
                maybeAutoplay(lowWaterRefill: true)
            }
            return
        }
        loadCurrent(target, refreshAutoplay: userInitiated)
    }

    /// Promotes the engine's armed successor when it is the requested queue
    /// entry, and adopts it like a completed load. Returns false when nothing
    /// suitable is armed — the caller loads normally.
    ///
    /// The peek comes first because promoting has the side effect of moving
    /// the engine: only the picked track may be promoted, never whatever
    /// happens to be armed (repeat-one arms the current track itself).
    func trySkipToArmed(_ target: Int) -> Bool {
        // A paused/inactive output must take the load path, which awaits
        // activation. Instant promotion is reserved for an audible session.
        guard queue.indices.contains(target) else { return false }
        guard isPlaying else { return false }
        #if os(iOS)
        guard AudioSessionManager.isActive else { return false }
        #endif
        let entry = queue[target]
        guard let queued = engine.pendingTrack(),
              queued.title == entry.title, queued.artist == entry.artist
        else { return false }
        syncSkipMixEnabled()
        guard let info = try? engine.skipToPending() else {
            // Armed a moment ago but already consumed (a natural handoff may
            // have landed it meanwhile): if the queue is already there, the
            // work is done; otherwise load it properly.
            return current?.id == entry.id && engineLoadedId == entry.id
        }
        // The engine moved under a concurrent edit; converge on the target
        // with a full load rather than playing the wrong track.
        guard info.title == entry.title, info.artist == entry.artist else {
            loadCurrent(target, refreshAutoplay: false)
            return true
        }
        // Promoting an armed successor is a new selection too. Invalidate
        // outgoing loads/upgrades just as the full load path does.
        playGeneration &+= 1
        resumeGeneration &+= 1
        loadSubmissionGate.invalidate(to: playGeneration)
        // Ensure the promoted output is unmuted; this is idempotent for an
        // already playing session.
        do { try engine.play() } catch {
            loadCurrent(target, refreshAutoplay: false)
            return true
        }
        let headers = sourceHeadersByPath.removeValue(forKey: info.source) ?? [:]
        PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(position))
        loadDidSucceed(entry: entry, index: target, info: info, startAt: 0, headers: headers)
        VideoPlayback.shared.transportClockChanged()
        return true
    }

    func previous() {
        noteLocalIntent()
        if position > Self.backRestartsAfter {
            seek(to: 0)
            return
        }
        if playingIndex > 0 {
            loadCurrent(playingIndex - 1)
        } else if prependPreviousContextEntry() {
            loadCurrent(0)
        } else if repeatMode == .all, queue.count > 1 {
            loadCurrent(queue.count - 1)
        } else {
            seek(to: 0)
        }
    }

    func cycleRepeat() {
        let previous = repeatMode
        let next: RepeatMode
        switch previous {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        // Repeat-all loops the queue as it stands; AutoPlay's endless supply of
        // new tracks is the opposite, so they come out first (upstream
        // onRepeatModeChanged / stashAutoplayTracks). Leaving ALL — including
        // the step ALL→ONE — puts them back when the seed track is still current.
        if next == .all {
            stashAutoplayTracks()
        } else if previous == .all {
            restoreAutoplayTracks()
        }
        repeatMode = next
        autoplayRefresh.invalidate()
        persistSession()
        syncEngineQueueNext()
        maybeAutoplay(force: true)
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        applyListOrder()
    }

    /// Reorders only list slots. Played tracks, manual additions and the separate
    /// recommendation tail keep their places when playback mode changes.
    func applyListOrder() {
        queue = PlaybackQueuePolicy.orderList(
            queue, after: playingIndex, automix: automixSequencingEnabled,
            shuffle: shuffleEnabled, scores: tasteScores(queue)
        )
        queueEditRevision &+= 1
        persistSession()
        syncEngineQueueNext()
        scheduleSequencing()
    }

    func smartSequencingPreferenceChanged() {
        applyListOrder()
    }

    func seek(to requestedSeconds: Double) {
        guard requestedSeconds.isFinite else { return }
        var seconds = max(0, requestedSeconds)
        if duration > 0, duration.isFinite { seconds = min(seconds, duration) }
        noteLocalIntent()
        // Queues and returns: the playhead is the engine's to move, and waiting
        // for it here would stall whatever thread asked — usually the main one.
        guard engineLoadedId == current?.id, engineLoadedId != nil else { return }
        if seconds <= 0.1, position > Self.backRestartsAfter, isPlaying,
           let id = historyVideoID {
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(position))
            PlaybackTrackerBridge.shared.onPlaying(videoId: id)
        }
        if let dolbyRenderer { dolbyRenderer.seek(seconds) } else { engine.seek(seconds: seconds) }
        nowPlaying.update(position: seconds)
        position = seconds
        positionSampledAt = Date()
        VideoPlayback.shared.transportClockChanged()
        // Seeking can abandon the mixer's armed incoming voice. Re-arm the
        // already-local loop so the next EOS does not fall back to a cold load.
        if repeatMode == .one { syncEngineQueueNext() }
    }

    func removeFromQueue(at offsets: IndexSet) {
        let adjusted = offsets.filter { $0 != playingIndex && queue.indices.contains($0) }
        guard !adjusted.isEmpty else { return }
        let removedIds = Set(adjusted.map { queue[$0].id })
        queue.remove(atOffsets: IndexSet(adjusted))
        removedIds.forEach { QualityUpgrade.forget($0) }
        playingIndex -= adjusted.filter { $0 < playingIndex }.count
        playingIndex = min(playingIndex, max(0, queue.count - 1))
        queueEditRevision &+= 1
        persistSession()
        syncEngineQueueNext()
    }

    func removeFromQueue(at index: Int) {
        removeFromQueue(at: IndexSet(integer: index))
    }
}
