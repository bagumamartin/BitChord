import Foundation

/// Where a song's moments fall in its music video, for the video toggle.
///
/// A music video is rarely the song's cut: "Money" opens 3.7 s earlier and
/// stops for an 11.6 s interlude at 1:23. One clock offset would put the
/// picture eleven seconds off for the second half. The engine's
/// `align_versions` maps the whole song, segment by segment; this fetches the
/// video's audio, runs it once per pair and keeps the answer, so the picture
/// can follow the song's own audio through an intro and past an interlude.
actor VideoVersionAlignment {
    static let shared = VideoVersionAlignment()

    struct Map: Codable, Sendable, Equatable {
        struct Segment: Codable, Sendable, Equatable {
            let songStart: Double
            let songEnd: Double
            let offset: Double
        }
        let segments: [Segment]
        let confident: Bool
        let minimumWindowSimilarity: Double

        init(segments: [Segment], confident: Bool, minimumWindowSimilarity: Double) {
            self.segments = segments
            self.confident = confident
            self.minimumWindowSimilarity = minimumWindowSimilarity
        }

        private enum CodingKeys: String, CodingKey {
            case segments, confident, minimumWindowSimilarity
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            segments = try values.decode([Segment].self, forKey: .segments)
            confident = try values.decode(Bool.self, forKey: .confident)
            // A pre-window map lacks this metric and must be remeasured before
            // being trusted by the video surface.
            minimumWindowSimilarity = try values.decodeIfPresent(Double.self, forKey: .minimumWindowSimilarity) ?? -1
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(segments, forKey: .segments)
            try values.encode(confident, forKey: .confident)
            try values.encode(minimumWindowSimilarity, forKey: .minimumWindowSimilarity)
        }

        /// Video time for a song time. Before the first segment and after the
        /// last, the nearest segment's offset holds.
        func videoTime(at song: Double) -> Double {
            if let segment = segments.first(where: { song >= $0.songStart && song < $0.songEnd }) {
                return song + segment.offset
            }
            let nearest = song < (segments.first?.songStart ?? 0) ? segments.first : segments.last
            return song + (nearest?.offset ?? 0)
        }

        var summary: String {
            segments.map { String(format: "%.0f–%.0fs %+.2fs", $0.songStart, $0.songEnd, $0.offset) }
                .joined(separator: ", ")
        }
    }

    private var maps: [String: Map] = [:]
    private var mapOrder: [String] = []
    private struct Flight {
        let id: UUID
        let task: Task<Map?, Never>
        var waiters: Set<UUID>
    }
    private var inFlight: [String: Flight] = [:]

    private let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("BitChord/VersionAlignment", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The map for this pair, measuring it if no earlier play did. Nil when the
    /// song never finished downloading or the video's audio could not be had.
    func map(songId: String, videoId: String) async -> Map? {
        guard !Task.isCancelled else { return nil }
        let key = "\(songId)_\(videoId)"
        if let known = maps[key] { return known }
        let file = directory.appendingPathComponent("\(key).json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Map.self, from: data),
           saved.minimumWindowSimilarity >= 0 {
            remember(saved, key: key)
            return saved
        }
        if var running = inFlight[key] {
            let waiter = UUID()
            running.waiters.insert(waiter); inFlight[key] = running
            return await wait(for: running, key: key, waiter: waiter)
        }
        let task = Task<Map?, Never> { [directory] in
            // Both recordings are fetched here, side by side and at full
            // speed: waiting for playback to finish downloading the song kept
            // the picture off screen for most of the track.
            // Different candidate pairs may share a song. Private work files
            // prevent one pair's download/cleanup from corrupting another's.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("BitChordVideoAlignment-\(UUID().uuidString)")
            do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
            catch { return nil }
            let songAudio = work.appendingPathComponent("song.audio")
            let videoAudio = work.appendingPathComponent("video.audio")
            defer { try? FileManager.default.removeItem(at: work); MemoryRelief.soon() }
            let fetchStarted = Date()
            do {
                async let song: Void = Self.download(videoId: songId, to: songAudio)
                async let video: Void = Self.download(videoId: videoId, to: videoAudio)
                _ = try await (song, video)
            } catch {
                PlaybackDebugLog.shared.record("video align: the audio for \(videoId) failed: \(error)", about: songId)
                return nil
            }
            let songPath = songAudio.path
            guard !Task.isCancelled else { return nil }
            PlaybackDebugLog.shared.record(String(
                format: "video align: both recordings fetched in %.1fs", Date().timeIntervalSince(fetchStarted)
            ), about: songId)
            let started = Date()
            let analysisWork = Task.detached(priority: .utility) {
                await VideoAlignmentWorker.shared.align(song: songPath, video: videoAudio.path)
            }
            let rec = await withTaskCancellationHandler {
                await analysisWork.value
            } onCancel: {
                analysisWork.cancel()
            }
            guard !Task.isCancelled else { return nil }
            guard let rec else {
                PlaybackDebugLog.shared.record("video align: \(videoId) could not be decoded", about: songId)
                return nil
            }
            let map = Map(
                segments: rec.segments.map { .init(songStart: $0.songStart, songEnd: $0.songEnd, offset: $0.offset) },
                confident: rec.confident,
                minimumWindowSimilarity: rec.minimumWindowSimilarity
            )
            PlaybackDebugLog.shared.record(String(
                format: "video align: %@ %@ in %.1fs (similarity %.2f, baseline %.2f, window minimum %.2f, coverage %.2f): %@",
                videoId, rec.confident ? "aligned" : "NOT confident", Date().timeIntervalSince(started),
                rec.similarity, rec.baseline, rec.minimumWindowSimilarity, rec.coverage, map.summary
            ), about: songId)
            if let data = try? JSONEncoder().encode(map) { try? data.write(to: file, options: .atomic) }
            return map
        }
        let waiter = UUID()
        let flight = Flight(id: UUID(), task: task, waiters: [waiter])
        inFlight[key] = flight
        return await wait(for: flight, key: key, waiter: waiter)
    }

    private func wait(for flight: Flight, key: String, waiter: UUID) async -> Map? {
        await withTaskCancellationHandler {
            let map = await flight.task.value
            release(key: key, id: flight.id, waiter: waiter, cancelled: false)
            guard !Task.isCancelled else { return nil }
            if let map { remember(map, key: key) }
            return map
        } onCancel: {
            Task { await self.release(key: key, id: flight.id, waiter: waiter, cancelled: true) }
        }
    }

    private func release(key: String, id: UUID, waiter: UUID, cancelled: Bool) {
        guard var flight = inFlight[key], flight.id == id else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty {
            if cancelled { flight.task.cancel() }
            inFlight[key] = nil
        } else { inFlight[key] = flight }
    }

    private func remember(_ map: Map, key: String) {
        mapOrder.removeAll { $0 == key }
        mapOrder.append(key); maps[key] = map
        while mapOrder.count > 32 { maps[mapOrder.removeFirst()] = nil }
    }

    /// googlevideo slows one open-ended request down to playback speed, so a
    /// whole song took minutes; bounded 1 MiB ranges arrive at line rate (the
    /// engine's `fetch_loop` does the same).
    private static func download(videoId: String, to destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }
        // Reuse only a verified completed recording with this exact YouTube
        // identity, never an unfinished or substituted playback rendition.
        if let cached = await StreamFileCache.shared.completedDownloadPath(videoId: videoId, requireLossless: false, minimumKbps: 0) {
            do { try FileManager.default.copyItem(atPath: cached, toPath: destination.path); return }
            catch { /* Cache eviction can race the copy; fetch normally. */ }
        }
        let stream = try await InnertubeStreamResolver.shared.resolve(videoId: videoId)
        guard let url = URL(string: stream.url) else { throw URLError(.badURL) }
        try await VideoAudioDownloader.download(source: url, headers: stream.headers, to: destination)
    }
}

/// Native alignment is synchronous and cannot be interrupted mid-call. Keep
/// one such call running at a time; cancelled queued jobs never start one.
private actor VideoAlignmentWorker {
    static let shared = VideoAlignmentWorker()
    func align(song: String, video: String) async -> VersionAlignmentRec? {
        guard !Task.isCancelled else { return nil }
        return await AnalysisTurns.take {
            Task.isCancelled ? nil : alignVersions(songPath: song, otherPath: video)
        }
    }
}
