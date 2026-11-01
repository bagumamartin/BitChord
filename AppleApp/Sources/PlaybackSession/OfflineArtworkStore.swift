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
    func cachedData(url: String, headers: [String: String]) -> Data? {
        let key = Self.key(url: url, headers: headers)
        loadOwners()
        for path in owners?[key] ?? [] {
            if let metadata = read(Self.recordURL(path), limit: 4096),
               let record = try? JSONDecoder().decode(Record.self, from: metadata), record.key == key,
               let data = data(audioPath: path) { return data }
            owners?[key]?.remove(path)
        }
        let canonical = imageDirectory.appendingPathComponent("cover-" + key)
        if let data = read(canonical), Self.pixels(data) != nil { DiskCache.touch(canonical); return data }
        // Recover covers already written by older versions, including a smaller
        // thumbnail when the larger player/lock-screen rendition was never fetched.
        let variants = [url] + [1200, 900, 600, 544, 480, 320, 256, 176, 132, 120, 112, 88].map {
            url.replacingOccurrences(of: #"w\d+-h\d+"#, with: "w\($0)-h\($0)", options: .regularExpression)
        }
        var seen: Set<String> = []
        for variant in variants where seen.insert(variant).inserted {
            let legacyKey = Self.digest(variant + headers.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\u{0}"))
            if let data = read(imageDirectory.appendingPathComponent(legacyKey), limit: 8 * 1024 * 1024),
               let normalized = cache(data: data, url: url, headers: headers) { return normalized }
        }
        return nil
    }
    @discardableResult func cache(data: Data, url: String, headers: [String: String]) -> Data? {
        guard let image = Self.normalized(data) else { return nil }
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let file = imageDirectory.appendingPathComponent("cover-" + Self.key(url: url, headers: headers))
        try? image.write(to: file, options: .atomic)
        DiskCache.allowLockedPlayback(file)
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
        if let saved = await store.cachedData(url: url, headers: headers) { return saved }
        guard allowNetwork, !Task.isCancelled else { return nil }
        let sized = url.replacingOccurrences(of: #"w\d+-h\d+"#, with: "w544-h544", options: .regularExpression)
        return await ArtworkRequests.shared.data(url: sized, headers: headers)
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
