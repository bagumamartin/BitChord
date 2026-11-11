import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import BitChordShared

/// One bounded cover beside each saved audio file. A URL/credential digest
/// joins display sizes; the audio file, rather than the image LRU, owns retention.
actor OfflineArtworkStore {
    static let shared = OfflineArtworkStore()
    private let audioDirectories: [URL]
    private let imageDirectory: URL
    private var owners: [String: Set<String>]?
    private var lastTrim = Date.distantPast
    private struct Record: Codable { var key: String; var sha256: String; var pixels: Int }

    init(audioDirectories: [URL]? = nil, imageDirectory: URL? = nil) {
        let files = FileManager.default
        self.audioDirectories = audioDirectories ?? [
            files.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BitChord/audio"),
            files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BitChord/Downloads/audio")
        ]
        self.imageDirectory = imageDirectory ?? DiskCache.cachesSubfolder("images")
    }

    nonisolated static func key(url: String, headers: [String: String]) -> String {
        let canonical = url.replacingOccurrences(of: #"w\d+-h\d+"#, with: "w*-h*", options: .regularExpression)
        return digest(canonical + "\u{0}" + headers.sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: "\u{0}"))
    }
    nonisolated private static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    nonisolated private static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func coverURL(audioPath: String) -> URL { URL(fileURLWithPath: audioPath).appendingPathExtension("artwork") }
    nonisolated private static func recordURL(_ audioPath: String) -> URL { URL(fileURLWithPath: audioPath).appendingPathExtension("artwork.json") }
    nonisolated static func remove(audioPath: String) {
        try? FileManager.default.removeItem(at: coverURL(audioPath: audioPath))
        try? FileManager.default.removeItem(at: recordURL(audioPath))
    }

    nonisolated private static func pixels(_ data: Data) -> Int? {
        guard data.count <= 8 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return max(width.intValue, height.intValue)
    }
    nonisolated static func normalized(_ data: Data) -> Data? {
        guard pixels(data) != nil, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: hasAlpha = true
        default: hasAlpha = false
        }
        let format = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 2 * 1024 * 1024 else { return nil }
        return output as Data
    }

    private func read(_ url: URL, limit: Int = 2 * 1024 * 1024) -> Data? {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              bytes.intValue > 0, bytes.intValue <= limit else { return nil }
        return try? Data(contentsOf: url)
    }
    func image(_ data: Data) -> Data? { Self.normalized(data) }
    private func loadOwners() {
        guard owners == nil else { return }
        owners = [:]
        for directory in audioDirectories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(".artwork.json") {
                let path = file.deletingPathExtension().deletingPathExtension().path
                if FileManager.default.fileExists(atPath: path), let data = read(file, limit: 4096),
                   let record = try? JSONDecoder().decode(Record.self, from: data) {
                    owners?[record.key, default: []].insert(path)
                }
            }
        }
    }
    func data(audioPath: String) -> Data? {
        guard FileManager.default.fileExists(atPath: audioPath),
              let metadata = read(Self.recordURL(audioPath), limit: 4096),
              let record = try? JSONDecoder().decode(Record.self, from: metadata),
              let data = read(Self.coverURL(audioPath: audioPath)), Self.digest(data) == record.sha256 else { return nil }
        return data
    }
    /// The size a request asks for, from its `w…-h…` segment, capped at what
    /// [normalized] keeps. Zero when the URL names no size.
    nonisolated static func requestedPixels(_ url: String) -> Int {
        guard let match = url.firstMatch(of: #/w(\d+)-h(\d+)/#),
              let width = Int(match.1), let height = Int(match.2) else { return 0 }
        return min(1200, max(width, height))
    }

    /// A saved cover for this artwork at least as large as the request, or nil.
    ///
    /// The key deliberately ignores the size segment, so every rendition of one
    /// cover shares a file. That made the first size ever fetched — often the
    /// 88-pixel list thumbnail — the answer for every later size too, and the
    /// player, the lock screen and the menu bar drew that thumbnail scaled up
    /// (issue 12). A smaller saved cover is now only a stand-in: it is returned
    /// when `acceptSmaller` says the caller has no better way to get one (no
    /// network, or the fetch failed).
    func cachedData(url: String, headers: [String: String], acceptSmaller: Bool = false) -> Data? {
        let key = Self.key(url: url, headers: headers)
        let needed = Self.requestedPixels(url)
        var standIn: (data: Data, pixels: Int)?
        func consider(_ data: Data) -> Data? {
            let pixels = Self.pixels(data) ?? 0
            if pixels >= needed { return data }
            if pixels > (standIn?.pixels ?? -1) { standIn = (data, pixels) }
            return nil
        }
        loadOwners()
        for path in owners?[key] ?? [] {
            if let metadata = read(Self.recordURL(path), limit: 4096),
               let record = try? JSONDecoder().decode(Record.self, from: metadata), record.key == key,
               let data = data(audioPath: path) {
                if let hit = consider(data) { return hit }
                continue
            }
            owners?[key]?.remove(path)
        }
        let canonical = imageDirectory.appendingPathComponent("cover-" + key)
        if let data = read(canonical), Self.pixels(data) != nil {
            DiskCache.touch(canonical)
            if let hit = consider(data) { return hit }
            // Already asked the CDN for this size or more and this is what it
            // had: some covers simply are small, and asking again on every
            // view would be a fetch per row for nothing.
            if asked(canonical) >= needed { return data }
        }
        // Recover covers already written by older versions, including a smaller
        // thumbnail when the larger player/lock-screen rendition was never fetched.
        let variants = [url] + [1200, 900, 600, 544, 480, 320, 256, 176, 132, 120, 112, 88].map {
            url.replacingOccurrences(of: #"w\d+-h\d+"#, with: "w\($0)-h\($0)", options: .regularExpression)
        }
        var seen: Set<String> = []
        for variant in variants where seen.insert(variant).inserted {
            let legacyKey = Self.digest(variant + headers.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\u{0}"))
            if let data = read(imageDirectory.appendingPathComponent(legacyKey), limit: 8 * 1024 * 1024),
               let normalized = cache(data: data, url: url, headers: headers, asked: Self.requestedPixels(variant)),
               let hit = consider(normalized) { return hit }
        }
        return acceptSmaller ? standIn?.data : nil
    }
    /// The largest size the CDN has been asked for this cover, beside it.
    private func asked(_ cover: URL) -> Int {
        guard let data = read(cover.appendingPathExtension("asked"), limit: 16),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        return Int(text) ?? 0
    }
    private func noteAsked(_ pixels: Int, for cover: URL) {
        guard pixels > asked(cover) else { return }
        try? Data(String(pixels).utf8).write(to: cover.appendingPathExtension("asked"), options: .atomic)
    }

    /// `asked` is the size the bytes were fetched at, when that is not the size
    /// `url` names — a legacy file recovered for a larger request was never
    /// asked for at the larger size, and must not be remembered as if it were.
    @discardableResult func cache(data: Data, url: String, headers: [String: String], asked: Int? = nil) -> Data? {
        guard let image = Self.normalized(data) else { return nil }
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let file = imageDirectory.appendingPathComponent("cover-" + Self.key(url: url, headers: headers))
        // Never trade a larger saved rendition for a smaller one: a list
        // thumbnail fetched after the player's cover would otherwise put the
        // thumbnail back in its place.
        if let existing = read(file), let saved = Self.pixels(existing),
           saved > (Self.pixels(image) ?? 0) {
            DiskCache.touch(file)
            noteAsked(asked ?? Self.requestedPixels(url), for: file)
            return existing
        }
        try? image.write(to: file, options: .atomic)
        DiskCache.allowLockedPlayback(file)
        noteAsked(asked ?? Self.requestedPixels(url), for: file)
        if Date().timeIntervalSince(lastTrim) > 60 {
            lastTrim = Date(); DiskCache.trimFolder(imageDirectory, limitBytes: 128 * 1024 * 1024)
        }
        return image
    }
    @discardableResult func retain(data: Data, url: String, headers: [String: String], audioPath: String) -> Data? {
        guard FileManager.default.fileExists(atPath: audioPath), let pixels = Self.pixels(data) else { return nil }
        let key = Self.key(url: url, headers: headers)
        if let metadata = read(Self.recordURL(audioPath), limit: 4096),
           let saved = try? JSONDecoder().decode(Record.self, from: metadata), saved.key == key,
           saved.pixels >= min(1200, pixels), let existing = self.data(audioPath: audioPath) { return existing }
        guard let image = Self.normalized(data) else { return nil }
        return write(image: image, key: key, audioPath: audioPath)
    }
    func copy(from sourcePath: String, to audioPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: audioPath),
              let metadata = read(Self.recordURL(sourcePath), limit: 4096),
              let record = try? JSONDecoder().decode(Record.self, from: metadata),
              let image = data(audioPath: sourcePath) else { return false }
        return write(image: image, key: record.key, audioPath: audioPath) != nil
    }
    private func write(image: Data, key: String, audioPath: String) -> Data? {
        let record = Record(key: key, sha256: Self.digest(image), pixels: Self.pixels(image) ?? 0)
        if let previous = read(Self.recordURL(audioPath), limit: 4096),
           let saved = try? JSONDecoder().decode(Record.self, from: previous), saved.key == key,
           saved.pixels >= record.pixels, let existing = self.data(audioPath: audioPath) { return existing }
        do {
            try image.write(to: Self.coverURL(audioPath: audioPath), options: .atomic)
            try JSONEncoder().encode(record).write(to: Self.recordURL(audioPath), options: .atomic)
            DiskCache.allowLockedPlayback(Self.coverURL(audioPath: audioPath)); DiskCache.allowLockedPlayback(Self.recordURL(audioPath))
            guard FileManager.default.fileExists(atPath: audioPath) else { Self.remove(audioPath: audioPath); return nil }
            loadOwners(); owners?[key, default: []].insert(audioPath)
            return image
        } catch { return nil }
    }
}

enum OfflineArtwork {
    static func data(for entry: QueueEntry, store: OfflineArtworkStore = .shared, allowNetwork: Bool = true) async -> Data? {
        if let data = entry.artworkData, let image = await store.image(data) { return image }
        guard let url = entry.thumbnailUrl else { return nil }
        if LocalArtwork.isReference(url) { return await LocalArtwork.shared.data(for: url) }
        let headers = WebDavBridge.shared.playbackHeaders(fileUrl: url)
        let sized = url.replacingOccurrences(of: #"w\d+-h\d+"#, with: "w544-h544", options: .regularExpression)
        if let saved = await store.cachedData(url: sized, headers: headers, acceptSmaller: !allowNetwork) { return saved }
        guard allowNetwork, !Task.isCancelled else { return nil }
        if let fetched = await ArtworkRequests.shared.data(url: sized, headers: headers) { return fetched }
        return await store.cachedData(url: sized, headers: headers, acceptSmaller: true)
    }
    static func preserve(_ entry: QueueEntry, audioPath: String, store: OfflineArtworkStore = .shared, allowNetwork: Bool = true) async {
        if let url = entry.thumbnailUrl, LocalArtwork.isReference(url), let path = URL(string: url)?.path,
           await store.copy(from: path, to: audioPath) { return }
        guard FileManager.default.fileExists(atPath: audioPath), !Task.isCancelled,
              let data = await data(for: entry, store: store, allowNetwork: allowNetwork), !Task.isCancelled else { return }
        let url = entry.thumbnailUrl ?? "embedded:\(entry.source)|\(entry.id)"
        let headers = LocalArtwork.isReference(url) ? [:] : WebDavBridge.shared.playbackHeaders(fileUrl: url)
        await store.retain(data: data, url: url, headers: headers, audioPath: audioPath)
    }
}
