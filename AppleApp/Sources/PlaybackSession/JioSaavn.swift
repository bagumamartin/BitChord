import Foundation
import CommonCrypto
import BitChordShared

/// JioSaavn search + stream — same unofficial catalogue API as upstream
/// `JioSaavnService`. DES decrypt uses Apple CommonCrypto.
enum JioSaavn {
    private static let base = "https://www.jiosaavn.com/api.php"
    private static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

    static func search(_ query: String) async -> [SearchHitDTO] {
        var comps = URLComponents(string: base)!
        comps.queryItems = [
            .init(name: "__call", value: "search.getResults"),
            .init(name: "_format", value: "json"),
            .init(name: "_marker", value: "0"),
            .init(name: "api_version", value: "4"),
            .init(name: "ctx", value: "android"),
            .init(name: "q", value: query),
            .init(name: "p", value: "1"),
            .init(name: "n", value: "8"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { raw in
            guard let id = raw["id"] as? String, let title = raw["title"] as? String else { return nil }
            let info = raw["more_info"] as? [String: Any]
            let artistNames = ((info?["artistMap"] as? [String: Any])?["primary_artists"] as? [[String: Any]]) ?? []
            let artists = artistNames.compactMap { $0["name"] as? String }.joined(separator: ", ")
            let image: String?
            if let rawImage = raw["image"] as? String {
                image = rawImage
                    .replacingOccurrences(of: "150x150", with: "500x500")
                    .replacingOccurrences(of: "http://", with: "https://")
            } else {
                image = nil
            }
            let seconds = Int(info?["duration"] as? String ?? "") ?? 0
            let dur = seconds > 0 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : nil
            return SearchHitDTO(
                kind: "track",
                videoId: "saavn:\(id)",
                title: title,
                subtitle: artists,
                thumbnailUrl: image,
                durationText: dur,
                albumName: info?["album"] as? String,
                browseId: nil,
                browseType: nil,
                artistId: nil,
                albumId: nil,
                isVideo: false,
                setVideoId: nil
            )
        }
    }

    static func streamURL(for trackId: String, maxKbps: Int = Int.max) async -> (url: String, kbps: Int)? {
        let id = trackId.hasPrefix("saavn:") ? String(trackId.dropFirst(6)) : trackId
        var comps = URLComponents(string: base)!
        comps.queryItems = [
            .init(name: "__call", value: "song.getDetails"),
            .init(name: "_format", value: "json"),
            .init(name: "_marker", value: "0"),
            .init(name: "api_version", value: "4"),
            .init(name: "ctx", value: "android"),
            .init(name: "pids", value: id),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let song: [String: Any]?
        if let songs = root["songs"] as? [[String: Any]] {
            song = songs.first
        } else {
            song = root.values.first { $0 is [String: Any] } as? [String: Any]
        }
        guard let song,
              let info = song["more_info"] as? [String: Any],
              let encrypted = info["encrypted_media_url"] as? String,
              let decrypted = decryptDES(encrypted) else { return nil }
        let has320 = (info["320kbps"] as? String)?.lowercased() == "true"
        let currentRung = StreamBitrateCapPolicy.jioSaavnRung(in: decrypted)
        if maxKbps < Int.max {
            // The API's URL suffix is the only quality evidence this response
            // supplies. If it is absent, do not claim the rendition fits.
            guard currentRung != nil else { return nil }
            let available = has320 ? StreamBitrateCapPolicy.jioSaavnRungs : [48, 96, 160]
            guard let selected = StreamBitrateCapPolicy.bestJioSaavnRung(
                available: available, maxKbps: maxKbps
            ), let selectedURL = StreamBitrateCapPolicy.jioSaavnURL(decrypted, selecting: selected) else { return nil }
            return (selectedURL, selected)
        }
        if has320, currentRung != nil,
           let highestURL = StreamBitrateCapPolicy.jioSaavnURL(decrypted, selecting: 320) {
            return (highestURL, 320)
        }
        return (decrypted, currentRung ?? 160)
    }

    /// Upstream `matchAndStream` for this catalogue: search, score, then open
    /// the best row that is the same recording. Nil means fall through to YouTube.
    static func matchedStream(
        for entry: QueueEntry, playingDurationSec: Int? = nil
    ) async -> (url: String, kbps: Int, durationSec: Int?)? {
        let target = TrackMatch.Target(
            title: entry.title,
            artist: entry.artist,
            durationSec: playingDurationSec ?? {
                let s = Int(entry.durationSeconds.rounded())
                return s > 0 ? s : nil
            }()
        )
        if target.title.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let query = [target.title, target.artist].filter { !$0.isEmpty }.joined(separator: " ")
        let hits = await search(query)
        let candidates = hits.map {
            TrackMatch.Candidate(title: $0.title, artist: $0.subtitle ?? "", durationText: $0.durationText)
        }
        guard let index = TrackMatch.bestIndex(in: candidates, target: target),
              let sid = hits[index].videoId else { return nil }
        guard let stream = await streamURL(for: sid) else { return nil }
        return (stream.url, stream.kbps, TrackMatch.seconds(of: hits[index].durationText))
    }

    private static func decryptDES(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        let key = Array("38346591".utf8)
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeDES)
        var outLen = 0
        let status = data.withUnsafeBytes { raw in
            key.withUnsafeBufferPointer { keyBuf in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmDES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyBuf.baseAddress, kCCKeySizeDES,
                    nil,
                    raw.baseAddress, data.count,
                    &out, out.count, &outLen
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: out.prefix(outLen), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
