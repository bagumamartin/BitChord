import Foundation
import BitChordShared

/// Swift face of the shared module's [SourceResolver].
///
/// The controller used to run its own cross-source race: a `withTaskGroup` over
/// the custom HTTP source, the JS module host and JioSaavn, with
/// "JioSaavn must beat 256 kbps" as the only quality bar and no notion of rank.
/// That could not be made correct without reimplementing the parts that *are*
/// judgement — which is what the shared module now holds.
///
/// Three decisions, three entry points, matching upstream:
///
///  - `substitute` — the latency-critical race, run before a queued YouTube track
///    is resolved. Raced, not walked: the sources differ in speed by two orders of
///    magnitude, and walking them in rank order means the fast answer arrives after
///    YouTube's own walk has already won.
///  - `upgrade` — the unhurried second look, run with sound already playing. Waits
///    for every source, so a slow source holding the FLAC still gets to serve it
///    mid-track rather than being dropped for a fast 320.
///  - `prefetch` — a longer bounded comparison while the current track is playing.
enum SourceSubstitution {

    struct Stream: Sendable {
        var url: String
        var headers: [String: String]
        var codec: String?
        var kbps: Int?
        var lossless: Bool
        var isDolbyAtmos: Bool
        var belowRequest: Bool
        var durationSec: Int?
        var sourceConfigId: String?
        var summary: String
    }

    /// The stream for a queued YouTube track, from a source ranked above it.
    ///
    /// - Parameter playingDurationSec the runtime *actually playing*, which makes
    ///   this the upgrade path: the replacement has to be the same length to the
    ///   second or so before it may be cut in over the audio.
    static func substitute(
        title: String,
        artist: String,
        durationSec: Int?,
        album: String? = nil,
        isExplicit: KotlinBoolean? = nil,
        isVideo: Bool = false,
        playing: Format? = nil,
        diagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Stream? {
        // With a known floor the resolver's bar becomes "beats what is playing"
        // rather than "satisfies the request" — which is the difference between
        // finding the FLAC and finding anything better than 160kbps.
        if let playing, let durationSec, !isVideo {
            return await upgrade(
                title: title, artist: artist, durationSec: durationSec,
                album: album, isExplicit: isExplicit, isVideo: isVideo, playing: playing, diagnostic: diagnostic
            )
        }
        return await call(diagnostic: diagnostic) { callback in
            SourceResolverBridge.shared.substituteForYouTube(
                title: title,
                artist: artist,
                durationSec: durationSec.map { KotlinInt(value: Int32($0)) },
                album: album,
                isExplicit: isExplicit,
                isVideo: isVideo,
                callback: callback
            )
        }
    }

    /// A stream that genuinely satisfies the request, for a track already playing.
    ///
    /// `servedBy` is the source already serving the track, so it is not asked again
    /// for a stream it would only reproduce.
    static func upgrade(
        title: String,
        artist: String,
        durationSec: Int?,
        album: String? = nil,
        isExplicit: KotlinBoolean? = nil,
        isVideo: Bool = false,
        playing: Format,
        servedBy: String? = nil,
        diagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Stream? {
        guard durationSec != nil, !isVideo else {
            // The resolver declines both on purpose: without a runtime the length
            // check is meaningless, and a video's runtime is not its audio's. Going
            // straight to the pre-play race is the correct fallback rather than
            // forcing an unverifiable swap.
            return await substitute(
                title: title, artist: artist, durationSec: durationSec,
                album: album, isExplicit: isExplicit, isVideo: isVideo
            )
        }
        return await call(diagnostic: diagnostic) { callback in
            SourceResolverBridge.shared.upgradeFor(
                title: title,
                artist: artist,
                durationSec: durationSec.map { KotlinInt(value: Int32($0)) },
                album: album,
                isExplicit: isExplicit,
                isVideo: isVideo,
                playingJson: formatJSON(playing),
                servedBy: servedBy,
                callback: callback
            )
        }
    }

    /// The best available copy for the next track, including slower addons.
    ///
    /// The caller is expected to pin a returned stream before caching any of it —
    /// otherwise playback re-runs the race, may land on a different source, and
    /// writes a second file into the cache entry the warm one already half-filled.
    static func prefetch(
        title: String,
        artist: String,
        durationSec: Int?,
        album: String? = nil,
        isExplicit: KotlinBoolean? = nil,
        isVideo: Bool = false,
        diagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Stream? {
        guard !isVideo else { return nil }
        return await call(diagnostic: diagnostic) { callback in
            SourceResolverBridge.shared.prefetchSubstitute(
                title: title,
                artist: artist,
                durationSec: durationSec.map { KotlinInt(value: Int32($0)) },
                album: album,
                isExplicit: isExplicit,
                isVideo: isVideo,
                callback: callback
            )
        }
    }

    /// The copy worth keeping as a file over whatever YouTube's ladder would give.
    static func forDownload(
        title: String,
        artist: String,
        durationSec: Int?,
        album: String? = nil,
        isExplicit: KotlinBoolean? = nil,
        quality: String
    ) async -> Stream? {
        return await call(cancellable: true) { callback in
            SourceResolverBridge.shared.forDownload(
                title: title,
                artist: artist,
                durationSec: durationSec.map { KotlinInt(value: Int32($0)) },
                album: album,
                isExplicit: isExplicit,
                isVideo: false,
                quality: quality,
                callback: callback
            )
        }
    }

    // ── Plumbing ────────────────────────────────────────────────────────────

    /// What the listener is hearing, in the shape the resolver judges against.
    struct Format: Sendable {
        var codec: String?
        var kbps: Int?
        var lossless: Bool
        var isDolbyAtmos: Bool = false
    }

    /// A [Format] as the shared module's `FormatDocument`.
    ///
    /// Hand-built rather than `Encodable`, because the shared module's
    /// `KotlinInt` and `KotlinBoolean` are Kotlin boxed primitives and do not
    /// conform to Swift's `Encodable`. Wrapping each in a shadow struct to bridge
    /// them would be more machinery than three optional fields are worth.
    private static func formatJSON(_ format: Format) -> String {
        var parts: [String] = []
        if let codec = format.codec { parts.append("\"codec\":\(quote(codec))") }
        if let kbps = format.kbps { parts.append("\"kbps\":\(kbps)") }
        // Null rather than omitted: "this source declined to say" is a real answer
        // the resolver distinguishes from "it said it is lossy", and that difference
        // is exactly what decides whether a swap is worth making.
        parts.append("\"isLossless\":\(format.lossless ? "true" : "null")")
        if format.isDolbyAtmos { parts.append("\"isDolbyAtmos\":true") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func call(
        diagnostic: @escaping @Sendable (String) -> Void = { _ in },
        cancellable: Bool = false,
        _ request: (SourceResolverBridgeStreamCallback) -> Void
    ) async -> Stream? {
        let box = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            box.arm(continuation)
            if cancellable && Task.isCancelled { box.resume(nil); return }
            request(ResolveCallback { json, message in
                if let message { diagnostic(message) }
                // A null document is a *miss*, not a failure: this source does not
                // hold the recording, or nothing ranked above YouTube has it. The
                // resolver has already logged why, and the caller's next move is the
                // same either way — fall back to YouTube.
                box.resume(json.flatMap(decode))
            })
            }
        } onCancel: {
            if cancellable { box.resume(nil) }
        }
    }

    static func decode(_ json: String) -> Stream? {
        guard let data = json.data(using: .utf8),
              let document = try? JSONDecoder().decode(StreamDocument.self, from: data)
        else { return nil }
        return Stream(
            url: document.url,
            headers: document.headers,
            codec: document.format.codec,
            kbps: document.format.kbps.map { $0 },
            lossless: document.format.isLossless == true,
            isDolbyAtmos: document.format.isDolbyAtmos,
            belowRequest: document.belowRequest,
            durationSec: document.durationSec,
            sourceConfigId: document.sourceConfigId,
            summary: document.format.summary
        )
    }
}

/// Resumes exactly once.
///
/// A bridge callback that arrived after the caller had already given up would
/// otherwise trap on a double resume, which is a crash rather than a wrong answer.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SourceSubstitution.Stream?, Never>?

    func arm(_ continuation: CheckedContinuation<SourceSubstitution.Stream?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ stream: SourceSubstitution.Stream?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: stream)
    }
}

private final class ResolveCallback: SourceResolverBridgeStreamCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

private struct StreamDocument: Decodable {
    struct Format: Decodable {
        var codec: String?
        var kbps: Int?
        var isLossless: Bool?
        var isDolbyAtmos: Bool
        var summary: String
        private enum CodingKeys: String, CodingKey { case codec, kbps, isLossless, isDolbyAtmos, summary }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            codec = try values.decodeIfPresent(String.self, forKey: .codec)
            kbps = try values.decodeIfPresent(Int.self, forKey: .kbps)
            isLossless = try values.decodeIfPresent(Bool.self, forKey: .isLossless)
            isDolbyAtmos = try values.decodeIfPresent(Bool.self, forKey: .isDolbyAtmos) ?? false
            summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        }
    }
    var url: String
    var format: Format
    var headers: [String: String]
    var belowRequest: Bool
    var durationSec: Int?
    var sourceConfigId: String?
    private enum CodingKeys: String, CodingKey { case url, format, headers, belowRequest, durationSec, sourceConfigId }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(String.self, forKey: .url)
        format = try values.decode(Format.self, forKey: .format)
        // Kotlin omits its default false flags and empty header map.
        headers = try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        belowRequest = try values.decodeIfPresent(Bool.self, forKey: .belowRequest) ?? false
        durationSec = try values.decodeIfPresent(Int.self, forKey: .durationSec)
        sourceConfigId = try values.decodeIfPresent(String.self, forKey: .sourceConfigId)
    }
}
