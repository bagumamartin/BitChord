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

// Resolving a playable source: downloads, YouTube, substitutes and custom
// sources, raced by module priority, and prefetching what plays next.
extension PlaybackController {
    /// Resolves the entry's source to an engine-loadable string. Local paths
    /// pass through unchanged; `"yt:<videoId>"` sources go through the
    /// `StreamResolver` to get a real HTTP URL, which has already been probed
    /// and proven to serve audio.
    ///
    /// The fetch goes through the shared `Http` client, so it shares a connection
    /// context with both the `player` request that minted the URL and the probe
    /// that cleared it — upstream's rule about why that has to be one stack. An
    /// earlier version ran a separate fetch here "because URLSession has a
    /// different TLS fingerprint"; that was a symptom of the split, not a cause.
    ///
    /// Upstream's ExoPlayer starts on the first bounded range. So do we: the first
    /// chunk is written and we return that path while later chunks keep appending.
    /// The engine's GrowingFile waits at EOF until `.complete`.
    struct ResolvedSource: Sendable {
        let source: String
        let headers: [String: String]
        let kbps: Int
        var lossless: Bool = false
        var codec: String? = nil
        var durationSec: Int? = nil
        /// Player-response loudness figure (YouTube only; substitutes, cache
        /// hits and local files carry none). Rides to the engine's
        /// normalization stage with the load.
        var loudnessDb: Double? = nil
        var clientName: String? = nil
        var resolutionAt: TimeInterval? = nil
        var origin: Origin = .other
        var youtubeVideoId: String? = nil

        enum Origin: String, Sendable { case local, cache, youtube, substitute, other }

        var format: QualityUpgrade.Format {
            QualityUpgrade.Format(
                codec: codec,
                kbps: kbps > 0 ? kbps : nil,
                lossless: lossless
            )
        }

        func asCandidate() -> QualityUpgrade.Candidate {
            QualityUpgrade.Candidate(
                url: source, headers: headers, format: format, durationSec: durationSec
            )
        }
    }

    struct ResolveOutcome: Sendable {
        let source: ResolvedSource
        let leftover: Task<QualityUpgrade.Candidate?, Never>?
        var decisionNote: String? = nil
    }

    struct ResolvePrefs: Sendable {
        let maxKbps: Int
        let wantLossless: Bool
        let jiosaavn: Bool
        let canSubstitute: Bool
        let preferMusicOnly: Bool

        @MainActor
        static func current() -> ResolvePrefs {
            let streamQuality = AppSettings.shared.effectiveAudioQuality(metered: NetworkQuality.shared.metered).name
            NSLog("[BitChord] playback quality requested=\(streamQuality) network=\(NetworkQuality.shared.metered ? "metered" : "unmetered")")
            return ResolvePrefs(
                maxKbps: Int(NetworkQuality.shared.maxKbps),
                wantLossless: streamQuality == "LOSSLESS",
                jiosaavn: PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true),
                canSubstitute: QualityUpgrade.canSubstituteForYouTube(),
                preferMusicOnly: PlatformSettings.shared.getBoolean(key: "prefer_music_only", default: false)
            )
        }
    }

    static func resolveSource(
        _ entry: QueueEntry, prefs: ResolvePrefs,
        preparationBudget: TimeInterval? = nil,
        freshResolution: Bool = false,
        latencyResolved: PlaybackLatencyRecorder? = nil
    ) async throws -> ResolveOutcome {
        await DownloadStore.shared.waitUntilReady()
        try Task.checkCancellation()
        if !entry.isLocal { await StreamFileCache.shared.remember(entry) }
        let pinnedOriginal = entry.source.hasPrefix("yt:") && OriginalVersion.shared.isPinned(videoId: entry.id)
        if let asset = await DownloadStore.shared.playbackAsset(for: entry, onlyOriginal: pinnedOriginal) {
            await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cached", "download")
            return ResolveOutcome(source: ResolvedSource(source: asset.path, headers: [:], kbps: asset.kbps,
                lossless: asset.lossless, codec: asset.codec, origin: .local, youtubeVideoId: asset.youtubeVideoId), leftover: nil)
        }
        if !freshResolution, !entry.isLocal,
           let cached = await StreamFileCache.shared.path(for: entry.id, allowQualityFallback: true,
                onlyOriginal: entry.source.hasPrefix("yt:") && OriginalVersion.shared.isPinned(videoId: entry.id)) {
            let metadata = await StreamFileCache.shared.metadata(at: cached)
            let musicOnlyVideo = prefs.preferMusicOnly && entry.isVideo && !OriginalVersion.shared.isPinned(videoId: entry.id)
            if (!musicOnlyVideo || (metadata?.playbackMediaId == entry.id && metadata?.recordingVerified == true)),
               let verified = NativeStreamVerifier.verifyCachedFile(cached) {
            await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cached", "stream cache")
            return ResolveOutcome(source: ResolvedSource(source: cached, headers: [:],
                kbps: verified.estimatedKbps.map(Int.init) ?? metadata?.kbps ?? 0,
                lossless: verified.format.losslessPcm, codec: verified.format.codec,
                durationSec: metadata?.durationSeconds, loudnessDb: metadata?.relativeLoudnessDb,
                clientName: "cache", origin: .cache, youtubeVideoId: metadata?.youtubeVideoId), leftover: nil)
            }
        }
        if entry.source.hasPrefix("saavn:") || entry.id.hasPrefix("saavn:") {
            let id = entry.source.hasPrefix("saavn:") ? String(entry.source.dropFirst(6)) : String(entry.id.dropFirst(6))
            if let hit = await JioSaavn.streamURL(for: id) {
                await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cold", "JioSaavn")
                return ResolveOutcome(
                    source: ResolvedSource(
                        source: hit.url, headers: [:], kbps: hit.kbps,
                        lossless: false, origin: .substitute
                    ),
                    leftover: nil
                )
            }
            throw InnertubeStreamResolver.StreamError(message: "JioSaavn had no stream")
        }
        if entry.source.hasPrefix("src:") || entry.id.hasPrefix("src:") {
            // An addon search row keeps its own `src:` key rather than a video
            // id, so it resolves through the source resolver's own ordering —
            // its source first, then any enabled source that has the recording.
            let key = entry.source.hasPrefix("src:") ? entry.source : entry.id
            let report = PlaybackLookupReport()
            if let stream = await SourceSearch.shared.stream(
                key: key, title: entry.title, artist: entry.artist,
                // Unknown is not zero: a 0 s runtime would be read as a real
                // length and reject every match.
                durationSec: entry.durationSeconds > 0 ? Int(entry.durationSeconds.rounded()) : nil,
                diagnostic: report.record
            ) {
                await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cold", "source substitute")
                return ResolveOutcome(
                    source: ResolvedSource(
                        source: stream.url, headers: stream.headers, kbps: stream.kbps ?? 0,
                        lossless: stream.lossless, codec: stream.codec,
                        durationSec: stream.durationSec, origin: .substitute
                    ),
                    leftover: nil, decisionNote: report.explanation
                )
            }
            throw InnertubeStreamResolver.StreamError(message: "That source had no stream")
        }
        #if DEBUG
        if entry.source.hasPrefix("dolby-test:") {
            await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cold", "fixture")
            return ResolveOutcome(source: ResolvedSource(source: String(entry.source.dropFirst(11)), headers: [:], kbps: 0, codec: "eac3-joc"), leftover: nil)
        }
        #endif
        guard entry.source.hasPrefix("yt:") else {
            await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cold", "WebDAV/local")
            // A file on a remote library plays from its own address, and that address
            // needs the share's credential — the same header the cover fetch and the
            // listing used, asked of the one rule that decides which requests may carry
            // it. Empty for a local path and for a JioSaavn URL, which is why this is
            // safe on the path every non-YouTube row takes.
            return ResolveOutcome(
                source: ResolvedSource(
                    source: entry.source,
                    headers: WebDavBridge.shared.playbackHeaders(fileUrl: entry.source),
                    kbps: 0,
                    codec: ["ac3", "ec3", "eac3"].contains(URL(string: entry.source)?.pathExtension.lowercased() ?? "") ? URL(string: entry.source)?.pathExtension : nil,
                    origin: .local
                ),
                leftover: nil
            )
        }
        let videoId = String(entry.source.dropFirst(3))
        if !freshResolution, !(prefs.preferMusicOnly && entry.isVideo && !OriginalVersion.shared.isPinned(videoId: videoId)),
           let growing = streamGate.lock.withLock({ streamGate.growing[videoId] }),
           FileManager.default.fileExists(atPath: growing),
           !FileManager.default.fileExists(atPath: growing + ".failed"),
           !FileManager.default.fileExists(atPath: growing + ".playback-cancelled") {
            await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cached", "stream cache")
            return ResolveOutcome(
                source: ResolvedSource(
                    source: growing, headers: [:], kbps: 0, durationSec: streamGate.lock.withLock { streamGate.durations[videoId] }, origin: .cache
                ),
                leftover: nil
            )
        }
        // A track the listener has reverted is held on YouTube's own upload, so
        // there is nothing to look for: a substitute found here would be the
        // exact thing they rejected. This has to be checked *before* the lookup
        // rather than after it, or a revert still costs a network round trip to
        // arrive at the answer it already knew.
        guard await NetworkQuality.shared.connected else { throw URLError(.notConnectedToInternet) }
        if OriginalVersion.shared.isPinned(videoId: videoId) {
            let source = try await Self.resolveYouTube(videoId: videoId, prefs: prefs)
            await latencyResolved?(source.resolutionAt ?? ProcessInfo.processInfo.systemUptime,
                                   "cold", source.clientName ?? "unknown")
            return ResolveOutcome(source: source, leftover: nil)
        }
        return try await resolveWithModulePriority(
            entry, videoId: videoId, prefs: prefs, preparationBudget: preparationBudget, latencyResolved: latencyResolved
        )
    }

    /// Upstream `resolveWithModulePriority`: start YouTube and substitutes
    /// together. The selected upload starts without waiting for a catalogue
    /// search. The preferred lookup is retained for an audio-verified upgrade.
    private static func resolveWithModulePriority(
        _ entry: QueueEntry, videoId: String, prefs: ResolvePrefs,
        preparationBudget: TimeInterval?,
        latencyResolved: PlaybackLatencyRecorder? = nil
    ) async throws -> ResolveOutcome {
        let report = PlaybackLookupReport()
        let lookup = Task<QualityUpgrade.Candidate?, Never> {
            if preparationBudget != nil && prefs.canSubstitute && !entry.isVideo {
                let stream = await SourceSubstitution.prefetch(
                    title: entry.title, artist: entry.artist,
                    durationSec: entry.durationSeconds > 0 ? Int(entry.durationSeconds.rounded()) : nil,
                    album: entry.albumName,
                    isExplicit: entry.isExplicit.map { KotlinBoolean(value: $0) },
                    diagnostic: report.record
                )
                return stream.map { QualityUpgrade.Candidate(
                    url: $0.url, headers: $0.headers,
                    format: QualityUpgrade.Format(codec: $0.codec, kbps: $0.kbps, lossless: $0.lossless),
                    durationSec: $0.durationSec
                ) }
            }
            return await Self.resolveSubstitute(entry, prefs: prefs, diagnostic: report.record)?.asCandidate()
        }
        let fallback = Task<ResolvedSource, Error> {
            try await Self.resolveYouTube(videoId: videoId, prefs: prefs)
        }

        // Prefer-music-only for a music video: the video's own upload is the
        // wrong answer when the catalogue audio was asked for, so the race is
        // not run at all — the substitute lookup is awaited, and YouTube's
        // upload is only the fallback when the lookup misses. Upstream does the
        // same switch after the fact (`switchToMusicOnly`); here the wait
        // happens before anything starts, so the video never plays first.
        if prefs.preferMusicOnly, entry.isVideo {
            if let stream = await lookup.value {
                _ = try await fallback.value
                let selected = ResolveOutcome(
                    source: ResolvedSource(
                        source: stream.url, headers: stream.headers,
                        kbps: stream.format.kbps ?? 0,
                        lossless: stream.format.lossless, codec: stream.format.codec,
                        durationSec: stream.durationSec,
                        origin: .substitute
                    ),
                    leftover: nil
                )
                let buffered = try await bufferPreparedSource(selected, mediaId: entry.id)
                if buffered.source.source.hasPrefix("/"),
                   await RecordingIdentityVerifier.matches(videoId: videoId, candidate: buffered.source.source, allowTimingEdits: true) {
                    await StreamFileCache.shared.markRecordingVerified(mediaID: entry.id,
                        cacheKey: "\(entry.id)#prepared-\(DiskCache.hashName(stream.url))", sourcePath: buffered.source.source)
                    await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cold", "verified source substitute")
                    return buffered
                }
                PlaybackDebugLog.shared.record("music-only candidate rejected: recording identity could not be verified", about: videoId)
            }
            let source = try await fallback.value
            await latencyResolved?(source.resolutionAt ?? ProcessInfo.processInfo.systemUptime,
                                   "cold", source.clientName ?? "unknown")
            return ResolveOutcome(source: source, leftover: nil, decisionNote: source.lossless
                ? "A preferred source supplied verified lossless audio." : report.explanation)
        }

        let race = PlaybackSourceRace<QualityUpgrade.Candidate, ResolvedSource>(preferPrimary: false)
        _ = Task { await race.finishLookup(await lookup.value) }
        _ = Task { await race.finishFallback(try? await fallback.value) }

        let waitSeconds = 0.0
        switch await race.wait(timeoutNanoseconds: UInt64(waitSeconds * 1_000_000_000)) {
        case .preferred(let stream):
            // Metadata identifies a candidate, not its audio. The selected
            // upload remains the reference while the upgrade path verifies it.
            let source = try await fallback.value
            await latencyResolved?(source.resolutionAt ?? ProcessInfo.processInfo.systemUptime, "cold", source.clientName ?? "YouTube")
            return ResolveOutcome(source: source, leftover: Task { stream },
                decisionNote: "A preferred copy is waiting for recording verification.")
        case .fallback(let source):
            // Preserve the slower substitute lookup for the in-playback quality
            // upgrade path instead of making it delay the first audible sample.
            await latencyResolved?(source.resolutionAt ?? ProcessInfo.processInfo.systemUptime,
                                   "cold", source.clientName ?? "unknown")
            return ResolveOutcome(source: source, leftover: lookup, decisionNote: report.explanation ?? (prefs.canSubstitute
                ? "Preferred sources did not provide a verified stream before the playback deadline."
                : "YouTube is the selected source."))
        case .timedOut:
            // The selected YouTube upload carries first sound; the patient
            // lookup stays available to the verified quality-upgrade path.
            do {
                let source = try await fallback.value
                await latencyResolved?(source.resolutionAt ?? ProcessInfo.processInfo.systemUptime,
                                       "cold", source.clientName ?? "unknown")
                return ResolveOutcome(source: source, leftover: lookup, decisionNote: report.explanation ?? (prefs.canSubstitute
                ? "Preferred sources did not provide a verified stream before the playback deadline."
                : "YouTube is the selected source."))
            } catch {
                // The lookup is the first thing to fall back on now, so it is
                // awaited rather than cancelled.
                let source = try await recoverRefusedTrack(entry, videoId: videoId, prefs: prefs, lookup: lookup, error: error)
                await latencyResolved?(ProcessInfo.processInfo.systemUptime, "cold", source.clientName ?? "recovered")
                return ResolveOutcome(source: source, leftover: nil, decisionNote: source.lossless
                ? "A preferred source supplied verified lossless audio." : report.explanation)
            }
        case .cancelled:
            lookup.cancel()
            fallback.cancel()
            throw CancellationError()
        case .none:
            // Preserve the resolver's actual failure instead of replacing
            // account/CDN errors with an uninformative "No stream".
            let source: ResolvedSource
            do {
                source = try await fallback.value
            } catch {
                source = try await recoverRefusedTrack(entry, videoId: videoId, prefs: prefs, lookup: lookup, error: error)
            }
            await latencyResolved?(source.resolutionAt ?? ProcessInfo.processInfo.systemUptime,
                                   "cold", source.clientName ?? "unknown")
            return ResolveOutcome(source: source, leftover: nil, decisionNote: source.lossless
                ? "A preferred source supplied verified lossless audio." : report.explanation)
        }
    }

    /// What plays when YouTube refused every way this app has of asking for a
    /// track: the same recording from another enabled catalogue, or else the
    /// track's YouTube Music counterpart — the Song/Video pairing YouTube itself
    /// publishes — when its length agrees with the song's. Only when both miss
    /// does the original failure stand, and the queue moves on.
    private static func recoverRefusedTrack(
        _ entry: QueueEntry, videoId: String, prefs: ResolvePrefs,
        lookup: Task<QualityUpgrade.Candidate?, Never>, error: Error
    ) async throws -> ResolvedSource {
        if let stream = await lookup.value { QualityUpgrade.shelve(videoId, stream: stream) }
        // The counterpart is another YouTube ask, which a bot check refuses too.
        if !InnertubeStreamResolver.StreamError.isBotCheck(error),
           let twin = await counterpart(of: entry, videoId: videoId) {
            do {
                var source = try await resolveYouTube(videoId: twin, prefs: prefs)
                source.clientName = "counterpart " + (source.clientName ?? "unknown")
                PlaybackDebugLog.shared.record("YouTube refused; playing its counterpart \(twin)", about: videoId)
                return source
            } catch {
                PlaybackDebugLog.shared.record("counterpart \(twin) failed too: \(error.localizedDescription)", about: videoId)
            }
        }
        throw error
    }

    /// YouTube Music's explicit counterpart of [entry], when it runs within three
    /// seconds of the song: an edit that long or short is not the same audio.
    private static func counterpart(of entry: QueueEntry, videoId: String) async -> String? {
        let songSeconds = entry.durationSeconds
        guard songSeconds > 0 else { return nil }
        let candidates: [CounterpartCandidate] = await withCheckedContinuation { continuation in
            VideoVersionBridge.shared.find(
                videoId: videoId, title: entry.title, artist: entry.artist,
                durationText: entry.durationText ?? QueueEntry.formatDuration(songSeconds),
                callback: CounterpartAdapter { json, _ in
                    continuation.resume(returning: json.flatMap {
                        try? JSONDecoder().decode([CounterpartCandidate].self, from: Data($0.utf8))
                    } ?? [])
                }
            )
        }
        return candidates.first { candidate in
            guard candidate.source == "counterpart", candidate.videoId != videoId,
                  let seconds = QueueEntry.seconds(fromDurationText: candidate.durationText) else { return false }
            return abs(seconds - songSeconds) <= 3
        }?.videoId
    }

    /// Innertube URL + growing local file, the path that starts playback earliest.
    ///
    /// ## What happens when a URL is refused
    ///
    /// Never the same URL again. A googlevideo URL is *bound to the session that
    /// minted it*, and re-fetching it with the same headers is the most reliable
    /// way to talk a session into being throttled; the reason it was refused is
    /// the reason it would be refused again.
    ///
    /// Instead the refusal walks a ladder, each rung a different variable:
    ///
    ///  1. **Another client.** The bridge has already told the resolver, which
    ///     forgot the URL and set aside the client that minted it, so asking
    ///     `player` again gets a new URL from a different client — up to
    ///     [clientsPerSession] of them.
    ///  2. **A fresh session.** When that many clients refuse one track in a row,
    ///     the session is the likelier culprit (a stale player config, a PoToken
    ///     bound to an old challenge), so it is rebuilt — new config, cipher and
    ///     token — the refused clients are forgiven, and the walk runs once more.
    ///  3. Past this function, the caller falls back to the same recording in
    ///     another catalogue, then to the track's YouTube Music counterpart.
    ///
    /// A *transport* failure is the opposite case and deliberately does not
    /// re-resolve: the URL was served once, so it is alive, and handing it to the
    /// engine — which has its own connection management and its own retries — is a
    /// better second chance than minting a new URL for a problem the new URL would
    /// not fix.
    private static func resolveYouTube(
        videoId: String, prefs: ResolvePrefs
    ) async throws -> ResolvedSource {
        var refusedClients: [String] = []
        var rebuilt = false
        func record(_ error: Error) {
            // The per-client reasons, which the shared module carries and the
            // sentence a listener sees does not. Recorded here because this is where
            // the debug log lives, and a report that says "playback failed" is worth
            // nothing next to one that says which client refused and why.
            if let streamError = error as? InnertubeStreamResolver.StreamError {
                PlaybackDebugLog.shared.record(streamError.raw, about: videoId)
            }
        }
        /// Rung 2: a rebuilt session, asked once.
        func rebuildAndResolve(after error: Error) async throws -> ResolvedYouTubeStream {
            // A bot check is the network's verdict; a new session asks again
            // from the same address and only adds to the suspicion.
            guard !rebuilt, !InnertubeStreamResolver.StreamError.isBotCheck(error) else { throw error }
            rebuilt = true
            PlaybackDebugLog.shared.record(
                "no client would serve this track (\(refusedClients.isEmpty ? "extraction failed" : refusedClients.joined(separator: ", "))); rebuilding the session and asking again",
                about: videoId
            )
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                PlayerBridge.shared.rebuildSession(videoId: videoId, callback: DoneAdapter { done.resume() })
            }
            refusedClients.removeAll()
            do {
                return try await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: prefs.maxKbps)
            } catch {
                record(error)
                throw error
            }
        }
        /// The next URL after a refusal: another client, then a rebuilt session.
        func nextStream() async throws -> ResolvedYouTubeStream {
            let exhausted = InnertubeStreamResolver.StreamError(
                message: "Every client refused this track (\(refusedClients.joined(separator: ", ")))"
            )
            guard refusedClients.count < Self.clientsPerSession else {
                return try await rebuildAndResolve(after: exhausted)
            }
            do {
                return try await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: prefs.maxKbps)
            } catch {
                // The catalogue ran out of clients before the budget did.
                record(error)
                return try await rebuildAndResolve(after: error)
            }
        }
        var stream: ResolvedYouTubeStream
        do {
            stream = try await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: prefs.maxKbps)
        } catch {
            record(error)
            stream = try await rebuildAndResolve(after: error)
        }
        var resolvedAt = ProcessInfo.processInfo.systemUptime
        var rangeRetry = 0
        while true {
            if let seconds = stream.durationSeconds, seconds > 0 {
                streamGate.lock.withLock { streamGate.durations[videoId] = seconds }
            }
            do {
                let localPath = try await streamViaKtor(
                    videoId: videoId, url: stream.url, headers: stream.headers,
                    codec: stream.mimeType.lowercased().contains("opus") ? "Opus" : "AAC",
                    kbps: stream.kbps, relativeLoudnessDb: stream.loudnessDb,
                    youtubeVideoId: videoId, durationSeconds: stream.durationSeconds,
                    maxKbps: prefs.maxKbps, expectedMimeType: stream.mimeType,
                    firstRangeRetry: rangeRetry
                )
                return ResolvedSource(
                    source: localPath, headers: [:], kbps: stream.kbps,
                    durationSec: stream.durationSeconds, loudnessDb: stream.loudnessDb,
                    clientName: stream.clientName, resolutionAt: resolvedAt,
                    origin: .youtube, youtubeVideoId: videoId
                )
            } catch {
                let reason = (error as? InnertubeStreamResolver.StreamError)?.message
                let rejected = StreamDownloadBridge.shared.isInvalidFirstRange(message: reason)
                    || StreamDownloadBridge.shared.isRefusal(message: reason)
                guard rejected else {
                    DebugLog.shared.d(message: "\(videoId): stream failed: \(reason ?? "\(error)")")
                    return ResolvedSource(
                        source: stream.url, headers: stream.headers, kbps: stream.kbps,
                        durationSec: stream.durationSeconds, loudnessDb: stream.loudnessDb,
                        clientName: stream.clientName, resolutionAt: resolvedAt,
                        origin: .youtube, youtubeVideoId: videoId
                    )
                }
                refusedClients.append(stream.clientName ?? "unknown")
                rangeRetry += 1
                DebugLog.shared.d(message: "\(videoId): \(stream.clientName ?? "a client") refused (\(reason ?? "no reason")); asking another")
                stream = try await nextStream()
                resolvedAt = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    /// Clients asked per session before the session itself is rebuilt. Upstream
    /// asks three and then gives the track up; this asks four, then rebuilds the
    /// session and asks again, because a burst of refusals is far more often the
    /// session than the track.
    private static let clientsPerSession = 4

    /// Catalogues ranked above YouTube — first match that is the same recording.
    /// The cross-source race, delegated to the shared resolver.
    ///
    /// This used to be a hand-rolled `withTaskGroup` over the custom HTTP source,
    /// the JS module host and JioSaavn, with "JioSaavn must beat 256 kbps" as the
    /// only quality bar, no notion of the user's ranking, and no recording check at
    /// all beyond a runtime comparison the caller had to remember to apply. It could
    /// not be made correct without the parts that are judgement, which now live in
    /// the shared module's `SourceResolver`:
    ///
    ///  - `TrackMatcher` checks catalogue metadata before opening a candidate.
    ///    The playback/download boundaries also verify decoded audio identity.
    ///  - Rank decides who is asked. Lossless compares completed answers within
    ///    a bounded window instead of selecting only the first responder.
    ///  - `playingDurationSec` set routes this through the *upgrade* path, whose bar
    ///    is "beats what is actually playing" rather than "satisfies the request",
    ///    and which waits for every source so a slow one holding the FLAC still
    ///    gets to serve it mid-track rather than being dropped for a fast 320.
    static func resolveSubstitute(
        _ entry: QueueEntry, prefs: ResolvePrefs, waitForAll: Bool = false,
        playingDurationSec: Int? = nil, playing: QualityUpgrade.Format? = nil,
        diagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ResolvedSource? {
        // Nothing configured outranks YouTube, so the race cannot be won and asking
        // would be pure latency. Answerable from the source list alone, with no
        // search, which is why it is safe to call before the track is resolved.
        guard prefs.canSubstitute else { return nil }

        let stream = await SourceSubstitution.substitute(
            title: entry.title,
            artist: entry.artist,
            durationSec: playingDurationSec ?? (entry.durationSeconds > 0 ? Int(entry.durationSeconds.rounded()) : nil),
            album: entry.albumName,
            isExplicit: entry.isExplicit.map { KotlinBoolean(value: $0) },
            isVideo: entry.isVideo,
            playing: (playing ?? (waitForAll ? QualityUpgrade.Format(codec: nil, kbps: nil, lossless: false) : nil)).map { SourceSubstitution.Format(codec: $0.codec, kbps: $0.kbps, lossless: $0.lossless) },
            diagnostic: diagnostic
        )
        guard let stream else { return nil }
        return ResolvedSource(
            source: stream.url,
            headers: stream.headers,
            kbps: stream.kbps ?? 0,
            lossless: stream.lossless, codec: stream.codec,
            durationSec: stream.durationSec,
            origin: .substitute
        )
    }

    private static func resolveCustom(title: String, artist: String) async -> ResolvedSource? {
        await withCheckedContinuation { cont in
            SourceBridge.shared.resolveCustom(title: title, artist: artist, quality: "LOSSLESS", callback: CustomStreamAdapter { json, _ in
                guard let json, let data = json.data(using: .utf8),
                      let hit = try? JSONDecoder().decode(CustomHit.self, from: data) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: ResolvedSource(
                    source: hit.url, headers: [:], kbps: hit.kbps,
                    lossless: hit.lossless == true, origin: .substitute
                ))
            })
        }
    }

    private struct CustomHit: Codable {
        let url: String
        let kbps: Int
        let lossless: Bool?
    }

    /// Buffer the chosen next-track rendition under its own cache identity.
    /// A failed speculative download retains the remote stream for normal loading.
    static func bufferPreparedSource(_ outcome: ResolveOutcome, mediaId: String) async throws -> ResolveOutcome {
        let chosen = outcome.source
        guard chosen.origin == .substitute,
              chosen.source.hasPrefix("https://") || chosen.source.hasPrefix("http://"),
              !PlaybackCodecCapabilities.shared.canRenderDolby(codec: chosen.codec, headers: chosen.headers) else {
            return outcome
        }
        do {
            let path = try await streamViaKtor(
                videoId: "\(mediaId)#prepared-\(DiskCache.hashName(chosen.source))",
                url: chosen.source, headers: chosen.headers,
                codec: chosen.codec ?? "unknown", kbps: chosen.kbps,
                durationSeconds: chosen.durationSec
            )
            try Task.checkCancellation()
            let buffered = ResolvedSource(
                source: path, headers: [:], kbps: chosen.kbps,
                lossless: chosen.lossless, codec: chosen.codec,
                durationSec: chosen.durationSec, origin: .substitute
            )
            return ResolveOutcome(source: buffered, leftover: outcome.leftover, decisionNote: outcome.decisionNote)
        } catch is CancellationError {
            outcome.leftover?.cancel()
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            PlaybackDebugLog.shared.record("next-track buffer unavailable; retaining selected stream", about: mediaId)
            return outcome
        }
    }

    /// Warm short-lived stream URLs for the upcoming queue window. This does
    /// not request media bytes; the opening range remains coupled to playback.
    func warmUpcoming(around index: Int, generation: UInt64) {
        guard state == .playing || state == .buffering || state == .paused else { return }
        guard NetworkQuality.shared.connected, repeatMode != .one else {
            urlPrefetchTask?.cancel(); urlPrefetchFingerprint = nil
            return
        }
        // Repeat-one never arms a different next track into the engine, but the
        // song after the loop still has to be measured while the loop runs —
        // otherwise turning repeat off starts a cold whole-track decode with
        // seconds left (upstream requestAnalysisAround). Automix self-mix only
        // needs the current file, which is already loaded.
        // The shared resolver caches issued URLs for 20 seconds. Keep the work
        // within that freshness window and cap it to a visible queue-sized set.
        let metered = NetworkQuality.shared.metered
        let prefetchCount = metered ? 1 : 3
        let prefetch = queue.dropFirst(index + 1).prefix(prefetchCount).filter {
            $0.source.hasPrefix("yt:") && !$0.id.hasPrefix("saavn:")
        }
        let prefs = ResolvePrefs.current()
        let fingerprint = "\(prefs.maxKbps)|metered=\(metered)|" + prefetch.map(\.id).joined(separator: "|")
        guard fingerprint != urlPrefetchFingerprint else { return }
        urlPrefetchFingerprint = fingerprint
        urlPrefetchTask?.cancel()
        guard !prefetch.isEmpty else { return }
        PlaybackDebugLog.shared.record("latency: prefetch url \(prefetch.count) rows")
        urlPrefetchTask = Task.detached(priority: .utility) { [weak self] in
            for entry in prefetch {
                guard !Task.isCancelled else { return }
                let id = entry.id
                let stillQueued = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    guard self.playGeneration == generation,
                          self.queue.contains(where: { $0.id == id }) else { return false }
                    // A path change can happen while this sequential read-ahead
                    // is running. Keep the first queued item, but stop before
                    // resolving additional speculative URLs on a metered path.
                    return NetworkQuality.shared.connected && (!NetworkQuality.shared.metered || id == prefetch.first?.id)
                }
                guard stillQueued else { continue }
                let videoId = String(entry.source.dropFirst(3))
                if await StreamFileCache.shared.path(for: videoId, allowQualityFallback: true) != nil { continue }
                _ = try? await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: prefs.maxKbps)
            }
        }
    }

    func refreshUpcomingURLPrefetch() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.warmUpcoming(around: self.playingIndex, generation: self.playGeneration)
        }
    }

    private final class StreamGate: @unchecked Sendable {
        let lock = NSLock()
        var tasks: [String: (id: UUID, task: Task<String, Error>)] = [:]
        /// Path of a download that has its first bytes, set before the
        /// downloader's continuation resumes so a second resolve cannot miss it.
        var growing: [String: String] = [:]
        var growingQuality: [String: String] = [:]
        var growingKbps: [String: Int] = [:]
        var durations: [String: Int] = [:]
        var requests: [String: (mediaID: String, path: String?)] = [:]
        var retired: [String: String] = [:]
        var keepingMediaIDs: Set<String> = []
        var verificationPins: [String: Int] = [:]
    }

    private static let streamGate = StreamGate()

    static func retainVerificationStream(_ mediaID: String) {
        streamGate.lock.withLock { streamGate.verificationPins[mediaID, default: 0] += 1 }
    }
    static func releaseVerificationStream(_ mediaID: String) {
        streamGate.lock.withLock {
            let remaining = (streamGate.verificationPins[mediaID] ?? 1) - 1
            streamGate.verificationPins[mediaID] = remaining > 0 ? remaining : nil
        }
        releaseObsoleteStreams()
    }

    static func releaseObsoleteStreams(keeping selected: Set<String>? = nil) {
        let (mediaIDs, requests, retired) = streamGate.lock.withLock {
            if let selected { streamGate.keepingMediaIDs = selected }
            return (streamGate.keepingMediaIDs.union(streamGate.verificationPins.keys), streamGate.requests, streamGate.retired)
        }
        for (requestID, request) in requests {
            let base = String(request.mediaID.prefix(while: { $0 != "#" }))
            if !mediaIDs.contains(base), request.path.map({ sourceHasPlaybackReaders(source: $0) }) != true {
                StreamDownloadBridge.shared.cancel(downloadId: requestID)
            }
        }
        for (path, mediaID) in retired where !mediaIDs.contains(mediaID) && !sourceHasPlaybackReaders(source: path) {
            for suffix in ["", ".grow", ".len", ".complete", ".failed", ".playback-cancelled"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            streamGate.lock.withLock { streamGate.retired[path] = nil }
        }
    }

    /// Starts playback as soon as the first range is on disk — up to a megabyte,
    /// or half that for a client that caps lower. Remaining ranges keep
    /// appending; [StreamFileCache] is filled when the last one lands so a
    /// re-tap does not fetch again.
    static func streamViaKtor(
        videoId: String, url: String, headers: [String: String], codec: String = "unknown", kbps: Int = 0, relativeLoudnessDb: Double? = nil, youtubeVideoId: String? = nil, durationSeconds: Int? = nil, maxKbps: Int = Int(Int32.max), expectedMimeType: String? = nil, firstRangeRetry: Int = 0
    ) async throws -> String {
        let taskKey = videoId + "|" + StreamFileCache.qualityIdentity + "|" + DiskCache.hashName(url)
        let flight: (id: UUID, task: Task<String, Error>) = streamGate.lock.withLock {
            if let existing = streamGate.tasks[taskKey] { return existing }
            let created = Task { try await streamViaKtorOnce(videoId: videoId, url: url, headers: headers, codec: codec, kbps: kbps, relativeLoudnessDb: relativeLoudnessDb, youtubeVideoId: youtubeVideoId, durationSeconds: durationSeconds, maxKbps: maxKbps, expectedMimeType: expectedMimeType, firstRangeRetry: firstRangeRetry) }
            let flight = (id: UUID(), task: created)
            streamGate.tasks[taskKey] = flight
            return flight
        }
        do {
            let path = try await flight.task.value
            streamGate.lock.withLock {
                if streamGate.tasks[taskKey]?.id == flight.id { streamGate.tasks[taskKey] = nil }
            }
            return path
        } catch {
            streamGate.lock.withLock {
                if streamGate.tasks[taskKey]?.id == flight.id { streamGate.tasks[taskKey] = nil }
            }
            throw error
        }
    }

    private static func streamViaKtorOnce(
        videoId: String, url: String, headers: [String: String], codec: String = "unknown", kbps: Int = 0, relativeLoudnessDb: Double? = nil, youtubeVideoId: String? = nil, durationSeconds: Int? = nil, maxKbps: Int = Int(Int32.max), expectedMimeType: String? = nil, firstRangeRetry: Int = 0
    ) async throws -> String {
        let qualityIdentity = StreamFileCache.qualityIdentity
        let requestID = "playback:" + UUID().uuidString
        streamGate.lock.withLock { streamGate.requests[requestID] = (videoId, nil) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let lock = NSLock()
            var resumed = false
            var openedPath: String?
            let ready = DownloadCallbackAdapter { path, message in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                if let path {
                    openedPath = path
                    DiskCache.allowLockedPlayback(URL(fileURLWithPath: path))
                    streamGate.lock.withLock { streamGate.requests[requestID]?.path = path }
                    streamGate.lock.withLock { streamGate.growing[videoId] = path; streamGate.growingQuality[videoId] = qualityIdentity; streamGate.growingKbps[videoId] = kbps }
                    Task {
                        await StreamFileCache.shared.noteGrowing(videoId: videoId, path: path, kbps: kbps, quality: qualityIdentity, relativeLoudnessDb: relativeLoudnessDb, youtubeVideoId: youtubeVideoId, durationSeconds: durationSeconds)
                        continuation.resume(returning: path)
                    }
                } else {
                    continuation.resume(throwing: InnertubeStreamResolver.StreamError(
                        message: message ?? "Stream failed"))
                }
            }
            let done = DownloadCallbackAdapter { path, message in
                streamGate.lock.withLock { streamGate.requests[requestID] = nil }
                // The bridge reports a failure before the first byte — a refused
                // or invalid opening range, a download with no bytes — on `done`
                // alone and never calls `ready`. Unanswered, the continuation
                // leaked and the load waiting on it hung for good: the next song
                // never started and nothing said why. Answering it here is also
                // what lets the caller's re-resolve on a rejected range run.
                lock.lock()
                let waiting = !resumed
                let failedPath = openedPath
                resumed = true
                lock.unlock()
                if waiting, path == nil {
                    continuation.resume(throwing: InnertubeStreamResolver.StreamError(
                        message: message ?? "Stream ended before its first bytes"))
                    return
                }
                if waiting, let path { continuation.resume(returning: path) }
                if let path {
                    Task {
                        await StreamFileCache.shared.store(videoId, path: path, sourceIdentity: DiskCache.hashName(url), codec: codec, kbps: kbps, quality: qualityIdentity, relativeLoudnessDb: relativeLoudnessDb, youtubeVideoId: youtubeVideoId, durationSeconds: durationSeconds)
                        streamGate.lock.withLock {
                            if streamGate.growing[videoId] == path { streamGate.growing[videoId] = nil; streamGate.growingQuality[videoId] = nil; streamGate.growingKbps[videoId] = nil; streamGate.durations[videoId] = nil }
                            streamGate.retired[path] = String(videoId.prefix(while: { $0 != "#" }))
                        }
                        releaseObsoleteStreams()
                    }
                } else if let message {
                    print("[Playback] stream tail failed for \(videoId): \(message)")
                    if let failedPath {
                        streamGate.lock.withLock {
                            if streamGate.growing[videoId] == failedPath { streamGate.growing[videoId] = nil; streamGate.growingQuality[videoId] = nil; streamGate.growingKbps[videoId] = nil; streamGate.durations[videoId] = nil }
                            streamGate.retired[failedPath] = String(videoId.prefix(while: { $0 != "#" }))
                        }
                        Task { await StreamFileCache.shared.dropGrowing(videoId: videoId, path: failedPath) }
                        releaseObsoleteStreams()
                    }
                }
            }
            // With the YouTube id the bridge can answer a mid-track refusal with a
            // fresh URL for the same rendition instead of cutting the song short.
            if let youtubeVideoId {
                StreamDownloadBridge.shared.streamTrackRequest(
                    requestId: requestID, videoId: youtubeVideoId, maxKbps: Int32(clamping: maxKbps),
                    url: url, headers: headers, expectedMimeType: expectedMimeType,
                    firstRangeRetry: Int32(clamping: firstRangeRetry),
                    ready: ready, done: done)
                return
            }
            StreamDownloadBridge.shared.streamSourceRequest(requestId: requestID, url: url, headers: headers, ready: ready, done: done)
        }
    }
}

private final class DoneAdapter: PlayerBridgeDoneCallback {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func onDone() { handler() }
}

private struct CounterpartCandidate: Decodable {
    let videoId: String
    let durationText: String?
    let source: String?
}

private final class CounterpartAdapter: VideoVersionBridgeVideoVersionCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}
