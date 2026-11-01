import CryptoKit
import Foundation
import BitChordShared

/// Disk LRU of completed stream files — Apple stand-in for upstream `AudioCache`
/// + `DynamicLruCacheEvictor`. Keyed by video id, ceiling from Settings
/// (512 MB–10 GB). Whole files rather than Media3 spans: the easy path on
/// Apple, and it never evicts a track's opening while keeping its tail.
actor StreamFileCache {
    static let shared = StreamFileCache()

    private let directory: URL?
    private var verifiedFiles: [String: (bytes: Int64, modified: Date, hash: String)] = [:]
    private var aliases: [String: [URL]]?
    private var verifiedSources: [String: (hash: String, mediaID: String)] = [:]
    private var rememberedEntries: [String: QueueEntry] = [:]
    private var artworkTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private let artworkStore: OfflineArtworkStore
    init(directory: URL? = nil, artworkStore: OfflineArtworkStore = .shared) { self.directory = directory; self.artworkStore = artworkStore }

    private static let defaultLimit: Int64 = 512 * 1024 * 1024
    private static let extensions = ["m4a", "mp4", "webm", "m4v", "aac", "flac", "ogg", "opus", "mp3", "wav", "aiff"]

    struct Manifest: Codable {
        var version: Int = 1
        var codec: String
        var kbps: Int
        var quality: String
        var sourceIdentity: String
        var recordingIdentity: String
        var complete: Bool
        var bytes: Int64
        var sha256: String
        var youtubeVideoId: String? = nil
        var relativeLoudnessDb: Double? = nil
        var durationSeconds: Int? = nil
        var playbackMediaId: String? = nil
        var recordingVerified: Bool? = nil
        var entry: QueueEntry? = nil
    }
    private var inFlight: [String: (path: String, quality: String, kbps: Int, loudnessDb: Double?, youtubeVideoId: String?, durationSeconds: Int?)] = [:]
    nonisolated static var qualityIdentity: String {
        let wifi = PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "LOSSLESS")
        let cellular = PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "LOSSLESS")
        let musicOnly = PlatformSettings.shared.getBoolean(key: "prefer_music_only", default: false)
        return "\(wifi)|\(cellular)|\(musicOnly)"
    }
    private func manifestURL(_ path: String) -> URL { URL(fileURLWithPath: path).appendingPathExtension("json") }
    private func hashFile(_ path: String) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        var hash = SHA256()
        do { while true { let data = try file.read(upToCount: 65536) ?? Data(); if data.isEmpty { break }; hash.update(data: data) } } catch { return nil }

        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var folder: URL {
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory }
        return DiskCache.cachesSubfolder("audio")
    }

    private func verified(_ path: String, manifest: Manifest) -> Bool {
        guard manifest.version == 1, manifest.complete, manifest.bytes > 0,
              !FileManager.default.fileExists(atPath: path + ".failed"),
              !FileManager.default.fileExists(atPath: path + ".playback-cancelled"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value == manifest.bytes,
              let modified = attributes[.modificationDate] as? Date else { return false }
        if let known = verifiedFiles[path], known.bytes == manifest.bytes,
           known.modified == modified, known.hash == manifest.sha256 { return true }
        guard hashFile(path) == manifest.sha256 else { verifiedFiles[path] = nil; return false }
        if verifiedFiles.count >= 256 { verifiedFiles.removeAll(keepingCapacity: true) }
        verifiedFiles[path] = (manifest.bytes, modified, manifest.sha256)
        return true
    }

    /// Network ceilings limit fetched bytes, not files already on disk. Keep the
    /// music-video preference separate so a preference change still takes effect.
    nonisolated static func compatiblePlaybackIdentity(_ saved: String, _ current: String) -> Bool {
        let old = saved.split(separator: "|"), new = current.split(separator: "|")
        return old.count == 3 && new.count == 3 ? old[2] == new[2] : saved == current
    }

    private func aliasedFiles(for id: String) -> [URL] {
        if aliases == nil {
            aliases = [:]
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.recordingVerified == true, let id = manifest.playbackMediaId {
                    aliases?[id, default: []].append(file.deletingPathExtension())
                }
            }
        }
        return aliases?[id] ?? []
    }

    func path(for videoId: String, maxKbps: Int = Int.max, requireLossless: Bool = false, allowGrowing: Bool = true, allowQualityFallback: Bool = false, onlyOriginal: Bool = false) -> String? {
        if allowGrowing, let active = inFlight[videoId],
           (active.quality == Self.qualityIdentity || (allowQualityFallback && Self.compatiblePlaybackIdentity(active.quality, Self.qualityIdentity))),
           FileManager.default.fileExists(atPath: active.path),
           !FileManager.default.fileExists(atPath: active.path + ".failed"),
           !FileManager.default.fileExists(atPath: active.path + ".playback-cancelled"),
           !requireLossless, active.kbps <= maxKbps,
           !onlyOriginal || active.youtubeVideoId == videoId { return active.path }
        let candidates = (onlyOriginal ? [] : aliasedFiles(for: videoId)) + Self.extensions.map { cachedURL(for: videoId, ext: $0) }
        for dest in candidates {
        guard !FileManager.default.fileExists(atPath: dest.path + ".failed"),
              !FileManager.default.fileExists(atPath: dest.path + ".playback-cancelled"),
              let data = try? Data(contentsOf: manifestURL(dest.path)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, manifest.complete, manifest.codec != "unknown",
              manifest.recordingIdentity == videoId || (manifest.playbackMediaId == videoId && manifest.recordingVerified == true),
              !onlyOriginal || manifest.youtubeVideoId == videoId,
              (manifest.quality == Self.qualityIdentity || (allowQualityFallback && Self.compatiblePlaybackIdentity(manifest.quality, Self.qualityIdentity))),
              manifest.kbps <= maxKbps,
              !requireLossless || ["FLAC", "ALAC", "PCM"].contains(manifest.codec),
              verified(dest.path, manifest: manifest) else { continue }
        // A legacy entry needs a fresh resolution: its quality and completion
        // cannot be established from a file extension. Keep its bytes for any
        // active reader while the new rendition is resolved.

        DiskCache.touch(manifestURL(dest.path))
        return dest.path
        }
        return nil
    }

    /// Downloads can adopt verified completed YouTube bytes, independent of
    /// streaming network ceilings. Substitute renditions need their own identity.
    func completedDownloadPath(videoId: String, requireLossless: Bool, minimumKbps: Int, maximumKbps: Int = Int.max) -> String? {
        for ext in Self.extensions {
            let dest = cachedURL(for: videoId, ext: ext)
            guard let data = try? Data(contentsOf: manifestURL(dest.path)),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  manifest.complete, manifest.recordingIdentity == videoId,
                  manifest.youtubeVideoId == videoId, manifest.kbps >= minimumKbps, manifest.kbps <= maximumKbps,
                  !requireLossless || ["FLAC", "ALAC", "PCM"].contains(manifest.codec.uppercased()),
                  verified(dest.path, manifest: manifest) else { continue }
            return dest.path
        }
        return nil
    }

    private struct LoudnessCache: Codable {
        var sourceSHA256: String
        var measurementVersion: String
        var trackLufs: Double
        var truePeakDbtp: Double?
    }
    func measuredLoudness(at path: String) -> LoudnessMeasurement? {
        let url = URL(fileURLWithPath: path).appendingPathExtension("loudness.json")
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(LoudnessCache.self, from: data),
              entry.measurementVersion == "ebur128-0.1.10-stereo", entry.sourceSHA256 == hashFile(path) else { return nil }
        return LoudnessMeasurement(trackLufs: entry.trackLufs, albumLufs: nil, truePeakDbtp: entry.truePeakDbtp)
    }
    func storeMeasurement(_ measurement: LoudnessMeasurement, at path: String) {
        guard let hash = hashFile(path) else { return }
        let entry = LoudnessCache(sourceSHA256: hash, measurementVersion: "ebur128-0.1.10-stereo", trackLufs: measurement.trackLufs, truePeakDbtp: measurement.truePeakDbtp)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: URL(fileURLWithPath: path).appendingPathExtension("loudness.json"), options: .atomic)
    }

    func metadata(at path: String) -> Manifest? {
        if let data = try? Data(contentsOf: manifestURL(path)) {
            return try? JSONDecoder().decode(Manifest.self, from: data)
        }
        if let entry = inFlight.first(where: { $0.value.path == path }) {
            return Manifest(codec: "unknown", kbps: entry.value.kbps, quality: entry.value.quality, sourceIdentity: "growing", recordingIdentity: entry.key, complete: false, bytes: 0, sha256: "", youtubeVideoId: entry.value.youtubeVideoId, relativeLoudnessDb: entry.value.loudnessDb, durationSeconds: entry.value.durationSeconds)
        }
        return nil
    }

    /// The download has its first bytes. Later resolves of the same track must
    /// join this file instead of starting a second fetch at the handoff.
    func noteGrowing(videoId: String, path: String, kbps: Int = 0, quality: String? = nil, relativeLoudnessDb: Double? = nil, youtubeVideoId: String? = nil, durationSeconds: Int? = nil) {
        guard !FileManager.default.fileExists(atPath: path + ".complete") else { return }
        inFlight[videoId] = (path, quality ?? Self.qualityIdentity, kbps, relativeLoudnessDb, youtubeVideoId, durationSeconds)
    }

    /// The download failed before it finished. Drop the pointer so the next
    /// resolve fetches again. The bytes already handed to a player stay put.
    func dropGrowing(videoId: String, path: String? = nil) {
        if path == nil || inFlight[videoId]?.path == path { inFlight.removeValue(forKey: videoId) }
    }

    func store(_ videoId: String, path: String, sourceIdentity: String = "unknown", codec: String = "unknown", kbps: Int = 0, quality: String? = nil, relativeLoudnessDb: Double? = nil, youtubeVideoId: String? = nil, durationSeconds: Int? = nil) {
        defer { if inFlight[videoId]?.path == path { inFlight.removeValue(forKey: videoId) } }
        guard !FileManager.default.fileExists(atPath: path + ".failed"),
              !FileManager.default.fileExists(atPath: path + ".grow") || FileManager.default.fileExists(atPath: path + ".complete") else { return }
        let suppliedExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        let ext = Self.extensions.contains(suppliedExtension) ? suppliedExtension : (AudioDownloadContainer.fileExtension(at: path) ?? suppliedExtension)
        let dest = cachedURL(for: videoId, ext: ext)
        let fm = FileManager.default
        if dest.path != path {
            let staged = folder.appendingPathComponent(".incoming-" + UUID().uuidString)
            defer { try? fm.removeItem(at: staged) }
            do {
                try fm.copyItem(atPath: path, toPath: staged.path)
                if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: staged) }
                else { try fm.moveItem(at: staged, to: dest) }
            } catch { return }
            // Leave `path` in place: the decoder may still be reading that file.
        }
        DiskCache.allowLockedPlayback(dest)
        guard let bytes = (try? fm.attributesOfItem(atPath: dest.path)[.size]) as? NSNumber,
              let hash = hashFile(dest.path), bytes.int64Value > 0 else { return }
        let playbackMediaId = videoId.contains("#") ? String(videoId.prefix(while: { $0 != "#" })) : nil
        let cachedCodec = codec == "unknown" ? (AudioDownloadContainer.fileExtension(at: dest.path)?.uppercased() ?? codec) : codec
        let recordingVerified = playbackMediaId.map { $0.hasPrefix("src:") || $0.hasPrefix("saavn:") || (verifiedSources[videoId]?.hash == hash && verifiedSources[videoId]?.mediaID == $0) } ?? true
        let entry = rememberedEntries[playbackMediaId ?? videoId]
        let manifest = Manifest(codec: cachedCodec, kbps: kbps, quality: quality ?? Self.qualityIdentity, sourceIdentity: sourceIdentity, recordingIdentity: videoId, complete: true, bytes: bytes.int64Value, sha256: hash, youtubeVideoId: youtubeVideoId, relativeLoudnessDb: relativeLoudnessDb, durationSeconds: durationSeconds, playbackMediaId: playbackMediaId, recordingVerified: recordingVerified, entry: entry)
        guard let data = try? JSONEncoder().encode(manifest), (try? data.write(to: manifestURL(dest.path), options: .atomic)) != nil else { return }
        inFlight.removeValue(forKey: videoId)
        if let playbackMediaId { aliases?[playbackMediaId]?.removeAll { $0 == dest } }
        if let playbackMediaId, recordingVerified {
            _ = aliasedFiles(for: playbackMediaId)
            aliases?[playbackMediaId]?.removeAll { $0 == dest }
            aliases?[playbackMediaId, default: []].insert(dest, at: 0)
        }
        DiskCache.touch(manifestURL(dest.path))
        trim(keeping: videoId)
        if let entry { preserveArtwork(entry, path: dest.path, allowNetwork: true) }
    }

    /// Preserve names and covers even if listening history or the image LRU is cleared.
    func remember(_ entry: QueueEntry, allowNetwork: Bool = true) async {
        var metadata = entry; metadata.artworkData = nil
        if rememberedEntries.count >= 128, rememberedEntries[entry.id] == nil,
           let expired = rememberedEntries.keys.first(where: { id in !inFlight.keys.contains(where: { String($0.prefix(while: { $0 != "#" })) == id }) }) {
            rememberedEntries[expired] = nil
        }
        rememberedEntries[entry.id] = metadata
        if let bytes = entry.artworkData, let url = entry.thumbnailUrl {
            let headers = LocalArtwork.isReference(url) ? [:] : WebDavBridge.shared.playbackHeaders(fileUrl: url)
            await artworkStore.cache(data: bytes, url: url, headers: headers)
        }
        let candidates = aliasedFiles(for: entry.id) + Self.extensions.map { cachedURL(for: entry.id, ext: $0) }
        for file in Set(candidates) {
            guard var manifest = self.metadata(at: file.path), manifest.complete,
                  manifest.recordingIdentity == entry.id || (manifest.playbackMediaId == entry.id && manifest.recordingVerified == true),
                  FileManager.default.fileExists(atPath: file.path) else { continue }
            var saved = metadata
            if let url = saved.thumbnailUrl, LocalArtwork.isReference(url),
               let original = manifest.entry?.thumbnailUrl, !LocalArtwork.isReference(original) {
                saved.thumbnailUrl = original
            }
            manifest.entry = saved
            rememberedEntries[entry.id] = saved
            if let encoded = try? JSONEncoder().encode(manifest) { try? encoded.write(to: manifestURL(file.path), options: .atomic) }
            preserveArtwork(entry, path: file.path, allowNetwork: allowNetwork)
        }
    }
    private func preserveArtwork(_ entry: QueueEntry, path: String, allowNetwork: Bool) {
        artworkTasks[path]?.task.cancel()
        let id = UUID(), store = artworkStore
        let task = Task(priority: .utility) { [weak self] in
            await OfflineArtwork.preserve(entry, audioPath: path, store: store, allowNetwork: allowNetwork)
            await self?.finishedArtwork(path: path, id: id)
        }
        artworkTasks[path] = (id, task)
    }
    private func finishedArtwork(path: String, id: UUID) {
        if artworkTasks[path]?.id == id { artworkTasks[path] = nil }
    }

    func markRecordingVerified(mediaID: String, cacheKey: String, sourcePath: String) {
        guard !FileManager.default.fileExists(atPath: sourcePath + ".failed"), let hash = hashFile(sourcePath) else { return }
        if verifiedSources.count >= 128 { verifiedSources.removeAll(keepingCapacity: true) }
        verifiedSources[cacheKey] = (hash, mediaID)
        let cached = cachedURL(for: cacheKey)
        guard var manifest = metadata(at: cached.path), manifest.sha256 == hash else { return }
        manifest.recordingVerified = true; manifest.playbackMediaId = mediaID
        guard let data = try? JSONEncoder().encode(manifest), (try? data.write(to: manifestURL(cached.path), options: .atomic)) != nil else { return }
        _ = aliasedFiles(for: mediaID)
        aliases?[mediaID]?.removeAll { $0 == cached }
        aliases?[mediaID, default: []].insert(cached, at: 0)
    }

    func storeDuration(_ seconds: Int, at path: String) {
        guard seconds > 0, var manifest = metadata(at: path) else { return }
        manifest.durationSeconds = seconds
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL(path), options: .atomic) }
    }

    func clear() {
        artworkTasks.values.forEach { $0.task.cancel() }; artworkTasks.removeAll()
        rememberedEntries.removeAll()
        inFlight.removeAll()
        verifiedFiles.removeAll()
        aliases = nil
        verifiedSources.removeAll()
        DiskCache.clearFolder(folder)
    }

    // MARK: - What is on disk

    /// One cached track, as the Cached Songs list needs it.
    struct CachedEntry: Identifiable, Sendable {
        let videoId: String
        let bytes: Int64
        let durationSeconds: Int?
        let codec: String
        let modified: Date
        var entry: QueueEntry? = nil
        var artworkReference: String? = nil

        var id: String { videoId }
    }

    /// Every finished track in the cache, newest first.
    ///
    /// The manifest is what says whether a file is a finished track or a
    /// half-written one, so a file without a readable manifest is not listed —
    /// it is not something the listener could play from the cache anyway.
    func entries() -> [CachedEntry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        var out: [CachedEntry] = []
        for manifestFile in urls where manifestFile.pathExtension == "json" {
            guard let data = try? Data(contentsOf: manifestFile),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  manifest.complete,
                  (!manifest.recordingIdentity.contains("#") && manifest.playbackMediaId == nil) || manifest.recordingVerified == true else { continue }
            let audio = manifestFile.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: audio.path) else { continue }
            let values = try? audio.resourceValues(forKeys: Set(keys))
            out.append(CachedEntry(
                videoId: manifest.playbackMediaId ?? manifest.youtubeVideoId ?? manifest.recordingIdentity,
                bytes: Int64(values?.fileSize ?? 0),
                durationSeconds: manifest.durationSeconds,
                codec: manifest.codec,
                modified: values?.contentModificationDate ?? .distantPast,
                entry: manifest.entry,
                artworkReference: FileManager.default.fileExists(atPath: OfflineArtworkStore.coverURL(audioPath: audio.path).path) ? LocalArtwork.reference(path: audio.path) : nil
            ))
        }
        var seen: Set<String> = []
        return out.sorted { $0.modified > $1.modified }.filter { seen.insert($0.videoId).inserted }
    }

    /// Drops one track's cached audio and its manifest.
    func remove(_ videoId: String) {
        forget(videoId: videoId)
    }

    /// Drops everything cached for one track, and forgets where it was growing.
    ///
    /// The growing path has to go too, and not only the finished copy: a revert
    /// sends the track back to YouTube's own upload, and leaving the old file in
    /// `inFlight` means the next `path(for:)` finds it still there and hands
    /// back the exact copy the listener just rejected — so the revert appears to
    /// do nothing. Every extension is tried because the cached file's extension
    /// is whichever one the source offered, and the rejected copy is the one
    /// nobody remembers the extension of.
    func forget(videoId: String) {
        let growing = inFlight.removeValue(forKey: videoId)
        let fm = FileManager.default
        for file in aliasedFiles(for: videoId) {
            artworkTasks.removeValue(forKey: file.path)?.task.cancel()
            OfflineArtworkStore.remove(audioPath: file.path)
            try? fm.removeItem(at: file); try? fm.removeItem(at: manifestURL(file.path))
        }
        aliases?[videoId] = nil
        for ext in Self.extensions {
            let url = folder.appendingPathComponent("\(Self.sanitized(videoId)).\(ext)")
            if fm.fileExists(atPath: url.path) {
                artworkTasks.removeValue(forKey: url.path)?.task.cancel()
                try? fm.removeItem(at: url); try? fm.removeItem(at: manifestURL(url.path))
                OfflineArtworkStore.remove(audioPath: url.path)
            }
        }
        if let growing, growing.path != folder.path {
            try? fm.removeItem(atPath: growing.path)
        }
    }

    func trim(keeping videoId: String? = nil, limitBytes: Int64? = nil) {
        let limit = limitBytes ?? PlatformSettings.shared.getLong(key: "audio_cache_limit_bytes", default: Self.defaultLimit)
        let files = FileManager.default
        let urls = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var total = urls.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let audio = urls.filter { Self.extensions.contains($0.pathExtension) }.sorted {
            ((try? manifestURL($0.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? manifestURL($1.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in audio where total > limit {
            guard file.deletingPathExtension().lastPathComponent != videoId.map(Self.sanitized),
                  !sourceHasPlaybackReaders(source: file.path) else { continue }
            if let id = metadata(at: file.path)?.playbackMediaId {
                aliases?[id]?.removeAll { $0 == file }
                if aliases?[id]?.isEmpty == true { aliases?[id] = nil }
            }
            artworkTasks.removeValue(forKey: file.path)?.task.cancel()
            for part in [file, manifestURL(file.path), file.appendingPathExtension("loudness.json"), OfflineArtworkStore.coverURL(audioPath: file.path), file.appendingPathExtension("artwork.json")] {
                let bytes = Int64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if (try? files.removeItem(at: part)) != nil { total -= bytes }
            }
            verifiedFiles[file.path] = nil
        }
    }

    private func cachedURL(for videoId: String, ext: String? = nil) -> URL {
        let safe = Self.sanitized(videoId)
        if let ext, !ext.isEmpty {
            return folder.appendingPathComponent("\(safe).\(ext)")
        }
        for e in Self.extensions {
            let url = folder.appendingPathComponent("\(safe).\(e)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return folder.appendingPathComponent("\(safe).m4a")
    }

    private static func sanitized(_ videoId: String) -> String {
        videoId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}

/// Looping canvas clips, capped at 150 MB like upstream `CanvasCache`.
actor CanvasFileCache {
    static let shared = CanvasFileCache()
    private static let limit: Int64 = 150 * 1024 * 1024
    private struct InFlightDownload {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<URL, Never>]
    }
    private var inFlight: [URL: InFlightDownload] = [:]

    var folder: URL { DiskCache.cachesSubfolder("canvas") }

    func cachedFile(for remote: URL) async -> URL {
        if remote.isFileURL { return remote }
        let ext = remote.pathExtension.lowercased()
        // AVPlayer must see an HLS playlist as a network resource so it can
        // resolve and fetch its media segments. Do not snapshot the playlist
        // into a local file, where its relative segment URLs would break.
        if ["m3u", "m3u8"].contains(ext) { return remote }
        // Keep the container extension on disk; AVPlayer uses it when opening
        // the downloaded movie as a local asset.
        guard ["mp4", "m4v", "mov", "webm"].contains(ext) else { return remote }
        let dest = folder.appendingPathComponent("\(DiskCache.hashName(remote.absoluteString)).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            DiskCache.touch(dest)
            return dest
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: remote)
                    return
                }
                registerWaiter(continuation, id: waiterID, remote: remote, destination: dest)
            }
        } onCancel: {
            Task { await self.cancelWaiter(for: remote, waiterID: waiterID) }
        }
    }

    private func registerWaiter(
        _ continuation: CheckedContinuation<URL, Never>,
        id waiterID: UUID,
        remote: URL,
        destination: URL
    ) {
        if var flight = inFlight[remote] {
            flight.waiters[waiterID] = continuation
            inFlight[remote] = flight
            return
        }

        let operationID = UUID()
        inFlight[remote] = InFlightDownload(id: operationID, task: nil, waiters: [waiterID: continuation])
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.download(remote, to: destination)
            await self.finishDownload(for: remote, operationID: operationID, result: result)
        }
        if var flight = inFlight[remote], flight.id == operationID {
            flight.task = task
            inFlight[remote] = flight
        }
    }

    private func cancelWaiter(for remote: URL, waiterID: UUID) {
        guard var flight = inFlight[remote],
              let continuation = flight.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: remote)
        if flight.waiters.isEmpty {
            inFlight[remote] = nil
            flight.task?.cancel()
        } else {
            inFlight[remote] = flight
        }
    }

    private func finishDownload(for remote: URL, operationID: UUID, result: URL) {
        guard let flight = inFlight[remote], flight.id == operationID else { return }
        inFlight[remote] = nil
        for continuation in flight.waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func download(_ remote: URL, to dest: URL) async -> URL {
        guard let (data, response) = try? await URLSession.shared.data(for: CanvasMediaRequest.download(remote)),
              !data.isEmpty else { return remote }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            PlaybackDebugLog.shared.record("animated artwork download failed HTTP \(http.statusCode) host=\(remote.host ?? "unknown")")
            return remote
        }
        if let mimeType = response.mimeType?.lowercased(), mimeType.contains("mpegurl") {
            return remote
        }
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.contains("text/") || mimeType.contains("json") { return remote }
        try? data.write(to: dest, options: .atomic)
        DiskCache.trimFolder(folder, limitBytes: Self.limit)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : remote
    }

    func invalidate(_ remote: URL) {
        let ext = remote.pathExtension.lowercased()
        let path = folder.appendingPathComponent("\(DiskCache.hashName(remote.absoluteString)).\(ext)")
        try? FileManager.default.removeItem(at: path)
    }

    func clear() { DiskCache.clearFolder(folder) }
}

enum DiskCache {
    static func allowLockedPlayback(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    static func cachesSubfolder(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if name == "audio" { allowLockedPlayback(dir) }
        return dir
    }

    static func hashName(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func trimFolder(_ folder: URL, limitBytes: Int64, keepingPrefix: String? = nil) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        struct Item { var url: URL; var date: Date; var size: Int64 }
        var items: [Item] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            return Item(
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                size: Int64(values?.fileSize ?? 0)
            )
        }
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return }
        items.sort { $0.date < $1.date }
        for item in items {
            if total <= limitBytes { break }
            if let keepingPrefix, item.url.deletingPathExtension().lastPathComponent == keepingPrefix {
                continue
            }
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
        }
    }

    static func clearFolder(_ folder: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
