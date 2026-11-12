import Foundation
import BitChordShared

/// A resolved YouTube Music stream: the URL the engine fetches plus the
/// headers the CDN demands and the quality description for display.
struct ResolvedYouTubeStream {
    let url: String
    let kbps: Int
    let mimeType: String
    let headers: [String: String]
    /// Player-response loudness figure for the engine's normalization stage
    /// (nil when the response carried none, or the payload predates it).
    let durationSeconds: Int?
    let loudnessDb: Double?
    let clientName: String
}

struct VideoSideError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Swift bridge over the shared module's `StreamResolver` (via `PlayerBridge`):
/// resolves a videoId to a playable audio URL. The resolved payload crosses FFI
/// as JSON.
///
/// The resolution *policy* — which identities to ask, what to remember between
/// attempts, when to stand one down, and the signed-in retries — lives in the
/// shared module, mirroring upstream's own split. This is only the seam.
final class InnertubeStreamResolver: Sendable {
    static let shared = InnertubeStreamResolver()

    func resolve(videoId: String, maxKbps: Int = Int.max) async throws -> ResolvedYouTubeStream {
        let request = ResolutionRequest()
        let payload: ResolvedYouTubeStream = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard !Task.isCancelled else { request.cancel(); return }
                let id = PlayerBridge.shared.resolveRequest(
                    videoId: videoId,
                    maxKbps: Swift.Int32(clamping: maxKbps == Int.max ? Int(Swift.Int32.max) : maxKbps),
                    callback: ResolveCallbackAdapter { json, message in
                        if let json {
                            do {
                                let decoded = try JSONDecoder().decode(StreamPayload.self, from: Data(json.utf8))
                                request.finish(.success(ResolvedYouTubeStream(url: decoded.url, kbps: decoded.kbps,
                                    mimeType: decoded.mimeType, headers: decoded.headers, durationSeconds: decoded.durationSeconds,
                                    loudnessDb: decoded.loudnessDb, clientName: decoded.clientName)))
                            } catch { request.finish(.failure(error)) }
                        } else {
                            let raw = message ?? "Stream resolution failed"
                            request.finish(.failure(StreamError(message: StreamError.say(raw), raw: raw)))
                        }
                    })
                request.setID(id)
            }
        } onCancel: { request.cancel() }

        // The shared resolver transforms both direct and ciphered URLs before
        // probing. Applying the n transform again corrupts a verified URL.
        return payload
    }

    /// The track's AVC/MP4 video side, or a side whose `url` is nil when the
    /// track has none. The audio path is untouched: this is its own request,
    /// through the same direct profile the audio resolved with.
    func resolveVideo(videoId: String, forceRefresh: Bool = false) async throws -> ResolvedVideoSide {
        try await withCheckedThrowingContinuation { continuation in
            PlayerBridge.shared.resolveVideo(
                videoId: videoId,
                forceRefresh: forceRefresh,
                callback: VideoCallbackAdapter { json, message in
                    guard let json else {
                        continuation.resume(throwing: VideoSideError(
                            message: message ?? "Video side lookup failed"
                        ))
                        return
                    }
                    do {
                        let payload = try JSONDecoder().decode(VideoSidePayload.self, from: Data(json.utf8))
                        continuation.resume(returning: ResolvedVideoSide(
                            url: payload.url,
                            width: payload.width,
                            height: payload.height,
                            itag: payload.itag,
                            mimeType: payload.mimeType,
                            codecs: payload.codecs,
                            bitrate: payload.bitrate,
                            headers: payload.headers ?? [:],
                            availableVideoHeights: payload.availableVideoHeights ?? [],
                            hasNParameter: payload.urlHasNParameter ?? false,
                            clientName: payload.clientName,
                            profileId: payload.profileId,
                            musicVideoType: payload.musicVideoType
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            )
        }
    }

    struct StreamError: Error, LocalizedError {
        /// The sentence a listener sees.
        let message: String
        /// What the shared module said, in full.
        ///
        /// Kept rather than discarded because it is the only place the per-client
        /// reasons exist and they are what a bug report needs. Never shown: it
        /// contains a video id and internal client names.
        let raw: String

        init(message: String, raw: String? = nil) {
            self.message = message
            self.raw = raw ?? message
        }

        var errorDescription: String? { message }

        /// What to show a listener, from whatever the shared module said.
        ///
        /// The shared module's message names the track and every client that refused
        /// it, which is the right thing for a log and the wrong thing to put in front
        /// of somebody: a video id and a list of internal client names is not a
        /// explanation. The two cases that are not "this one track is being awkward"
        /// get their own sentences, because they are the two a listener can do
        /// something about — and everything else gets one honest sentence rather than
        /// five words that name a subsystem.
        ///
        /// Same rule as the party screen's `describe`: the server's own words when it
        /// sent any, otherwise a statement of what failed and never the raw error.
        /// YouTube's "confirm you're not a bot": about the network, not the track.
        static func isBotCheck(_ error: Error) -> Bool {
            ((error as? StreamError)?.raw ?? "\(error)").localizedCaseInsensitiveContains("not a bot")
        }

        /// What clears YouTube's bot check, for the device in hand. Signing in
        /// is the reliable way out — YouTube's own message asks for exactly
        /// that — and a Mac has no mobile data to switch to.
        static var botCheckAdvice: String { botCheckAdvice(signedIn: false) }

        /// Signed in, the check is YouTube's view of the network rather than of
        /// the account, so "sign in" is not advice; signing out and back in is,
        /// because an account session YouTube has stopped trusting reads the same.
        static func botCheckAdvice(signedIn: Bool) -> String {
            #if os(macOS)
            let network = "Try another network (a phone hotspot works)"
            #else
            let network = "Switch between Wi-Fi and mobile data"
            #endif
            if signedIn {
                return "YouTube is asking this network to confirm it isn’t a bot, even with your account signed in, so it isn’t serving audio right now. \(network), or wait a few minutes. If it keeps happening, sign out of YouTube Music in Settings and sign back in."
            }
            return "YouTube is asking this network to confirm it isn’t a bot, so it isn’t serving audio right now. Sign in to YouTube Music in Settings. \(network), or wait a few minutes."
        }

        static func say(_ raw: String) -> String {
            // Only the shared module's sentence decides the wording; the
            // per-client outcomes after the marker are for the report.
            let said = (raw.components(separatedBy: "\n[clients]").first ?? raw).lowercased()
            if said.contains("not a bot") && said.contains("even signed in") {
                return botCheckAdvice(signedIn: true)
            }
            if said.contains("signed-in playback:") {
                return "Your signed-in session could not be restored. Check your connection or sign in again."
            }
            if said.contains("temporarily unavailable") {
                return "Playback is temporarily unavailable. Try again shortly."
            }
            if said.contains("not a bot") {
                return botCheckAdvice
            }
            if said.contains("sign in") {
                return "YouTube is asking this device to sign in before it will serve anything. That is YouTube's gate rather than anything to do with the track."
            }
            if said.contains("needs to be reloaded") || said.contains("page needs") {
                return "YouTube's player refused this connection. Trying again in a moment usually clears it."
            }
            if said.contains("unavailable") || said.contains("not available") {
                return "That track isn’t available right now."
            }
            if said.contains("no signature timestamp") {
                return "BitChord could not read YouTube’s player, so it could not open a stream. Check the connection and try again."
            }
            return "Couldn’t open a stream for that track."
        }
    }
}

private struct StreamPayload: Codable {
    let url: String
    let kbps: Int
    let mimeType: String
    let headers: [String: String]
    /// Nil on payloads minted before the shared module parsed the figure.
    let durationSeconds: Int?
    let loudnessDb: Double?
    let clientName: String

    private enum CodingKeys: String, CodingKey { case url, kbps, mimeType, headers, loudnessDb, durationSeconds, clientName }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(String.self, forKey: .url)
        kbps = try values.decode(Int.self, forKey: .kbps)
        mimeType = try values.decode(String.self, forKey: .mimeType)
        // Kotlin omits empty default maps. Some upstream profiles correctly
        // need no CDN headers, so an omitted map is a valid empty map.
        headers = try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        durationSeconds = try values.decodeIfPresent(Int.self, forKey: .durationSeconds)
        loudnessDb = try values.decodeIfPresent(Double.self, forKey: .loudnessDb)
        clientName = try values.decodeIfPresent(String.self, forKey: .clientName) ?? "unknown"
    }
}

private final class ResolveCallbackAdapter: PlayerBridgeResolveCallback {
    private let onResult: (String?, String?) -> Void

    init(onResult: @escaping (String?, String?) -> Void) {
        self.onResult = onResult
    }

    func onResult(json: String?, message: String?) {
        onResult(json, message)
    }
}

private struct VideoSidePayload: Decodable {
    let url: String?
    let width: Int?
    let height: Int?
    let itag: Int?
    let mimeType: String?
    let codecs: String?
    let bitrate: Int?
    /// Kotlin omits an empty default map and list.
    let headers: [String: String]?
    let availableVideoHeights: [Int]?
    let urlHasNParameter: Bool?
    let clientName: String
    let profileId: String
    let musicVideoType: String?
}

private final class VideoCallbackAdapter: PlayerBridgeVideoCallback {
    private let onResult: (String?, String?) -> Void

    init(onResult: @escaping (String?, String?) -> Void) {
        self.onResult = onResult
    }

    func onResult(json: String?, message: String?) {
        onResult(json, message)
    }
}

/// Cancellation resumes Swift immediately and releases its shared Kotlin flight.
private final class ResolutionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ResolvedYouTubeStream, Error>?
    private var id: Int64?
    private var cancelled = false
    private var completed = false
    func install(_ value: CheckedContinuation<ResolvedYouTubeStream, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); value.resume(throwing: CancellationError()); return }
        continuation = value; lock.unlock()
    }
    func setID(_ value: Int64) {
        lock.lock(); id = value; let cancel = cancelled; lock.unlock()
        if cancel { PlayerBridge.shared.cancelResolve(requestId: value) }
    }
    func finish(_ result: Result<ResolvedYouTubeStream, Error>) {
        lock.lock()
        guard !completed, !cancelled, let value = continuation else { lock.unlock(); return }
        completed = true; continuation = nil; lock.unlock()
        value.resume(with: result)
    }
    func cancel() {
        lock.lock(); cancelled = true
        let value = continuation; continuation = nil
        let requestID = id; lock.unlock()
        value?.resume(throwing: CancellationError())
        if let requestID { PlayerBridge.shared.cancelResolve(requestId: requestID) }
    }
}
