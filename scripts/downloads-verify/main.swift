import Foundation
import Observation
import BitChordShared

final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func set() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

// UI-independent collaborators. DownloadStore itself and QueueEntry are the app sources.
struct LocalTrack { var path = ""; var title = ""; var artist = ""; var durationSeconds = 0.0; var album = ""; var artwork: Data? }
@MainActor final class NetworkQuality { static let shared = NetworkQuality(); var connected = true; var metered = false }
@MainActor enum PageSession { static func generation() -> Int64 { AuthBridge.shared.sessionGeneration() } }
struct BridgeDownloadBackend: DownloadBackend {
    func resolve(_ entry: QueueEntry, quality: String) async throws -> String { throw URLError(.unsupportedURL) }
    func transfer(id: String, url: String, headers: [String: String], progress: @escaping DownloadProgressHandler) async throws -> String { throw URLError(.unsupportedURL) }
    func cancel(id: String) {}
}
struct TestSong {
    let entry: QueueEntry
    func asEntry(fallbackArt: String?) -> QueueEntry { entry }
}
struct TestPage { var songs: [TestSong]; var continuation: String?; var thumbnailUrl: String? = nil; var title = "Collection" }
@MainActor final class InnertubeDetail {
    static let shared = InnertubeDetail()
    var pages: [TestPage] = []; var fails = false
    func browse(browseId: String, force: Bool = false) async throws -> TestPage { try take() }
    func more(token: String) async throws -> TestPage { try take() }
    private func take() throws -> TestPage {
        if fails || pages.isEmpty { throw CocoaError(.fileReadUnknown) }
        return pages.removeFirst()
    }
}
struct FixtureIndex: Codable {
    var version = 1
    var owners: [String: DownloadStore.Owner] = [:]
    var assets: [String: DownloadStore.Asset] = [:]
    var bindings: [String: String] = [:]
    var jobs: [DownloadStore.Job] = []
    var migrated = true
    var pendingDeletes: Set<String>? = nil
}
final class FixtureBackend: DownloadBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0
    private(set) var transfers = 0
    var sharedRecording = false
    var resolutionFails = false
    var verificationFails = false
    private var resolutions = 0
    func resolve(_ entry: QueueEntry, quality: String) async throws -> String {
        lock.withLock { resolutions += 1 }
        if resolutionFails { throw CocoaError(.fileReadUnknown) }
        let id = sharedRecording ? "shared-recording" : entry.id
        return "{\"url\":\"fixture://audio\",\"provider\":\"fixture\",\"recordingIdentity\":\"\(id)\",\"codec\":\"PCM\",\"kbps\":1411,\"lossless\":true}"
    }
    func transfer(id: String, url: String, headers: [String: String], progress: @escaping DownloadProgressHandler) async throws -> String {
        lock.withLock { active += 1; maximum = max(maximum, active); transfers += 1 }
        defer { lock.withLock { active -= 1 } }
        progress(3, 13)
        try await Task.sleep(for: .milliseconds(350))
        progress(13, 13)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("audio fixture".utf8).write(to: path)
        return path.path
    }
    func cancel(id: String) {}
    func verify(path: String, entry: QueueEntry, provider: String) async throws {
        if verificationFails { throw NSError(domain: "Download", code: 6) }
    }
    func resolutionCount() -> Int { lock.withLock { resolutions } }
    func counts() -> (Int, Int) { lock.withLock { (maximum, transfers) } }
}

@main struct Verify {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitchord-download-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func assert(_ condition: @autoclosure () -> Bool, _ text: String) { if !condition() { fatalError(text) }; print("PASS \(text)"); fflush(stdout) }
        let entry = QueueEntry.youtube(videoId: "aaaaaaaaaaa", title: "Identical title", artist: "Artist")
        let other = QueueEntry.youtube(videoId: "bbbbbbbbbbb", title: entry.title, artist: entry.artist)
        let quality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
        let request = DownloadStore.digest(entry.source + "|" + entry.id + "|" + quality)
        let path = root.appendingPathComponent("private.wav").path
        let exported = root.appendingPathComponent("export.wav").path
        try Data("audio fixture".utf8).write(to: URL(fileURLWithPath: path)); try Data("export".utf8).write(to: URL(fileURLWithPath: exported))
        let asset = DownloadStore.Asset(id: "recording", path: path, provider: "youtube", recordingIdentity: entry.id, codec: "PCM", kbps: 1411, lossless: true, youtubeVideoId: entry.id, bytes: 13, sha256: DownloadStore.hashFile(path)!, entry: entry, managed: true)
        var fixture = FixtureIndex()
        fixture.assets[asset.id] = asset; fixture.bindings[request] = asset.id
        fixture.owners["first"] = .init(id: "first", browseId: "collection1", accountId: "guest", title: "One", requests: [request])
        fixture.owners["second"] = .init(id: "second", browseId: "collection2", accountId: "guest", title: "Two", requests: [request])
        let index = root.appendingPathComponent("index.json")
        try JSONEncoder().encode(fixture).write(to: index)
        let store = DownloadStore(directory: root, startWorker: false)
        assert(store.isDownloaded(entry) && !store.isDownloaded(other), "row presence index restores exact song identities")
        let absent = QueueEntry.youtube(videoId: "missing-file", title: entry.title, artist: entry.artist)
        var missingAsset = asset; missingAsset.id = "missing"; missingAsset.entry = absent; missingAsset.path = root.appendingPathComponent("absent.wav").path
        var missingFixture = fixture; missingFixture.assets[missingAsset.id] = missingAsset
        let missingRoot = root.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(missingFixture).write(to: missingRoot.appendingPathComponent("index.json"))
        let missingStore = DownloadStore(directory: missingRoot, startWorker: false)
        assert(!missingStore.isDownloaded(absent), "row presence index excludes missing files on restore")
        let rowInvalidated = ObservationFlag()
        withObservationTracking { _ = store.isDownloaded(entry) } onChange: { rowInvalidated.set() }
        store.jobs.append(.init(id: "progress", runID: "fixture", title: "Progress", status: .running, entry: other, quality: "HIGH"))
        store.jobs[0].attempts += 1
        assert(!rowInvalidated.value, "download job updates do not invalidate row presence reads")
        store.jobs.removeAll()
        assert(store.asset(for: entry) != nil, "verified download found")
        assert(store.selectedYouTubeVideoId(for: path) == entry.videoId, "saved YouTube origin survives local-file playback")
        assert(store.selectedYouTubeVideoId(for: exported) == nil, "an unrelated local file has no invented YouTube origin")
        var substitute = asset
        substitute.youtubeVideoId = nil
        substitute.provider = "lossless-substitute"
        var substituted = fixture
        substituted.assets[asset.id] = substitute
        let substituteRoot = root.appendingPathComponent("substitute")
        try FileManager.default.createDirectory(at: substituteRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(substituted).write(to: substituteRoot.appendingPathComponent("index.json"))
        let substituteStore = DownloadStore(directory: substituteRoot, startWorker: false)
        assert(substituteStore.selectedYouTubeVideoId(for: path) == entry.videoId, "history retains the selected YouTube song for a saved lossless substitute")
        let rejecting = FixtureBackend(); rejecting.verificationFails = true
        let rejectedStore = DownloadStore(directory: substituteRoot, startWorker: false, backend: rejecting)
        let rejectedAsset = await rejectedStore.playbackAsset(for: entry)
        assert(rejectedAsset == nil && FileManager.default.fileExists(atPath: path), "legacy substitutions fail closed without deleting the user's saved file")
        let acceptingStore = DownloadStore(directory: substituteRoot, startWorker: false, backend: FixtureBackend())
        let acceptedAsset = await acceptingStore.playbackAsset(for: entry)
        let acceptedIndex = try JSONDecoder().decode(FixtureIndex.self, from: Data(contentsOf: substituteRoot.appendingPathComponent("index.json")))
        assert(acceptedAsset?.recordingVerified == true && acceptedIndex.assets[asset.id]?.recordingVerified == true, "a verified legacy substitution persists its recording check")
        var originalAsset = asset; originalAsset.id = "original"; originalAsset.lossless = false; originalAsset.kbps = 128
        substituted.assets[originalAsset.id] = originalAsset
        try JSONEncoder().encode(substituted).write(to: substituteRoot.appendingPathComponent("index.json"))
        let pinnedStore = DownloadStore(directory: substituteRoot, startWorker: false, backend: rejecting)
        let pinnedAsset = await pinnedStore.playbackAsset(for: entry, onlyOriginal: true)
        assert(pinnedAsset?.id == originalAsset.id, "reverting to original chooses saved YouTube bytes even when a higher-quality substitute also exists")
        assert(store.asset(for: other) == nil, "identical title is not recording identity")
        assert(store.download(entry) == .alreadyExists, "individual ownership reuses quality-compatible asset")
        store.removeOwner("first"); assert(FileManager.default.fileExists(atPath: path), "overlapping owner preserves audio")
        store.removeOwner("second"); assert(FileManager.default.fileExists(atPath: path), "individual ownership survives collection removal")
        store.retainPlayback(paths: [path])
        store.removeOwner("single:" + request); assert(FileManager.default.fileExists(atPath: path), "reader reservation defers deletion")
        store.retainPlayback(paths: []); assert(!FileManager.default.fileExists(atPath: path), "last owner and reader release deletes private copy")
        assert(!store.isDownloaded(entry) && rowInvalidated.value, "asset removal updates observable row presence")
        assert(FileManager.default.fileExists(atPath: exported), "export survives private asset cleanup")
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let oldFile = legacyRoot.appendingPathComponent("Same title.wav")
        try Data("legacy bytes".utf8).write(to: oldFile)
        let migrationRoot = root.appendingPathComponent("migration")
        let migrated = DownloadStore(directory: migrationRoot, startWorker: false, legacyDirectory: legacyRoot)
        migrated.refresh()
        await migrated.waitForRefresh()
        assert(migrated.items.count == 1 && FileManager.default.fileExists(atPath: oldFile.path), "legacy migration preserves the original file")
        let migratedIndex = try JSONDecoder().decode(FixtureIndex.self, from: Data(contentsOf: migrationRoot.appendingPathComponent("index.json")))
        let legacyEntry = migratedIndex.assets.values.first!.entry
        assert(migrated.isDownloaded(legacyEntry), "legacy migration populates row presence")
        assert(migrated.provenance(for: oldFile.path) == nil, "legacy names do not establish YouTube provenance")
        migrated.retainPlayback(paths: [oldFile.path]); migrated.delete(oldFile.path)
        let delayed = DownloadStore(directory: migrationRoot, startWorker: false)
        delayed.retainPlayback(paths: [])
        assert(!FileManager.default.fileExists(atPath: oldFile.path), "explicit legacy deletion survives relaunch and waits for readers")
        let qualityRoot = root.appendingPathComponent("quality")
        try FileManager.default.createDirectory(at: qualityRoot, withIntermediateDirectories: true)
        let lowPath = qualityRoot.appendingPathComponent("low.m4a")
        try Data("audio fixture".utf8).write(to: lowPath)
        var low = asset; low.id = "low-recording"; low.path = lowPath.path
        low.codec = "AAC"; low.kbps = 96; low.lossless = false
        var qualityIndex = FixtureIndex(); qualityIndex.assets[low.id] = low
        try JSONEncoder().encode(qualityIndex).write(to: qualityRoot.appendingPathComponent("index.json"))
        let qualityStore = DownloadStore(directory: qualityRoot, startWorker: false)
        assert(qualityStore.asset(for: entry, quality: "STANDARD") != nil, "standard quality can reuse a matching lossy rendition")
        assert(qualityStore.asset(for: entry, quality: "HIGH") == nil && qualityStore.asset(for: entry, quality: "LOSSLESS") == nil, "lower quality never satisfies high or lossless requests")
        let newStore = DownloadStore(directory: root, startWorker: false)
        _ = newStore.download(other)
        var durable = try JSONDecoder().decode(FixtureIndex.self, from: Data(contentsOf: index))
        durable.jobs[0].status = .running
        try JSONEncoder().encode(durable).write(to: index)
        let recovered = DownloadStore(directory: root, startWorker: false)
        assert(recovered.jobs.first?.status == .queued, "running job recovered after relaunch")
        recovered.cancel(otherJobId(recovered)); assert(recovered.jobs.first?.cancelled == true, "cancellation remains durable")
        let cancelled = DownloadStore(directory: root, startWorker: false)
        assert(cancelled.jobs.first?.cancelled == true, "relaunch respects cancellation")
        InnertubeDetail.shared.pages = [TestPage(songs: [TestSong(entry: entry)], continuation: "next"), TestPage(songs: [TestSong(entry: other)], continuation: nil)]
        _ = await recovered.downloadCollection(browseId: "playlist")
        let ownedBefore = try Data(contentsOf: index)
        InnertubeDetail.shared.fails = true
        _ = await recovered.downloadCollection(browseId: "playlist")
        assert(try! Data(contentsOf: index) == ownedBefore, "failed refresh preserves complete membership")
        InnertubeDetail.shared.fails = false
        InnertubeDetail.shared.pages = [TestPage(songs: [TestSong(entry: other)], continuation: nil)]
        _ = await recovered.downloadCollection(browseId: "playlist")
        let membership = try JSONDecoder().decode(FixtureIndex.self, from: Data(contentsOf: index)).owners.values.first { $0.browseId == "playlist" }!
        assert(membership.requests.count == 1, "successful refresh commits ordered membership")
        try Data("corrupt index".utf8).write(to: index)
        let corrupt = DownloadStore(directory: root, startWorker: false); corrupt.clearDownloads()
        assert(try! String(contentsOf: index, encoding: .utf8) == "corrupt index", "corrupt index neither overwrites nor authorizes deletion")
        let backend = FixtureBackend()
        let worker = DownloadStore(directory: root.appendingPathComponent("worker"), legacyDirectory: legacyRoot, backend: backend)
        let entries = (0..<3).map { QueueEntry.youtube(videoId: "worker-\($0)", title: "Worker fixture", artist: "Validation") }
        entries.forEach { _ = worker.download($0) }
        for _ in 0..<50 { if worker.activity(for: entries[0])?.received == 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
        assert(worker.activity(for: entries[0])?.phase == .transferring && worker.activity(for: entries[0])?.fraction != nil, "song activity reports actual transfer bytes before completion")
        for _ in 0..<100 { if !worker.restoring && worker.jobs.count == 3 && worker.jobs.allSatisfy({ $0.status == .done }) { break }; try await Task.sleep(for: .milliseconds(50)) }
        assert(worker.jobs.count == 3 && worker.jobs.allSatisfy { $0.status == .done }, "pending worker completes independent jobs")
        assert(entries.allSatisfy { worker.isDownloaded($0) }, "completed downloads populate row presence")
        assert(worker.activity(for: entries[0])?.phase == .saved, "song activity becomes downloaded after publication")
        assert(backend.counts().0 == 2 && backend.counts().1 == 3, "worker permits exactly two concurrent transfers")
        let joiningBackend = FixtureBackend(); joiningBackend.sharedRecording = true
        let joining = DownloadStore(directory: root.appendingPathComponent("joining"), legacyDirectory: legacyRoot, backend: joiningBackend)
        _ = joining.download(entries[0]); _ = joining.download(entries[1])
        for _ in 0..<100 { if !joining.restoring && joining.jobs.count == 2 && joining.jobs.allSatisfy({ $0.status == .done }) { break }; try await Task.sleep(for: .milliseconds(50)) }
        assert(joiningBackend.counts().1 == 1, "matching resolved renditions join one transfer")
        assert(joining.asset(for: entries[0])?.path == joining.asset(for: entries[1])?.path, "shared recording is used during playback for each request")
        assert(joining.isDownloaded(entries[0]) && joining.isDownloaded(entries[1]), "shared recording badges include each request identity")
        joining.clearFinishedJobs()
        let rejoined = DownloadStore(directory: root.appendingPathComponent("joining"), startWorker: false)
        assert(rejoined.isDownloaded(entries[0]) && rejoined.isDownloaded(entries[1]), "request badges survive clearing jobs and relaunch")
        joining.clearDownloads()
        assert(!joining.isDownloaded(entries[0]) && !joining.isDownloaded(entries[1]), "clearing downloads removes all shared recording badges")
        let previousWifi = PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true)
        PlatformSettings.shared.putBoolean(key: "wifi_only_downloads", value: true)
        NetworkQuality.shared.metered = true
        let blockedBackend = FixtureBackend()
        let blocked = DownloadStore(directory: root.appendingPathComponent("wifi"), legacyDirectory: legacyRoot, backend: blockedBackend)
        _ = blocked.download(entries[0]); await blocked.waitUntilReady()
        try await Task.sleep(for: .milliseconds(100))
        assert(blocked.jobs[0].status == .queued && blockedBackend.counts().1 == 0, "Wi-Fi policy keeps intent pending")
        NetworkQuality.shared.metered = false
        blocked.networkPolicyChanged()
        for _ in 0..<100 { if blocked.jobs.allSatisfy({ $0.status == .done }) { break }; try await Task.sleep(for: .milliseconds(50)) }
        assert(blocked.jobs[0].status == .done, "worker resumes when unmetered connectivity returns")
        let stoppingBackend = FixtureBackend()
        let stopping = DownloadStore(directory: root.appendingPathComponent("wifi-active"), legacyDirectory: legacyRoot, backend: stoppingBackend)
        _ = stopping.download(entries[0]); await stopping.waitUntilReady()
        try await Task.sleep(for: .milliseconds(100))
        NetworkQuality.shared.metered = true; stopping.networkPolicyChanged()
        assert(stopping.jobs[0].status == .queued, "metered change cancels an active transfer and retains intent")
        NetworkQuality.shared.metered = false; stopping.networkPolicyChanged()
        for _ in 0..<100 { if stopping.jobs[0].status == .done { break }; try await Task.sleep(for: .milliseconds(50)) }
        assert(stopping.jobs[0].status == .done, "interrupted transfer resumes after Wi-Fi returns")
        let failedBackend = FixtureBackend(); failedBackend.resolutionFails = true
        let failing = DownloadStore(directory: root.appendingPathComponent("retries"), legacyDirectory: legacyRoot, backend: failedBackend)
        _ = failing.download(entries[0])
        await failing.waitUntilReady()
        for attempt in 1...3 {
            for _ in 0..<100 { if failing.jobs[0].attempts >= attempt && failing.jobs[0].status != .running { break }; try await Task.sleep(for: .milliseconds(10)) }
            if attempt < 3 { failing.jobs[0].retryAt = .distantPast; failing.networkPolicyChanged() }
        }
        failing.networkPolicyChanged()
        assert(failing.jobs[0].status == .failed && failedBackend.resolutionCount() == 3, "automatic retries stop after three attempts")
        PlatformSettings.shared.putBoolean(key: "wifi_only_downloads", value: previousWifi)
        let segments = SponsorBlockStore.parse(Data("""
            [{"category":"music_offtopic","actionType":"skip","segment":[1,3]},
             {"category":"sponsor","actionType":"skip","segment":[4,8]},
             {"category":"music_offtopic","actionType":"skip","segment":[8,5]},
             {"category":"music_offtopic","actionType":"skip","segment":[-1,5]},
             {"category":"music_offtopic","actionType":"mute","segment":[10,12]}]
            """.utf8))
        assert(segments == [NonMusicSegment(start: 1, end: 3)], "SponsorBlock accepts only valid music_offtopic skips")
        assert(SponsorBlockStore.parse(Data("not JSON".utf8)).isEmpty, "malformed SponsorBlock responses fail open")
        let logDirectory = root.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        for n in 0..<6 { try Data("RUN START interrupted".utf8).write(to: logDirectory.appendingPathComponent("old-\(n).log")) }
        let log = PlaybackDebugLog(directory: logDirectory)
        log.record("Authorization: Bearer secret credential")
        log.record("url=https://example.com/audio?signature=secret accountId=secret /Users/private/Music/file.wav")
        log.record("access_token=secret user@example.com")
        for _ in 0..<90 { log.record(String(repeating: "x", count: 32768)) }
        let report = try log.saveReport(snapshot: "accountId=secret https://example.com?token=secret")
        let reportText = try String(contentsOf: report, encoding: .utf8)
        assert(!reportText.contains("secret") && !reportText.contains("/Users/private") && !reportText.contains("user@example.com"), "diagnostic redaction removes credentials accounts URLs and paths")
        assert(reportText.contains("interrupted; no clean-exit marker"), "diagnostics identify interrupted previous runs")
        let runs = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
        assert(runs.count == 5, "diagnostics retain five recent runs")
        assert(runs.allSatisfy { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? NSNumber)?.intValue ?? 0 <= 2097152 }, "each diagnostic run remains below 2 MiB")
        log.markCleanExit(); log.clearHistory()
        assert(try! FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil).count == 1, "clear diagnostic history starts a fresh run")
        try? FileManager.default.removeItem(at: report)
        try await NetworkChecks.run(root: root)
        try await ArtworkChecks.run(root: root)
        print("Download and diagnostic persistence checks complete")
    }
    @MainActor static func otherJobId(_ store: DownloadStore) -> String { store.jobs[0].id }
}
