import Foundation

/// Pure quality-cap rules shared by streaming resolvers and their checks.
enum StreamBitrateCapPolicy {
    static let jioSaavnRungs = [48, 96, 160, 320]

    static func bestJioSaavnRung(available: [Int], maxKbps: Int) -> Int? {
        available.filter { $0 > 0 && $0 <= maxKbps }.max()
    }

    static func jioSaavnRung(in url: String) -> Int? {
        guard let components = URLComponents(string: url),
              let range = components.path.range(of: #"_(48|96|160|320)\.(mp4|aac|mp3)$"#, options: .regularExpression) else {
            return nil
        }
        let suffix = components.path[range].dropFirst().split(separator: ".").first
        return suffix.flatMap { Int($0) }
    }

    static func jioSaavnURL(_ url: String, selecting rung: Int) -> String? {
        guard jioSaavnRungs.contains(rung), var components = URLComponents(string: url),
              let range = components.path.range(of: #"_(48|96|160|320)\.(mp4|aac|mp3)$"#, options: .regularExpression) else {
            return nil
        }
        let ext = components.path[range].split(separator: ".").last.map(String.init) ?? "mp4"
        components.path.replaceSubrange(range, with: "_\(rung).\(ext)")
        return components.url?.absoluteString
    }

    static func acceptsKnownBitrate(_ kbps: Int?, maxKbps: Int) -> Bool {
        guard maxKbps < Int.max else { return true }
        guard let kbps, kbps > 0 else { return false }
        return kbps <= maxKbps
    }

    static func blocksUnreducibleRemoteOriginal(maxKbps: Int) -> Bool {
        maxKbps < Int.max
    }

    static func unavailableMessage(maxKbps: Int) -> String {
        "This source has no known format at or below \(maxKbps) kbps. Choose High or Highest Available, or use a saved copy."
    }

    static let unreducibleRemoteMessage = "Original remote files cannot be reduced to this bitrate. Choose High or Highest Available, or use a saved copy."
}
