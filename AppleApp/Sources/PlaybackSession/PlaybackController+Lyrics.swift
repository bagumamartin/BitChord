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
        lyricsAlignedLocally = false
        lyricsAlignmentState = .idle
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
        lyricsAlignmentTask?.cancel()
        lyricsAlignmentTask = nil
        lyricsAligning = false
        lyricsAlignedLocally = false
        lyricsAlignmentState = .idle
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
        requestGeneration: UInt64,
        allowPermissionRequest: Bool = false,
        useCache: Bool = true
    ) {
        guard lines.contains(where: { !$0.isGap && $0.words.isEmpty }),
              let source = loadedSourcePath,
              !source.isEmpty
        else { lyricsAlignmentState = .idle; return }

        let trackDuration = duration > 0 ? duration : entry.durationSeconds
        guard trackDuration > 0 else { lyricsAlignmentState = .audioUnavailable; return }
        let sourceURL = URL(fileURLWithPath: source)
        let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceIdentity = [
            sourceURL.standardizedFileURL.path,
            String(describing: sourceAttributes?[.size] ?? "unknown-size"),
            String(describing: sourceAttributes?[.modificationDate] ?? "unknown-date")
        ].joined(separator: "|")
        let cacheKey = LyricsAlignmentCache.key(
            trackId: entry.id, provider: lyricsSourceLabel, source: sourceIdentity, lines: lines
        )
        if useCache, let cached = LyricsAlignmentCache.value(for: cacheKey) {
            lyrics = cached
            lyricsAlignedLocally = true
            lyricsAlignmentState = cached.contains(where: { !$0.isGap && $0.words.isEmpty }) ? .partial : .complete
            return
        }
        let engine = self.engine
        let headers = loadedSourceHeaders
        let decode: LyricsAudioAligner.Decode = { start, length in
            guard let region = engine.decodeRegionWithHeaders(
                source: source,
                startSeconds: start,
                durationSeconds: length,
                mono: true,
                headers: headers
            ) else { return nil }
            return LyricsAudioAligner.Region(
                samples: region.samples,
                sampleRate: Double(region.sampleRate),
                startSeconds: region.startSeconds
            )
        }

        lyricsAligning = true
        lyricsAlignmentState = .analyzing
        lyricsAlignmentTask = Task { @MainActor [weak self] in
            let outcome = await LyricsAudioAligner.align(
                lines: lines,
                durationSeconds: trackDuration,
                decode: decode,
                allowPermissionRequest: allowPermissionRequest,
                onState: { [weak self] state in
                    guard let self,
                          !Task.isCancelled,
                          self.current?.id == entry.id,
                          self.lyricsRequestGeneration == requestGeneration
                    else { return }
                    self.lyricsAlignmentState = state
                },
                onUpdate: { [weak self] updated in
                    guard let self,
                          !Task.isCancelled,
                          self.current?.id == entry.id,
                          self.lyricsRequestGeneration == requestGeneration
                    else { return }
                    self.lyrics = updated
                }
            )
            guard let self,
                  !Task.isCancelled,
                  self.current?.id == entry.id,
                  self.lyricsRequestGeneration == requestGeneration
            else { return }
            self.lyricsAligning = false
            // The mark is the honest one: it says the word timings came from
            // this app's ears, not the provider's, so a listener who finds a
            // badly-synced line knows whom to tell.
            self.lyricsAlignedLocally = outcome == .complete || outcome == .partial
            self.lyricsAlignmentState = outcome
            if outcome == .complete || outcome == .partial {
                LyricsAlignmentCache.insert(self.lyrics, for: cacheKey)
            }
            self.lyricsAlignmentTask = nil
            NSLog("[BitChord] local lyric alignment %@ for %@",
                  outcome == .complete || outcome == .partial ? "added word timings" : "alignment did not complete",
                  entry.title)
        }
    }

    func retryLyricsAlignment() {
        guard let entry = current, !lyrics.isEmpty else { return }
        lyricsAlignmentTask?.cancel()
        lyricsAlignmentTask = nil
        lyricsAligning = false
        lyricsAlignedLocally = false
        lyricsAlignmentState = .idle
        alignFetchedLyricsIfNeeded(
            lyrics,
            for: entry,
            requestGeneration: lyricsRequestGeneration,
            allowPermissionRequest: true,
            useCache: false
        )
    }
}
