import Foundation

@main struct VerifyOfflineCacheRules {
    static func main() {
        var generation = CacheGeneration()
        let beforeClear = generation.value
        precondition(generation.accepts(beforeClear), "current cache token is accepted")
        generation.advance()
        precondition(!generation.accepts(beforeClear), "a clear rejects work started before it")
        let afterClear = generation.value
        precondition(generation.accepts(afterClear), "new work after clear is accepted")
        generation.advance()
        generation.advance()
        precondition(!generation.accepts(afterClear), "repeated clears keep old work invalid")
        let clearPlan = CacheClearPolicy.pathsToDeferDeletion(
            audioPaths: ["active.m4a", "idle.flac"], activeReaderPaths: ["active.m4a", "unrelated.wav"]
        )
        precondition(clearPlan == ["active.m4a"], "clear defers only cached audio with an active reader")
        precondition(CacheClearPolicy.removingRepublishedPath("active.m4a", from: clearPlan).isEmpty, "a fresh cache entry replaces an old deferred-delete marker")

        let headersA = ["Authorization": "Bearer fixture", "Accept": "audio/*"]
        let headersB = ["accept": "audio/*", "authorization": "Bearer fixture"]
        let base = DownloadResumeSignature.make(url: "https://audio.example/stream", headers: headersA, allowsCellular: false)
        precondition(base == DownloadResumeSignature.make(url: "https://audio.example/stream", headers: headersB, allowsCellular: false), "header ordering and casing do not break resume reuse")
        precondition(base != DownloadResumeSignature.make(url: "https://audio.example/stream", headers: headersA, allowsCellular: true), "cellular policy changes invalidate resume data")
        precondition(base != DownloadResumeSignature.make(url: "https://audio.example/other", headers: headersA, allowsCellular: false), "a different source cannot reuse resume data")

        precondition(OfflinePlaybackSourcePolicy.blocksUncachedSource(source: "yt:video-id", isLocal: false, offlineEnabled: true), "offline mode blocks remote resolution without a local copy")
        precondition(!OfflinePlaybackSourcePolicy.blocksUncachedSource(source: "/Users/listener/Music/track.flac", isLocal: true, offlineEnabled: true), "offline mode permits a direct local file")
        precondition(!OfflinePlaybackSourcePolicy.blocksUncachedSource(source: "file:///Users/listener/Music/track.flac", isLocal: true, offlineEnabled: true), "offline mode permits a file URL")
        precondition(OfflinePlaybackSourcePolicy.blocksUncachedSource(source: "file:///Users/listener/Music/track.flac", isLocal: false, offlineEnabled: true), "a file URL is allowed only when the queue identifies it as local")
        precondition(OfflinePlaybackSourcePolicy.blocksUncachedSource(source: "", isLocal: true, offlineEnabled: true), "an empty local marker is not a playable saved file")
        precondition(!OfflinePlaybackSourcePolicy.shouldAutoSkipFailedTrack(offlineEnabled: true), "a missing offline track stays selected in the queue")
        precondition(OfflinePlaybackSourcePolicy.shouldAutoSkipFailedTrack(offlineEnabled: false), "online automatic playback can continue past a failed track")
        precondition(OfflinePlaybackSourcePolicy.blocksUncachedSource(source: "https://dav.example/music/track.flac", isLocal: true, offlineEnabled: true), "remote WebDAV URLs are blocked even when marked local by their provider")
        precondition(!OfflinePlaybackSourcePolicy.blocksUncachedSource(source: "yt:video-id", isLocal: false, offlineEnabled: false), "normal playback can resolve missing audio")
        precondition(OfflinePlaybackRules.settingKey == "offline_playback", "offline mode uses a durable dedicated setting")
        precondition(OfflinePlaybackRules.unavailableMessage.contains("no downloaded or cached audio"), "offline failure explains the missing local copy")
        precondition(DownloadRetryPolicy.disposition(failedCount: 0, connected: true, metered: false, wifiOnly: true) == .noFailedJobs, "retry all reports an empty failed set")
        precondition(DownloadRetryPolicy.disposition(failedCount: 3, connected: false, metered: false, wifiOnly: true) == .waitingForNetwork(count: 3), "retry all reports disconnected jobs as queued")
        precondition(DownloadRetryPolicy.disposition(failedCount: 2, connected: true, metered: true, wifiOnly: true) == .waitingForWiFi(count: 2), "retry all reports Wi-Fi-gated jobs as queued")
        precondition(DownloadRetryPolicy.disposition(failedCount: 2, connected: true, metered: true, wifiOnly: false) == .started(count: 2), "retry all starts on mobile when Wi-Fi-only is disabled")

        precondition(!PlaybackLoadIntentPolicy.shouldHoldQualityReload(shouldResumePlayback: true), "a playing track resumes after quality reload")
        precondition(PlaybackLoadIntentPolicy.shouldHoldQualityReload(shouldResumePlayback: false), "a paused or stopped track stays held after quality reload")

        precondition(StreamBitrateCapPolicy.bestJioSaavnRung(available: [48, 96, 160, 320], maxKbps: 64) == 48, "64 kbps cap chooses the highest supported rung within cap")
        precondition(StreamBitrateCapPolicy.bestJioSaavnRung(available: [48, 96, 160, 320], maxKbps: 128) == 96, "128 kbps cap chooses a known rung within cap")
        precondition(StreamBitrateCapPolicy.bestJioSaavnRung(available: [160, 320], maxKbps: 128) == nil, "no rung within a finite cap is unavailable")
        precondition(!StreamBitrateCapPolicy.acceptsKnownBitrate(nil, maxKbps: 128), "finite caps reject unknown source bitrate")
        precondition(!StreamBitrateCapPolicy.acceptsKnownBitrate(160, maxKbps: 128), "finite caps reject an over-cap source")
        precondition(StreamBitrateCapPolicy.acceptsKnownBitrate(nil, maxKbps: Int.max), "unlimited quality allows unknown source bitrate")
        precondition(StreamBitrateCapPolicy.blocksUnreducibleRemoteOriginal(maxKbps: 128), "finite caps block original remote files")
        precondition(!StreamBitrateCapPolicy.blocksUnreducibleRemoteOriginal(maxKbps: Int.max), "unlimited quality permits original remote files")
        precondition(StreamBitrateCapPolicy.jioSaavnRung(in: "https://audio.example/track_160.mp4?token=fixture") == 160, "rung detection preserves query URLs")
        precondition(StreamBitrateCapPolicy.jioSaavnURL("https://audio.example/track_320.mp4?token=fixture", selecting: 96) == "https://audio.example/track_96.mp4?token=fixture", "rung rewriting preserves query URLs")
        precondition(StreamBitrateCapPolicy.jioSaavnRung(in: "https://audio.example/track.mp4") == nil, "unknown URL quality is not inferred for finite caps")
        print("PASS: cache generations, offline playback and finite stream quality caps")
    }
}
