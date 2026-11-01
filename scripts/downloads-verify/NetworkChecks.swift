import Foundation
import BitChordShared

final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64?)] = []
    func record(_ bytes: Int64, _ total: Int64?) { lock.withLock { values.append((bytes, total)) } }
    var last: (Int64, Int64?)? { lock.withLock { values.last } }
}

struct JournalBackend: DownloadBackend {
    let transport: FileDownloadTransport
    func resolve(_ entry: QueueEntry, quality: String) async throws -> String { fatalError("Completed background transfer resolved again") }
    func transfer(id: String, url: String, headers: [String: String], progress: @escaping DownloadProgressHandler) async throws -> String { fatalError("Completed background transfer downloaded twice") }
    func restoreTransfer(id: String, progress: @escaping DownloadProgressHandler) async throws -> String? { try await transport.restore(id: id, progress: progress) }
    func hasCompletedTransfer(id: String) -> Bool { transport.hasCompleted(id: id) }
    func cancel(id: String) { transport.cancel(id: id) }
    func finish(id: String) { transport.finish(id: id) }
}

private final class StreamDone: StreamDownloadBridgeDownloadCallback {
    let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(path: String?, message: String?) { handler(path, message) }
}
private final class StreamProgress: StreamDownloadBridgeProgressCallback {
    let handler: (Int64, Int64) -> Void
    init(_ handler: @escaping (Int64, Int64) -> Void) { self.handler = handler }
    func onProgress(received: Int64, total: Int64) { handler(received, total) }
}

enum NetworkChecks {
    @MainActor static func run(root: URL) async throws {
        func check(_ condition: Bool, _ text: String) { precondition(condition, text); print("PASS \(text)"); fflush(stdout) }
        let base = URL(string: ProcessInfo.processInfo.environment["BITCHORD_DOWNLOAD_TEST_BASE_URL"]!)!
        check(FileDownloadTransport.requiresRedirectControl(headers: ["Authorization": "fixture"]) &&
              FileDownloadTransport.requiresRedirectControl(headers: ["X-API-Key": "fixture"]) &&
              !FileDownloadTransport.requiresRedirectControl(headers: ["User-Agent": "fixture"]), "requests carrying credentials or custom headers use a session with redirect control")
        let journal = root.appendingPathComponent("transfer-journal")
        let transport = FileDownloadTransport(directory: journal, configuration: .ephemeral)
        defer { transport.invalidate() }
        let progress = ProgressSamples()
        let path = try await transport.download(id: "full", url: base.appendingPathComponent("audio"), headers: ["X-Fixture": "preserved"], allowsCellular: true, progress: progress.record)
        let expected = try Data(contentsOf: URL(fileURLWithPath: path))
        check(AudioDownloadContainer.fileExtension(at: path) == "wav" && expected.count > 500000, "ordinary 200 responses save complete audio with the actual container")
        check(progress.last?.0 == Int64(expected.count) && progress.last?.1 == Int64(expected.count), "native progress reaches the real expected byte length")
        let unknown = try await transport.download(id: "unknown", url: base.appendingPathComponent("unknown-length"), headers: [:], allowsCellular: true, progress: { _, _ in })
        check(try Data(contentsOf: URL(fileURLWithPath: unknown)) == expected, "a response without Content-Length saves the complete recording")
        let redirected = try await transport.download(id: "redirect", url: base.appendingPathComponent("redirect"), headers: ["Authorization": "fixture-only"], allowsCellular: true, progress: { _, _ in })
        check(try Data(contentsOf: URL(fileURLWithPath: redirected)) == expected, "same-origin redirects retain a working download")
        do {
            _ = try await transport.download(id: "credential-boundary", url: base.appendingPathComponent("redirect-cross-origin"), headers: ["Authorization": "fixture-only"], allowsCellular: true, progress: { _, _ in })
            preconditionFailure("An authenticated redirect crossed origins")
        } catch { check(!transport.hasCompleted(id: "credential-boundary"), "authenticated cross-origin redirects are rejected") }
        do {
            _ = try await transport.download(id: "custom-credential-boundary", url: base.appendingPathComponent("redirect-cross-origin"), headers: ["X-API-Key": "fixture-only"], allowsCellular: true, progress: { _, _ in })
            preconditionFailure("A custom credential crossed origins")
        } catch { check(!transport.hasCompleted(id: "custom-credential-boundary"), "custom authentication headers cannot cross redirect origins") }
        do {
            _ = try await transport.download(id: "playlist", url: base.appendingPathComponent("playlist"), headers: [:], allowsCellular: true, progress: { _, _ in })
            preconditionFailure("A playlist was published as audio")
        } catch { check(!transport.hasCompleted(id: "playlist"), "playlist bodies cannot become successful audio downloads") }
        do {
            let recovered = try await transport.download(id: "drop", url: base.appendingPathComponent("drop"), headers: [:], allowsCellular: true, progress: { _, _ in })
            check(try Data(contentsOf: URL(fileURLWithPath: recovered)) == expected, "URLSession recovered the interrupted response without truncation")
        } catch { check(!transport.hasCompleted(id: "drop"), "dropped connections do not publish truncated audio") }
        let retried = try await transport.download(id: "drop", url: base.appendingPathComponent("drop"), headers: [:], allowsCellular: true, progress: { _, _ in })
        check(try Data(contentsOf: URL(fileURLWithPath: retried)) == expected, "retry after a dropped connection preserves exact recording bytes")
        let cancelling = Task { try await transport.download(id: "cancelled", url: base.appendingPathComponent("slow"), headers: [:], allowsCellular: true, progress: { _, _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        transport.cancel(id: "cancelled"); cancelling.cancel()
        do { _ = try await cancelling.value; preconditionFailure("Cancelled transfer completed") } catch {}
        try await Task.sleep(for: .milliseconds(100))
        check(!transport.hasCompleted(id: "cancelled"), "cancellation settles the waiter without publishing an asset")

        let firstBytes = ProgressSamples()
        func direct(_ endpoint: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                StreamDownloadBridge.shared.streamSourceRequest(requestId: endpoint, url: base.appendingPathComponent(endpoint).absoluteString, headers: [:],
                    ready: StreamDone { path, _ in
                        if let path { firstBytes.record(((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0, Int64(expected.count)) }
                    }, done: StreamDone { path, message in
                        if let path { continuation.resume(returning: path) }
                        else { continuation.resume(throwing: NSError(domain: "Stream fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "Failed"])) }
                    })
            }
        }
        let streamed = try await direct("slow")
        check(try Data(contentsOf: URL(fileURLWithPath: streamed)) == expected && (firstBytes.last?.0 ?? Int64.max) < Int64(expected.count), "ordinary-source playback starts on a bounded opening while the same GET fills its cache")
        let resumed = try await direct("direct-drop")
        check(try Data(contentsOf: URL(fileURLWithPath: resumed)) == expected, "direct-source streaming resumes a dropped connection at the validated byte offset")
        let rangedProgress = ProgressSamples()
        let rangeURL = base.appendingPathComponent("ranges").absoluteString + "?clen=\(expected.count)"
        let ranged: String = try await withCheckedThrowingContinuation { continuation in
            StreamDownloadBridge.shared.downloadWithProgress(downloadId: "ranged-fixture", url: rangeURL, headers: [:],
                progress: StreamProgress { bytes, total in
                    rangedProgress.record(bytes, total)
                    if bytes == 128 * 1024 {
                        StreamDownloadBridge.shared.networkStatus(available: false)
                        Task { try? await Task.sleep(for: .milliseconds(150)); StreamDownloadBridge.shared.networkStatus(available: true) }
                    }
                }, callback: StreamDone { path, message in
                    if let path { continuation.resume(returning: path) }
                    else { continuation.resume(throwing: NSError(domain: "Range fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "Failed"])) }
                })
        }
        check(try Data(contentsOf: URL(fileURLWithPath: ranged)) == expected && rangedProgress.last?.0 == Int64(expected.count), "ranged audio survives an outage and a 503 without restarting or changing bytes")
        for temporary in [streamed, resumed, ranged] { for suffix in ["", ".len", ".grow", ".complete", ".failed"] { try? FileManager.default.removeItem(atPath: temporary + suffix) } }

        let cache = StreamFileCache(directory: root.appendingPathComponent("audio-cache"))
        let parts = StreamFileCache.qualityIdentity.split(separator: "|").map(String.init)
        let oldIdentity = (parts.first == "HIGH" ? "LOSSLESS" : "HIGH") + "|HIGH|" + (parts.last ?? "false")
        await cache.store("cached", path: path, codec: "PCM", kbps: 1411, quality: oldIdentity, youtubeVideoId: "cached")
        let strict = await cache.path(for: "cached", allowGrowing: false)
        let fallback = await cache.path(for: "cached", allowGrowing: false, allowQualityFallback: true)
        check(strict == nil && fallback != nil, "cache playback survives changed network quality settings")
        check(!StreamFileCache.compatiblePlaybackIdentity("HIGH|HIGH|false", "HIGH|HIGH|true"), "cache fallback still honors the music-only recording preference")
        let cachedURL = URL(fileURLWithPath: fallback!)
        var corrupt = expected; corrupt[100] ^= 1
        try corrupt.write(to: cachedURL)
        let invalid = await cache.path(for: "cached", allowGrowing: false, allowQualityFallback: true)
        check(invalid == nil, "changed cached bytes fail integrity validation")
        try Data().write(to: URL(fileURLWithPath: path + ".failed"))
        await cache.store("failed", path: path, codec: "PCM")
        let failedCache = await cache.path(for: "failed", allowGrowing: false, allowQualityFallback: true)
        check(failedCache == nil, "failed streams cannot become completed cache entries")
        try FileManager.default.removeItem(atPath: path + ".failed")
        await cache.trim(limitBytes: 0)
        check(!FileManager.default.fileExists(atPath: cachedURL.path) && !FileManager.default.fileExists(atPath: cachedURL.path + ".json"), "cache eviction removes audio and its manifest together")
        await cache.store("logical-track#prepared-fixture", path: path, codec: "PCM")
        let unverifiedAlias = await cache.path(for: "logical-track", allowQualityFallback: true)
        check(unverifiedAlias == nil, "an unverified alternative cannot poison the song's playback cache")
        await cache.markRecordingVerified(mediaID: "logical-track", cacheKey: "logical-track#prepared-fixture", sourcePath: path)
        let alias = await cache.path(for: "logical-track", allowQualityFallback: true)
        let originalOnly = await cache.path(for: "logical-track", allowQualityFallback: true, onlyOriginal: true)
        check(alias != nil && originalOnly == nil, "preferred-source cache is reusable by song identity without pretending to be the original YouTube upload")
        let coldCache = StreamFileCache(directory: root.appendingPathComponent("audio-cache"))
        let coldAlias = await coldCache.path(for: "logical-track", allowQualityFallback: true)
        check(coldAlias != nil, "preferred-source cache survives process restart")
        let changedSource = root.appendingPathComponent("changed-source.wav")
        try corrupt.write(to: changedSource)
        await coldCache.store("logical-track#prepared-fixture", path: changedSource.path, codec: "PCM")
        let replacedAlias = await coldCache.path(for: "logical-track", allowQualityFallback: true)
        check(replacedAlias == nil, "overwriting a verified cache key cannot inherit trust for different audio bytes")
        await coldCache.remove("logical-track")
        let deletedAlias = await coldCache.path(for: "logical-track", allowQualityFallback: true)
        check(deletedAlias == nil, "removing a cached song removes its preferred rendition too")

        let restored = FileDownloadTransport(directory: journal, configuration: .ephemeral)
        defer { restored.invalidate() }
        let entry = QueueEntry.youtube(videoId: "background-restored", title: "Background fixture", artist: "Validation")
        let downloadRoot = root.appendingPathComponent("background-store")
        try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        let quality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
        let request = DownloadStore.digest(entry.source + "|" + entry.id + "|" + quality)
        var fixture = FixtureIndex()
        var job = DownloadStore.Job(id: request, runID: "full", title: entry.title, status: .running, entry: entry, quality: quality)
        job.resolved = .init(url: "", provider: "fixture", recordingIdentity: entry.id, codec: "PCM", kbps: 1411, lossless: true)
        fixture.jobs = [job]
        fixture.owners["single:" + request] = .init(id: "single:" + request, accountId: "", title: entry.title, requests: [request])
        try JSONEncoder().encode(fixture).write(to: downloadRoot.appendingPathComponent("index.json"))
        NetworkQuality.shared.connected = false
        let store = DownloadStore(directory: downloadRoot, backend: JournalBackend(transport: restored))
        await store.waitUntilReady()
        for _ in 0..<100 { if store.jobs.first?.status == .done { break }; try await Task.sleep(for: .milliseconds(20)) }
        await store.waitForRefresh()
        check(store.jobs.first?.status == .done && store.items.count == 1 && store.isDownloaded(entry), "relaunch imports background downloads into Downloads without internet or a second resolve")
        let movedRoot = root.appendingPathComponent("moved-container")
        try FileManager.default.copyItem(at: downloadRoot, to: movedRoot)
        let movedStore = DownloadStore(directory: movedRoot, backend: JournalBackend(transport: restored))
        await movedStore.waitUntilReady()
        let movedAsset = movedStore.asset(for: entry)
        check(movedAsset?.path.hasPrefix(movedRoot.path + "/audio/") == true, "saved downloads rebase safely when iOS changes the app container path")
        NetworkQuality.shared.connected = true
    }
}
