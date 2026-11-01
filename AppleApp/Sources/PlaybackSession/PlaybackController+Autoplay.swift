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

// Autoplay: recommendations, taste scores, Smart Sequencing and presence.
extension PlaybackController {
    /// The queue is a promise: once a recommendation is in it, it stays where
    /// it is until the listener plays, skips, moves or removes it. What the
    /// listener does — a skip, a like, a new pick — steers the *next* fill,
    /// because the next fill is seeded from whatever is playing then. It never
    /// rewrites the fill already shown.
    func maybeAutoplay(force: Bool = false, lowWaterRefill: Bool = false) {
        guard NetworkQuality.shared.connected else { return }
        if force {
            // A forced fill tops the tail up to its target; it does not replace it.
            guard PlaybackQueuePolicy.fillRoom(queue, after: playingIndex) > 0 else { return }
        }
        let due = force || (lowWaterRefill && PlaybackQueuePolicy.shouldRefillAutoplay(
            upcomingCount: queue.count - playingIndex - 1
        ))
        guard due else { return }
        guard let context = recommendationContext else {
            if autoplayEnabled {
                PlaybackDebugLog.shared.record(
                    "autoplay: no context (repeatAll=\(repeatMode == .all) state=\(state) youtube=\(current.flatMap { youtubeVideoID(for: $0) } != nil))",
                    about: current?.id
                )
            }
            return
        }
        guard let request = autoplayRefresh.begin(context, force: force) else { return }
        let videoId = String(context.source.dropFirst(3))
        PlaybackDebugLog.shared.record("autoplay: fill requested (force=\(force) count=\(queue.count) index=\(playingIndex))", about: current?.id)
        fetchRecommendations(videoId: videoId) { [weak self] json, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let json else {
                    PlaybackDebugLog.shared.record("autoplay: recommendations fetch returned nothing", about: videoId)
                    return
                }
                guard let currentContext = self.recommendationContext,
                      self.autoplayRefresh.accepts(request, current: currentContext) else {
                    let now = self.recommendationContext
                    let retry = self.autoplayRefresh.shouldRetry(request)
                    PlaybackDebugLog.shared.record(
                        "autoplay: fill discarded (state=\(self.state) context=\(now != nil) source=\(now?.source == context.source) index=\(now?.index == context.index) playGen=\(now?.playbackGeneration == context.playbackGeneration) queueRev=\(now?.queueEditRevision == context.queueEditRevision) session=\(now?.sessionGeneration == context.sessionGeneration)) retry=\(retry)",
                        about: videoId
                    )
                    if retry {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(2))
                            self?.maybeAutoplay(force: true)
                        }
                    }
                    return
                }
                // Fills only ever append. Anything already queued — list rows,
                // the listener's own additions, earlier recommendations — keeps
                // its place.
                let kept = self.queue
                guard kept.indices.contains(self.playingIndex) else { return }
                let room = PlaybackQueuePolicy.fillRoom(kept, after: self.playingIndex)
                guard room > 0 || !force else { return }
                // QueueBuilder reads the final existing entry as the station seed.
                // Its filtering snapshot ends with the current song; actual queue
                // positions and manual/list priority are unchanged.
                let filteringEntries = kept.enumerated().filter { $0.offset != self.playingIndex }.map(\.element) + [kept[self.playingIndex]]
                let existing = (try? JSONEncoder().encode(filteringEntries.map { $0.asSongJSON(videoIDOverride: self.youtubeVideoID(for: $0)) }))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let extraJson = QueueBuilderBridge.shared.extendJson(
                    existingJson: existing, candidatesJson: json,
                    limit: Int32(max(room, PlaybackQueuePolicy.autoplayRefillThreshold))
                )
                guard let data = extraJson.data(using: .utf8),
                      let songs = try? JSONDecoder().decode([SongDTO].self, from: data) else {
                    PlaybackDebugLog.shared.record("autoplay: queue builder returned unreadable JSON", about: videoId)
                    return
                }
                var known = Set(kept.map(\.id))
                let extras = songs.filter { known.insert($0.videoId).inserted }.map {
                    QueueEntry.youtube(
                        videoId: $0.videoId, title: $0.title, artist: $0.artist,
                        thumbnailUrl: $0.thumbnailUrl, durationText: $0.durationText,
                        albumName: $0.albumName, artistId: $0.artistId, albumId: $0.albumId,
                        fromAutoplay: true
                    )
                }
                // Ordered by taste once, as a batch, before anyone has seen it.
                let scores = self.tasteScores(extras)
                let ordered = PlaybackQueuePolicy.ranked(Array(extras.indices), scores: scores).map { extras[$0] }
                PlaybackDebugLog.shared.record("autoplay: \(songs.count) candidates, \(ordered.count) appended (room=\(room))", about: videoId)
                guard !ordered.isEmpty else { return }
                self.autoplayRefresh.noteFilled()
                self.queue = PlaybackQueuePolicy.appendingFill(kept, extras: ordered)
                self.persistSession()
                self.syncEngineQueueNext()
                self.scheduleSequencing()
            }
        }
    }

    private func fetchRecommendations(videoId: String, response: @escaping (String?, String?) -> Void) {
        #if DEBUG
        if let recommendationFetchOverride { recommendationFetchOverride(videoId, response); return }
        #endif
        AutoPlayBridge.shared.related(videoId: videoId, callback: AutoPlayAdapter(response))
    }

    func tasteScores(_ entries: [QueueEntry], transitionFits: [Int: Double] = [:]) -> [Double] {
        let taste = ListeningStore.shared.summary(includeGenres: true)
        let lastPlayed = ListeningStore.shared.lastPlayedByTrack()
        let now = Date().timeIntervalSince1970 * 1000
        return entries.enumerated().map { index, entry in
            let primaryArtist = ListeningStore.primaryArtist(entry.artist) ?? entry.artist
            let artistRank = taste.artists.firstIndex {
                $0.name.caseInsensitiveCompare(primaryArtist) == .orderedSame
            }
            let artistAffinity = artistRank.map { max(0, 1.0 - Double($0) / 10.0) } ?? 0
            let artistGenres = ListeningStore.shared.knownGenres[primaryArtist] ?? []
            let genreRank = taste.genres.firstIndex { genre in
                artistGenres.contains { $0.caseInsensitiveCompare(genre.name) == .orderedSame }
            }
            let genreAffinity = genreRank.map { max(0, 1.0 - Double($0) / 10.0) } ?? 0
            return PlaybackQueuePolicy.score(
                transitionFit: transitionFits[index], affinity: max(artistAffinity, genreAffinity),
                playedAt: lastPlayed[entry.id], now: now
            )
        }
    }

    /// Re-sequence one bounded list window and settle each recommendation batch.
    func scheduleSequencing() {
        sequencingTask?.cancel()
        sequencingGeneration &+= 1
        guard automixSequencingEnabled, let current else { return }
        let generation = sequencingGeneration
        let snapshot = queue
        let index = playingIndex
        let playbackGeneration = playGeneration
        let sessionGeneration = PageSession.generation()
        let currentPath = loadedSourcePath
        let fade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        let skipVocals = automixPerformanceMode == "EFFICIENT"
        let listPositions = PlaybackQueuePolicy.rollingListWindow(snapshot, after: index)
        let autoplayPositions = PlaybackQueuePolicy.autoplayIndices(snapshot, after: index).filter {
            $0 > index + PlaybackQueuePolicy.committedRows && !settledAutoplayIds.contains(snapshot[$0].id)
        }
        guard listPositions.count > 1 || autoplayPositions.count > 1 else { return }
        // Taste/freshness is the fallback and stable tie-break. Sequencing never
        // resolves a stream: it analyzes only local or completed cached files.
        let fallback = tasteScores(snapshot)
        sequencingTask = Task(priority: .utility) { [weak self] in
            var transitionFits: [Int: Double] = [:]
            var analyzedChain: [Int] = []
            var analyzedTracks = 0
            var analyzedBytes: Int64 = 0
            var skippedForBudget = 0
            let analysisByteBudget: Int64 = 512 * 1024 * 1024

            if let currentPath, FileManager.default.fileExists(atPath: currentPath), listPositions.count > 1 {
                var candidates: [(position: Int, path: String, text: String)] = []
                for position in PlaybackQueuePolicy.ranked(listPositions, scores: fallback) {
                    if Task.isCancelled { return }
                    let entry = snapshot[position]
                    let path: String?
                    if entry.isLocal, FileManager.default.fileExists(atPath: entry.source) {
                        path = entry.source
                    } else if entry.source.hasPrefix("yt:"), let id = entry.videoId {
                        path = await StreamFileCache.shared.path(for: id, allowGrowing: false)
                    } else {
                        path = nil
                    }
                    guard let path, FileManager.default.fileExists(atPath: path),
                          let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber else { continue }
                    let bytes = size.int64Value
                    guard bytes > 0, bytes <= analysisByteBudget - analyzedBytes else {
                        skippedForBudget += 1
                        continue
                    }
                    analyzedBytes += bytes
                    candidates.append((position, path, entry.itemText))
                }

                analyzedTracks = candidates.count
                var remaining = candidates
                var previousPath = currentPath
                var previousText = current.itemText
                while !remaining.isEmpty {
                    if Task.isCancelled { return }
                    let ranked = await AutomixQueueRanker.shared.rank(
                        currentPath: previousPath,
                        candidatePaths: remaining.map(\.path),
                        currentText: previousText,
                        candidateTexts: remaining.map(\.text),
                        crossfadeSeconds: fade, skipVocals: skipVocals
                    )
                    var rankOrder: [Int] = []
                    for raw in ranked {
                        let candidateIndex = Int(raw)
                        guard remaining.indices.contains(candidateIndex) else { continue }
                        rankOrder.append(candidateIndex)
                    }
                    guard let selectedIndex = rankOrder.first else { break }
                    let selected = remaining.remove(at: selectedIndex)
                    analyzedChain.append(selected.position)
                    previousPath = selected.path
                    previousText = selected.text
                }
            }

            if let currentPath, FileManager.default.fileExists(atPath: currentPath) {
                for positions in [Array(autoplayPositions.prefix(12))] {
                    var paths: [String] = []
                    var texts: [String] = []
                    var available: [Int] = []
                    for position in positions {
                        if Task.isCancelled { return }
                        let entry = snapshot[position]
                        let path: String?
                        if entry.isLocal, FileManager.default.fileExists(atPath: entry.source) {
                            path = entry.source
                        } else if entry.source.hasPrefix("yt:"), let id = entry.videoId {
                            path = await StreamFileCache.shared.path(for: id)
                        } else { path = nil }
                        if let path, FileManager.default.fileExists(atPath: path) {
                            paths.append(path)
                            texts.append(entry.itemText)
                            available.append(position)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    if paths.count > 1 {
                        let ranked = await AutomixQueueRanker.shared.rank(
                            currentPath: currentPath, candidatePaths: paths,
                            currentText: current.itemText, candidateTexts: texts,
                            crossfadeSeconds: fade, skipVocals: skipVocals
                        )
                        for (rank, value) in ranked.enumerated() {
                            let candidate = Int(value)
                            if available.indices.contains(candidate) {
                                transitionFits[available[candidate]] = 1 - Double(rank) / Double(max(1, available.count - 1))
                            }
                        }
                    }
                }
            }
            if !listPositions.isEmpty {
                PlaybackDebugLog.shared.record(
                    "AutoMix list window rows=\(listPositions.count) analyzedTracks=\(analyzedTracks) candidateBytes=\(analyzedBytes) networkBytes=0 budgetSkipped=\(skippedForBudget)"
                )
            }
            guard let self, !Task.isCancelled, self.sequencingGeneration == generation,
                  self.automixSequencingEnabled, self.queue == snapshot, self.playingIndex == index,
                  self.playGeneration == playbackGeneration, self.current?.id == current.id,
                  PageSession.generation() == sessionGeneration else { return }
            self.settledAutoplayIds.formUnion(autoplayPositions.map { snapshot[$0].id })
            let scores = transitionFits.isEmpty ? fallback : self.tasteScores(snapshot, transitionFits: transitionFits)
            var ordered = snapshot
            let analyzedPositions = analyzedChain.sorted()
            ordered = PlaybackQueuePolicy.replacing(
                ordered, at: analyzedPositions, with: analyzedChain.map { snapshot[$0] }
            )
            ordered = PlaybackQueuePolicy.replacing(
                ordered, at: autoplayPositions,
                with: PlaybackQueuePolicy.ranked(autoplayPositions, scores: scores).map { snapshot[$0] }
            )
            guard ordered != self.queue else { return }
            self.queue = ordered
            self.persistSession()
            self.syncEngineQueueNext()
        }
    }

    /// Clears AutoPlay's tail for the duration of repeat-all, keeping it to put back.
    func stashAutoplayTracks() {
        if !repeatAllStash.isEmpty { return }
        let seed = current?.id
        var kept: [QueueEntry] = []
        var dropped: [QueueEntry] = []
        for (i, entry) in queue.enumerated() {
            // Never pull the playing item or anything before it out of the loop.
            if i <= playingIndex || !entry.fromAutoplay {
                kept.append(entry)
            } else {
                dropped.append(entry)
            }
        }
        guard !dropped.isEmpty else { return }
        queue = kept
        repeatAllStash = dropped
        repeatAllStashSeed = seed
        persistSession()
    }

    /// Puts the stashed AutoPlay tracks back when repeat-all ends.
    func restoreAutoplayTracks() {
        let stashed = repeatAllStash
        let seed = repeatAllStashSeed
        repeatAllStash = []
        repeatAllStashSeed = nil
        guard !stashed.isEmpty, autoplayEnabled else { return }
        guard current?.id == seed else { return }
        let present = Set(queue.map(\.id))
        let restored = stashed.filter { !present.contains($0.id) }
        guard !restored.isEmpty else { return }
        queue.append(contentsOf: restored)
        persistSession()
    }

    private struct SongDTO: Codable {
        let videoId: String
        let title: String
        let artist: String
        let thumbnailUrl: String?
        let durationText: String?
        let albumName: String?
        let artistId: String?
        let albumId: String?
    }

    func publishPresence() {
        guard PlatformSettings.shared.getBoolean(key: "discord_rpc_enabled", default: true) else { return }
        guard let current else { return }
        let speed = PlatformSettings.shared.getFloat(key: "playback_speed", default: 1)
        let videoId = current.source.hasPrefix("yt:") ? String(current.source.dropFirst(3)) : nil
        DiscordGateway.shared.updatePresence(
            title: current.title, artist: current.artist, album: current.albumName,
            positionMs: Swift.Int64(position * 1000), durationMs: Swift.Int64(duration * 1000),
            speed: speed, videoId: videoId
        )
    }

    // ---- Quality upgrade / Automix UI state ---------------------------------
}
