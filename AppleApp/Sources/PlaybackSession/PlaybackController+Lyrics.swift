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

// Lyrics: fetching, providers, per-track choice and alignment.
extension PlaybackController {
    func fetchLyrics(for entry: QueueEntry) {
        lyricsAlignmentTask?.cancel()
        lyricsAlignmentTask = nil
        lyricsAligning = false
        lyricsAlignedLocally = nil
        lyricsRequestGeneration &+= 1
        let requestGeneration = lyricsRequestGeneration
        lyricsNeedsDurationRefresh = false
        lyrics = []
        lyricsSourceLabel = nil
        // The picker starts from zero with the track: upstream resets the state
        // map whenever a new lookup begins.
        lyricsProviderStates = [:]
        lyricsProviderResults = [:]
        lyricsProviderChoice = Self.storedProviderChoice(for: entry.id)
        // Cleared rather than set: a new track has not been looked up yet, and a
        // stale "there are none" from the previous one would say so about this
        // one before anyone had asked.
        attemptedLyrics = false
        // A translation belongs to the lyric it was made from. Carrying it across
        // a track change would show one song's words over another's music, which is
        // worse than having no translation at all.
        lyricsTranslator.reset()
        // A remote library's file is "local" in the sense that it needs no download,
        // but its `source` is an `https` address and cannot be opened for tags. Asking
        // again here is what keeps a remote row from trying to read a URL as a file.
        let localPath = entry.isLocal && !entry.source.isEmpty && !entry.source.hasPrefix("http")
            ? entry.source
            : nil
        let allowNetwork = PlatformSettings.shared.getBoolean(key: "synced_lyrics", default: true)
        if !allowNetwork, localPath == nil {
            // Not a search that found nothing — a search that was never going to
            // be made, because the listener has lyrics off. "Unavailable" would
            // be a lie; the strip says nothing was looked for.
            lyricsLoading = false
            attemptedLyrics = true
            return
        }
        lyricsLoading = true
        // Compare provider timelines with the decoded audio that is playing.
        // Queue metadata can describe a longer video upload or another edition.
        let knownDuration = duration > 0 ? duration : entry.durationSeconds
        let durationMs = Swift.Int64(knownDuration * 1000)
        lyricsNeedsDurationRefresh = durationMs <= 0
        LyricsBridge.shared.fetchWithSourceStates(
            title: entry.title,
            artist: entry.artist,
            durationMs: durationMs,
            album: entry.albumName,
            videoId: entry.videoId,
            localPath: localPath,
            callback: AttributedLyricsAdapter { [weak self] _, label, lines in
                Task { @MainActor in
                    guard let self,
                          self.current?.id == entry.id,
                          self.lyricsRequestGeneration == requestGeneration
                    else { return }
                    // The listener's choice outranks the race: when both the
                    // winner and the chosen source have lines, the chosen one
                    // is what this track sings.
                    let chosen = self.lyricsProviderChoice
                    if let chosen, chosen != label,
                       let chosenLines = self.lyricsProviderResults[chosen], !chosenLines.isEmpty {
                        self.applyLyrics(chosenLines, label: chosen, entry: entry, generation: requestGeneration)
                        return
                    }
                    self.applyLyrics(lines, label: label, entry: entry, generation: requestGeneration)
                }
            },
            onSourceState: SourceStateAdapter { [weak self] source, label, state, lines in
                Task { @MainActor in
                    guard let self,
                          self.current?.id == entry.id,
                          self.lyricsRequestGeneration == requestGeneration
                    else { return }
                    self.lyricsProviderStates[source] = LyricsSourceState(state)
                    if let lines, !lines.isEmpty {
                        self.lyricsProviderResults[source] = lines
                    }
                }
            }
        )
    }

    /// One place for what a finished lookup does, so the race's winner and the
    /// listener's choice land the same way.
    private func applyLyrics(
        _ lines: [LyricLineDto],
        label: String,
        entry: QueueEntry,
        generation: UInt64
    ) {
        lyrics = lines
        lyricsSourceLabel = label.isEmpty ? nil : label
        lyricsLoading = false
        // The search finished either way, which is what the deck's
        // strip reads to tell "none" apart from "looking".
        attemptedLyrics = true
        alignFetchedLyricsIfNeeded(
            lines,
            for: entry,
            requestGeneration: generation
        )
    }

    /// Applies a FOUND source the listener tapped, instantly, from the lines
    /// the race already brought back — upstream's `showLyricsResult` — and
    /// remembers the choice for this track across devices.
    func selectLyricsProvider(named source: String) {
        guard let lines = lyricsProviderResults[source], !lines.isEmpty,
              let entry = current else { return }
        lyricsProviderChoice = source
        Self.storeProviderChoice(source, for: entry.id)
        lyricsRequestGeneration &+= 1
        applyLyrics(lines, label: source, entry: entry, generation: lyricsRequestGeneration)
    }

    // MARK: Per-track provider choice (O1)

    /// Provider choices sync through iCloud KVS and fall back to local defaults
    /// when cloud data is not available on this device.
    private static let lyricsChoiceStore: any LyricsChoiceStore = UbiquitousLyricsChoiceStore()

    private static func storedProviderChoice(for videoId: String) -> String? {
        lyricsChoiceStore.choice(for: videoId)
    }

    private static func storeProviderChoice(_ source: String, for videoId: String) {
        lyricsChoiceStore.remember(source, for: videoId)
    }

    /// Fill in missing word timestamps in the background. The fetched text stays
    /// the authority; local speech recognition only contributes candidate word
    /// times, and the shared aligner rejects transcript words that do not match.
    func alignFetchedLyricsIfNeeded(
        _ lines: [LyricLineDto],
        for entry: QueueEntry,
        requestGeneration: UInt64
    ) {
        guard lines.contains(where: { !$0.isGap && $0.words.isEmpty }),
              let source = loadedSourcePath,
              !source.isEmpty
        else { return }

        let trackDuration = duration > 0 ? duration : entry.durationSeconds
        guard trackDuration > 0 else { return }
        let engine = self.engine
        let headers = loadedSourceHeaders
        let decode: LyricsAudioAligner.Decode = { start, length in
            // 16 kHz is what speech recognition takes; bytes cross the bridge
            // in one copy where a float array is read back one at a time.
            guard let region = engine.decodeRegionPcm(
                source: source,
                startSeconds: start,
                durationSeconds: length,
                headers: headers,
                targetRate: 16_000
            ) else { return nil }
            let count = region.pcm.count / MemoryLayout<Float>.size
            let samples = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                region.pcm.withUnsafeBytes { raw in
                    UnsafeMutableRawBufferPointer(buffer).copyMemory(
                        from: UnsafeRawBufferPointer(rebasing: raw.prefix(count * MemoryLayout<Float>.size))
                    )
                }
                initialized = count
            }
            return LyricsAudioAligner.Region(
                samples: samples,
                sampleRate: Double(region.sampleRate),
                startSeconds: region.startSeconds
            )
        }

        lyricsAligning = true
        lyricsAlignmentTask = Task { @MainActor [weak self] in
            let coverage = await LyricsAudioAligner.align(
                lines: lines,
                durationSeconds: trackDuration,
                decode: decode,
                playhead: { [weak self] in self?.position ?? 0 },
                onUpdate: { [weak self] updated in
                    guard let self,
                          self.current?.id == entry.id,
                          self.lyricsRequestGeneration == requestGeneration
                    else { return }
                    self.lyrics = updated
                }
            )
            MemoryRelief.soon()
            guard let self,
                  self.current?.id == entry.id,
                  self.lyricsRequestGeneration == requestGeneration
            else { return }
            self.lyricsAligning = false
            // The mark is the honest one: it says the word timings came from
            // this app's ears, not the provider's, so a listener who finds a
            // badly-synced line knows whom to tell.
            self.lyricsAlignedLocally = coverage
            self.lyricsAlignmentTask = nil
            PlaybackDebugLog.shared.record(
                "lyrics: local alignment timed \(coverage.timed) of \(coverage.total) lines",
                about: entry.id
            )
        }
    }
}
