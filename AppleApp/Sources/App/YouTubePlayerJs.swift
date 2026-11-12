import Foundation
import BitChordShared

/// Player timestamp and both media-URL transforms, using one deployment of the
/// player script and a pinned, bundled solver. Work stays off the main actor.
actor YouTubePlayerJs {
    static let shared = YouTubePlayerJs()
    private let solverDirectory: URL?
    private var solver: YouTubeChallengeSolver?
    private var baseJsUrl: String?
    private var baseJsText: String?
    private var baseJsTask: Task<String, Error>?
    private var cachedSts: Int?

    init(solverDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("YouTubeSolver"), playerText: String? = nil) {
        self.solverDirectory = solverDirectory
        self.baseJsText = playerText
    }

    func signatureTimestamp() async throws -> Int {
        if let cachedSts { return cachedSts }
        let js = try await baseJs()
        let regex = try NSRegularExpression(pattern: #"(?:signatureTimestamp|sts)\s*[:=]\s*(\d{5})"#)
        guard let match = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let range = Range(match.range(at: 1), in: js), let sts = Int(js[range]) else {
            throw PlayerJsError("signatureTimestamp not found in base.js")
        }
        cachedSts = sts
        return sts
    }

    func unlockCipher(_ cipher: String, videoId: String) async throws -> String {
        let params = Self.parseQuery(cipher)
        guard let base = params["url"], let signature = params["s"],
              var components = URLComponents(string: base) else {
            throw PlayerJsError("signatureCipher missing url/s")
        }
        let solved = try await solve("sig", challenge: signature)
        let key = params["sp"] ?? "signature"
        Self.setQueryValue(solved, for: key, in: &components)
        guard let url = components.url?.absoluteString else { throw PlayerJsError("Invalid media URL") }
        return try await transformUrl(url)
    }

    /// Direct URLs can carry the throttling challenge too; being unciphered
    /// does not make them ready for a CDN range request.
    func transformUrl(_ url: String) async throws -> String {
        guard var components = URLComponents(string: url), let items = components.queryItems,
              let challenge = items.first(where: { $0.name == "n" })?.value, !challenge.isEmpty else { return url }
        let solved = try await solve("n", challenge: challenge)
        Self.setQueryValue(solved, for: "n", in: &components)
        guard let result = components.url?.absoluteString else { throw PlayerJsError("Invalid transformed URL") }
        return result
    }

    private func solve(_ type: String, challenge: String) async throws -> String {
        let player = try await baseJs()
        if solver == nil {
            guard let solverDirectory else { throw PlayerJsError("Bundled player solver unavailable") }
            solver = try YouTubeChallengeSolver(directory: solverDirectory)
        }
        return try solver!.solve(type, challenge: challenge, player: player)
    }

    private static func setQueryValue(_ value: String, for key: String, in components: inout URLComponents) {
        // Preserve every other signed parameter's exact encoding. queryItems
        // reconstruction can turn %2B into + and change what the CDN receives.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        var parts = (components.percentEncodedQuery ?? "").split(separator: "&").map(String.init)
        parts.removeAll { $0.split(separator: "=", maxSplits: 1).first?.removingPercentEncoding == key }
        parts.append("\(encodedKey)=\(encodedValue)")
        components.percentEncodedQuery = parts.joined(separator: "&")
    }

    // MARK: - base.js

    private func baseJs() async throws -> String {
        if let t = baseJsText { return t }
        if let baseJsTask { return try await baseJsTask.value }
        let task = Task { try await self.loadText(url: try await self.baseJsUrlString()) }
        baseJsTask = task
        defer { baseJsTask = nil }
        let text = try await task.value
        baseJsText = text
        return text
    }

    private func baseJsUrlString() async throws -> String {
        if let u = baseJsUrl { return u }
        if let fromIframe = try? await playerUrlFromIframeApi() {
            baseJsUrl = fromIframe
            return fromIframe
        }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=dummy")!)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        let html = try await loadText(request: req)
        if let range = html.range(of: #""jsUrl":"[^"]*base\.js[^"]*""#, options: .regularExpression) {
            var js = String(html[range])
            js = js.replacingOccurrences(of: "\"jsUrl\":\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\\/", with: "/")
            let full = js.hasPrefix("https://") ? js : "https://www.youtube.com\(js)"
            baseJsUrl = full
            return full
        }
        throw PlayerJsError("jsUrl not found")
    }

    private func playerUrlFromIframeApi() async throws -> String {
        let text = try await loadText(url: "https://www.youtube.com/iframe_api")
        let pat = #"player\\?/([a-z0-9]{8})\\?/"#
        guard let regex = try? NSRegularExpression(pattern: pat),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else {
            throw PlayerJsError("iframe_api hash not found")
        }
        let hash = String(text[r])
        return "https://www.youtube.com/s/player/\(hash)/player_ias.vflset/en_GB/base.js"
    }

    private func loadText(url: String) async throws -> String {
        guard let url = URL(string: url) else { throw PlayerJsError("Invalid player URL") }
        return try await loadText(request: URLRequest(url: url))
    }

    private func loadText(request: URLRequest) async throws -> String {
        // No cookie jar: YouTube's identity cookies would otherwise settle in
        // the process-wide store and tie every later page to one visitor.
        var request = request
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, url.scheme == "https", url.host == "www.youtube.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              data.count <= 5 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PlayerJsError("Player script request failed")
        }
        return text
    }

    private static func parseQuery(_ cipher: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in cipher.split(separator: "&") {
            let bits = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { continue }
            out[bits[0].removingPercentEncoding ?? bits[0]] =
                bits[1].removingPercentEncoding ?? bits[1]
        }
        return out
    }

    struct PlayerJsError: Error, LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }
}

// MARK: - CipherUnlockBridge wiring

enum CipherUnlockWiring {
    static func install(player: YouTubePlayerJs = .shared) {
        CipherUnlockBridge.shared.setImpl(value: Impl(player: player))
    }

    private final class Impl: CipherUnlockBridgeImpl {
        let player: YouTubePlayerJs
        init(player: YouTubePlayerJs) { self.player = player }
        func signatureTimestamp(callback: CipherUnlockBridgeResultCallback) {
            Task {
                do {
                    let sts = try await player.signatureTimestamp()
                    callback.onResult(value: String(sts), error: nil)
                } catch {
                    callback.onResult(value: nil, error: error.localizedDescription)
                }
            }
        }

        func transformUrl(url: String, callback: CipherUnlockBridgeResultCallback) {
            Task {
                do { callback.onResult(value: try await player.transformUrl(url), error: nil) }
                catch { callback.onResult(value: nil, error: error.localizedDescription) }
            }
        }

        func unlockCipher(videoId: String, cipher: String, callback: CipherUnlockBridgeResultCallback) {
            Task {
                do {
                    let url = try await player.unlockCipher(cipher, videoId: videoId)
                    callback.onResult(value: url, error: nil)
                } catch {
                    callback.onResult(value: nil, error: error.localizedDescription)
                }
            }
        }
    }
}
