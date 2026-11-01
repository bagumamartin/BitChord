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

// Engine callbacks: state, handoffs, track ends, durations and errors.
extension PlaybackController {
    func handleState(_ newState: PlaybackState) {
        guard dolbyRenderer == nil else { return }
        // A load callback can arrive from the outgoing voice after the listener
        // has already selected another track. Its load result is discarded by
        // the generation gate; don't let its state callback relabel the new
        // selection as playing while that selection is still buffering.
        if state == .buffering && (newState == .playing || newState == .stopped) { return }
        // A stale natural-end/stop for a superseded source must not wipe the
        // new selection either; the gate owns that call.
#if os(iOS)
        // Transport intent is updated synchronously. Rust delivers Play/Pause
        // acknowledgments later; an older acknowledgment must not reverse a
        // newer tap or publish a contradictory native button state.
        if (state == .paused && newState == .playing)
            || (state == .playing && newState == .paused) { return }
#endif
        if state == .paused && newState == .stopped { return }
        state = newState
        if let current {
            nowPlaying.update(
                id: current.id, title: current.title, artist: current.artist,
                duration: duration, artworkData: current.artworkData,
                thumbnailUrl: current.thumbnailUrl,
                isPlaying: newState == .playing
            )
        }
        widgetPublisher.publish(entry: current, isPlaying: newState == .playing,
                                canNext: canPlayNext, canPrevious: canPlayPrevious)
        if newState == .stopped {
            nowPlaying.stop()
        }
        if newState == .paused { persistSession() }
    }

    func handleHandoff(_ info: TrackInfoRec) {
        // The engine flipped to the incoming track. Trust-but-verify: the
        // mixer only arms what the gated queueNext asked for, but a manual
        // skip promotes on reply and flips the index itself, so a handoff
        // that follows it (or one from a superseded arm) must not advance
        // the queue a second time.
        if repeatMode != .one {
            if let next = nextEntry, info.title == next.title, info.artist == next.artist,
               sourceHeadersByPath[info.source] != nil {
                // The expected advance — fall through to the index logic.
            } else if let current, info.title == current.title, info.artist == current.artist {
                // Already here: adopt the authoritative path/headers and stop.
                // This is the skip path's own handoff arriving after the reply
                // already flipped the queue, or a duplicate delivery.
                loadedSourcePath = info.source
                if let headers = sourceHeadersByPath.removeValue(forKey: info.source) {
                    loadedSourceHeaders = headers
                }
                if info.durationSeconds > 0 { duration = info.durationSeconds }
                return
            } else {
                // A stale voice from a superseded arm (e.g. a blend abandoned
                // by a manual skip). Acting on it would move or stop the wrong
                // track.
                NSLog("[BitChord] ignoring handoff for untracked voice %@ — %@", info.title, info.artist)
                return
            }
        }
        // The engine flipped to the incoming track. Repeat-one with Automix is
        // a self-mix: stay on the same queue item. Repeat-all wrap lands on 0.
        if repeatMode == .one {
            // Same song again — count the lap like upstream REASON_REPEAT.
        } else if let next = nextPlayableIndex(after: playingIndex) {
            // The armed track, which is the next one not stepped over.
            playingIndex = next
        } else if repeatMode == .all, !queue.isEmpty {
            playingIndex = 0
        } else {
            return
        }
        let outgoingPosition = position
        let sameSong = current?.id == queue[playingIndex].id
        autoplayRefresh.invalidate()
        current = queue[playingIndex]
        if let current { streamRecovery.select(current.id, resetAttempts: true) }
        historyVideoID = current.flatMap(youtubeVideoID)
        duration = info.durationSeconds
        position = 0
        if let entry = current {
            if !sameSong {
                refreshArtwork(entry)
                fetchLyrics(for: entry)
                fetchCanvas(for: entry)
            }
            nerd = dolbyRenderer?.nerd ?? engine.nerdStats()
            racingLossless = QualityUpgrade.isRacing(entry.id)
            scrobbleArmed = false
            scrobbleSent = false
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(outgoingPosition))
            if let id = historyVideoID {
                QueueBuilderBridge.shared.rememberPlayed(videoId: id)
                PlaybackTrackerBridge.shared.onPlaying(videoId: id)
            }
            publishPresence()
            nowPlaying.update(
                id: entry.id, title: entry.title, artist: entry.artist,
                duration: info.durationSeconds, artworkData: entry.artworkData,
                thumbnailUrl: entry.thumbnailUrl, isPlaying: isPlaying, position: position
            )
            engineLoadedId = entry.id
            loadedSourcePath = info.source
            loadedSourceHeaders = sourceHeadersByPath.removeValue(forKey: info.source) ?? [:]
            beginSmartMixIfNeeded()
            if dolbyRenderer == nil { lookForBetterCopy(entry, codec: info.codec, kbps: info.kbps) }
        }
        persistSession()
        syncEngineQueueNext()
        scheduleSequencing()
        maybeAutoplay(lowWaterRefill: true)
    }

    func handleTrackEnded(_ reason: TrackEndReason, source: String) {
        guard state != .paused else { return }
        if reason == .error {
            _ = recoverInterruptedStream(source: source, explanation: "The audio decoder stopped; requesting a fresh stream at the same position.")
            return
        }
        guard reason == .natural else { return }
        // A natural end for a voice the transport already left (manual skip,
        // or a blend that already handed off) must not move or stop the new
        // selection. Empty source keeps backward compatibility with callers
        // that do not report one.
        if !source.isEmpty, let loaded = loadedSourcePath, loaded != source { return }
        if resumeAfterFailedDownload(source: source.isEmpty ? loadedSourcePath : source) { return }
        if historyVideoID != nil {
            PlaybackTrackerBridge.shared.onPlaybackFinished(positionSeconds: Int64(position))
        }
        if sleepAfterTrack {
            sleepAfterTrack = false
            pausePlayback(releaseAudioSession: true)
            try? engine.holdTrackEnd(hold: false)
            try? engine.setSleepGain(gain: 1)
            return
        }
        if let current, !scrobbleSent {
            ScrobbleBridge.shared.scrobble(
                artist: scrobbleArtist(for: current), title: current.title, album: current.albumName,
                durationSec: Swift.Int32(duration)
            )
            scrobbleSent = true
        }
        // Source validation above excludes the outgoing voice after a handoff.
        // If the current voice reaches EOS, prefetch may have failed or not
        // finished. Advance with a fresh load instead of assuming it was armed.
        PlaybackDebugLog.shared.record("natural end without handoff; index=\(playingIndex) count=\(queue.count)", about: current?.id)
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        switch repeatMode {
        case .one:
            // Automix self-mix should have handed off before EOS. A natural end
            // here means the blend never armed — reopen rather than sit stopped
            // (the previous seek-after-EOF path left the decoder finished).
            restartCurrentAfterNaturalEnd()
        case .all:
            dolbyRenderer?.stop()
            dolbyRenderer = nil
            engineLoadedId = nil
            advanceToNext(userInitiated: false)
        case .off:
            if let next = nextPlayableIndex(after: playingIndex) {
                automaticLoadEntryId = queue[next].id
                loadCurrent(next, refreshAutoplay: false)
                return
            }
            state = .stopped
            position = 0
            nowPlaying.updateRate(0.0, position: 0)
            nowPlaying.stop()
            deactivateAudioSessionIfIdle()
        }
    }

    /// A "natural end" that is really a download that gave up part-way (the
    /// bridge leaves `.failed` beside the file). Reload the same track at the
    /// same position — a fresh resolve, so a fresh URL — instead of moving on
    /// as if the song had finished. Once per track, so a source that keeps
    /// failing still lets the queue advance.
    private func resumeAfterFailedDownload(source: String?) -> Bool {
        guard let source else { return false }
        let failures = engine.drainSourceErrors()
        let failed = FileManager.default.fileExists(atPath: source + ".failed") || failures.contains { $0.source == source }
        guard failed else { return false }
        return recoverInterruptedStream(source: source, explanation: "Playback was interrupted; requesting a fresh stream at the same position.")
    }

    /// Reopen the current queue item after a natural end. Seeking a finished
    /// voice after the mixer has drained often fails to produce audio again;
    /// a fresh load is what actually loops without Automix.
    private func restartCurrentAfterNaturalEnd() {
        guard queue.indices.contains(playingIndex) else { return }
        let index = playingIndex
        scrobbleArmed = false
        scrobbleSent = false
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        loadCurrent(index, refreshAutoplay: false, reuseCurrentSource: true)
    }

    /// Reuse the selected recording rather than resolving a new rendition at EOS.
    func repeatableCurrentSource() -> ResolvedSource? {
        guard let source = loadedSourcePath, source.hasPrefix("/"),
              FileManager.default.fileExists(atPath: source),
              !FileManager.default.fileExists(atPath: source + ".failed"),
              !FileManager.default.fileExists(atPath: source + ".playback-cancelled") else { return nil }
        return ResolvedSource(source: source, headers: loadedSourceHeaders,
            kbps: Int(nerd?.kbps ?? 0), lossless: QualityUpgrade.Format.isLosslessCodec(nerd?.codec), codec: nerd?.codec,
            durationSec: duration > 0 ? Int(duration.rounded()) : nil,
            loudnessDb: currentLoudnessDb, origin: resolvedOrigin[current?.id ?? ""] ?? .cache,
            youtubeVideoId: historyVideoID)
    }

    func handleDuration(_ seconds: Double) {
        duration = seconds
        publishSmartWindow()
        // The lyric lookup may have gone out before the container said how long
        // the track is — the one field that lets most of these providers choose
        // between takes — and a lookup made blind is not evidence that there are
        // no lyrics. Upstream defers and re-runs on the length; so does this.
        if lyricsNeedsDurationRefresh, seconds > 0, let entry = current {
            lyricsNeedsDurationRefresh = false
            fetchLyrics(for: entry)
        }
    }

    /// Look again for the track that is playing.
    ///
    /// The "Change" sheet edits *which* sources are enabled and in what order,
    /// and those settings only ever applied to the next track: nothing re-ran
    /// the lookup for the one on screen, so a wrong or missing lyric could not
    /// be fixed from the player at all — the only way was to disable sources
    /// globally and play the track again. Upstream has a per-track provider
    /// picker for this; re-running with the settings the listener just changed
    /// is the part that makes those settings mean something.
    func refetchLyrics() {
        guard let entry = current else { return }
        fetchLyrics(for: entry)
    }

    func handleError(_ message: String) {
        lastError = message
        if let id = current?.id, QualityUpgrade.forcedStream(id) != nil {
            QualityUpgrade.refuseUpgrades(id)
            debugLog.record("broke on its upgrade; no more swaps", about: id)
        }
    }

    /// The track that plays after this one, for work done ahead of it (the
    /// music video is found and lined up while this track plays).
    var upNextEntry: QueueEntry? { nextEntry }

    /// The first index after [index] whose track has not just failed every way
    /// of playing it, or nil past the end of the queue.
    func nextPlayableIndex(after index: Int) -> Int? {
        let now = Date()
        return queue.indices.first { $0 > index && (unplayableUntil[queue[$0].id] ?? .distantPast) <= now }
    }

    /// Steps the queue over [entry] for ten minutes, upstream's window for a
    /// track that refused every ask. A failure while offline, or behind
    /// YouTube's bot check, says nothing about the track, so it is not held
    /// against it.
    @discardableResult
    func markUnplayable(_ entry: QueueEntry, after error: Error) -> Bool {
        guard NetworkQuality.shared.connected else { return false }
        let nsError = error as NSError
        let message = error.localizedDescription
        guard nsError.domain != NSURLErrorDomain,
              !InnertubeStreamResolver.StreamError.isBotCheck(error),
              !message.localizedCaseInsensitiveContains("offline"),
              !message.localizedCaseInsensitiveContains("network connection") else { return false }
        unplayableUntil = unplayableUntil.filter { $0.value > Date() }
        unplayableUntil[entry.id] = Date().addingTimeInterval(600)
        return true
    }

    var nextEntry: QueueEntry? {
        if repeatMode == .one {
            // Automix: blend the track into itself. Without Automix there is no
            // engine next — EOS reopens the same item.
            return automixEnabled ? current : nil
        }
        if let next = nextPlayableIndex(after: playingIndex) { return queue[next] }
        // Including a one-item queue: Media3 wrap under REPEAT_ALL points next
        // at the same index, which is how a single track on repeat-all self-mixes.
        if repeatMode == .all, !queue.isEmpty { return queue[0] }
        return nil
    }
}
