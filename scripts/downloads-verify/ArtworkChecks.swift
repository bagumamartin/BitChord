import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BitChordShared

private final class ArtworkFetchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

enum ArtworkChecks {
    private static func fixture() -> Data {
        let context = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @MainActor static func run(root: URL) async throws {
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); print("PASS \(label)"); fflush(stdout) }
        let audio = root.appendingPathComponent("artwork-audio"), images = root.appendingPathComponent("artwork-images")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let owner = audio.appendingPathComponent("track.wav")
        try Data("owned audio".utf8).write(to: owner)
        let small = "https://offline-artwork.invalid/cover=w88-h88-l90-rj"
        let large = "https://offline-artwork.invalid/cover=w1200-h1200-l90-rj"
        let image = fixture(), store = OfflineArtworkStore(audioDirectories: [audio], imageDirectory: images)
        let calls = ArtworkFetchCount()
        let requests = ArtworkRequests(store: store) { _, _ in calls.increment(); return image }
        let first = await requests.data(url: small, headers: [:])
        let second = await requests.data(url: large, headers: [:])
        check(first != nil && first == second && calls.value == 1, "all cover sizes reuse one downloaded artwork image")
        await store.retain(data: first!, url: small, headers: [:], audioPath: owner.path)
        DiskCache.clearFolder(images)
        let coldStore = OfflineArtworkStore(audioDirectories: [audio], imageDirectory: images)
        let coldCalls = ArtworkFetchCount()
        let offline = ArtworkRequests(store: coldStore) { _, _ in coldCalls.increment(); return nil }
        let restored = await offline.data(url: large, headers: [:])
        check(restored != nil && coldCalls.value == 0, "a song's cover survives image-cache clearing and a cold offline relaunch")
        let local = await LocalArtwork.shared.data(for: LocalArtwork.reference(path: owner.path))
        check(local != nil, "downloaded-file artwork references read the preserved sidecar offline")
        let copied = audio.appendingPathComponent("copied.wav"); try Data("another owner".utf8).write(to: copied)
        let didCopy = await coldStore.copy(from: owner.path, to: copied.path)
        try FileManager.default.removeItem(at: owner); OfflineArtworkStore.remove(audioPath: owner.path)
        let afterCopy = await coldStore.cachedData(url: large, headers: [:])
        check(didCopy && afterCopy != nil, "copying a cover preserves its original URL identity for another audio owner")
        try FileManager.default.removeItem(at: copied); OfflineArtworkStore.remove(audioPath: copied.path)
        let removed = await coldStore.cachedData(url: large, headers: [:])
        check(removed == nil, "deleted audio cannot keep a stale protected artwork lookup alive")

        let privateOwner = audio.appendingPathComponent("private.wav"); try Data("private audio".utf8).write(to: privateOwner)
        await coldStore.retain(data: image, url: small, headers: ["Authorization": "fixture-A"], audioPath: privateOwner.path)
        let otherAccount = await coldStore.cachedData(url: large, headers: ["Authorization": "fixture-B"])
        check(otherAccount == nil, "offline artwork remains isolated by request credentials")
        await coldStore.retain(data: image, url: small, headers: ["Authorization": "fixture-B"], audioPath: privateOwner.path)
        let staleAccount = await coldStore.cachedData(url: large, headers: ["Authorization": "fixture-A"])
        check(staleAccount == nil, "replacing a protected cover cannot reuse a stale credential alias")
        let invalidOwner = audio.appendingPathComponent("invalid.wav"); try Data("audio".utf8).write(to: invalidOwner)
        let bad = await coldStore.retain(data: Data("not an image".utf8), url: small, headers: [:], audioPath: invalidOwner.path)
        check(bad == nil && !FileManager.default.fileExists(atPath: OfflineArtworkStore.coverURL(audioPath: invalidOwner.path).path), "invalid artwork never becomes a saved cover")
        let missingReference = LocalArtwork.reference(path: invalidOwner.path)
        let missingCover = await LocalArtwork.shared.data(for: missingReference)
        await coldStore.retain(data: image, url: small, headers: [:], audioPath: invalidOwner.path)
        let repairedReference = LocalArtwork.reference(path: invalidOwner.path)
        let repaired = await LocalArtwork.shared.data(for: repairedReference)
        check(missingCover == nil && repairedReference != missingReference && repaired != nil, "a late cover repair invalidates the earlier missing-artwork cache")
        let legacyURL = "https://legacy-artwork.invalid/cover=w256-h256-l90-rj"
        let legacyKey = SHA256.hash(data: Data(legacyURL.utf8)).map { String(format: "%02x", $0) }.joined()
        try image.write(to: images.appendingPathComponent(legacyKey))
        let migrated = await coldStore.cachedData(url: legacyURL.replacingOccurrences(of: "256", with: "1200"), headers: [:])
        check(migrated != nil, "older cached thumbnails supply a larger offline display without another request")

        let cacheRoot = root.appendingPathComponent("artwork-stream-cache")
        let cache = StreamFileCache(directory: cacheRoot, artworkStore: coldStore)
        var entry = QueueEntry.youtube(videoId: "artwork-stream", title: "Retained title", artist: "Fixture artist", thumbnailUrl: small)
        entry.artworkData = image
        await cache.remember(entry, allowNetwork: false)
        let source = root.appendingPathComponent("artwork-source.wav"); try Data("audio fixture".utf8).write(to: source)
        await cache.store(entry.id, path: source.path, codec: "PCM", youtubeVideoId: entry.id)
        let cachedPath = await cache.path(for: entry.id, allowGrowing: false)
        for _ in 0..<100 {
            if let path = cachedPath, await coldStore.data(audioPath: path) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let retained = await coldStore.data(audioPath: cachedPath!)
        let coldCache = StreamFileCache(directory: cacheRoot, artworkStore: coldStore)
        let entries = await coldCache.entries()
        check(retained != nil && entries.first?.entry?.title == entry.title && entries.first?.entry?.artworkData == nil && entries.first?.artworkReference != nil,
              "cached songs retain lightweight metadata and a cover independently of listening history")
        await cache.trim(limitBytes: 0)
        check(!FileManager.default.fileExists(atPath: cachedPath!) && !FileManager.default.fileExists(atPath: OfflineArtworkStore.coverURL(audioPath: cachedPath!).path), "audio-cache eviction removes its retained cover in the same budget")

        let base = URL(string: ProcessInfo.processInfo.environment["BITCHORD_DOWNLOAD_TEST_BASE_URL"]!)!
        let journal = FileDownloadTransport(directory: root.appendingPathComponent("artwork-transfer"), configuration: .ephemeral)
        defer { journal.invalidate() }
        _ = try await journal.download(id: "artwork-job", url: base.appendingPathComponent("audio"), headers: [:], allowsCellular: true, progress: { _, _ in })
        let downloadRoot = root.appendingPathComponent("artwork-download")
        try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        var fixtureIndex = FixtureIndex()
        let quality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
        let requestID = DownloadStore.digest(entry.source + "|" + entry.id + "|" + quality)
        var job = DownloadStore.Job(id: requestID, runID: "artwork-job", title: entry.title, status: .queued, entry: entry, quality: quality)
        job.resolved = .init(url: "", provider: "fixture", recordingIdentity: entry.id, codec: "PCM", kbps: 1411, lossless: true)
        fixtureIndex.jobs = [job]
        fixtureIndex.owners["single:" + requestID] = .init(id: "single:" + requestID, accountId: "", title: entry.title, requests: [requestID])
        try JSONEncoder().encode(fixtureIndex).write(to: downloadRoot.appendingPathComponent("index.json"))
        let downloads = DownloadStore(directory: downloadRoot, backend: JournalBackend(transport: journal))
        await downloads.waitUntilReady()
        for _ in 0..<100 { if downloads.jobs.first?.status == .done { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard let asset = downloads.asset(for: entry) else { preconditionFailure("Downloaded fixture was not published") }
        let savedCover = await LocalArtwork.shared.data(for: LocalArtwork.reference(path: asset.path))
        check(savedCover != nil && asset.entry.artworkData == nil, "download publication saves a reusable cover without retaining image blobs in the asset index")
        downloads.delete(asset.path)
        check(!FileManager.default.fileExists(atPath: OfflineArtworkStore.coverURL(audioPath: asset.path).path), "removing a downloaded song removes its cover sidecar")
    }
}
