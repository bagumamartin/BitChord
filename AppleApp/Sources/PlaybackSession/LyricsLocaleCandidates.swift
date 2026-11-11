import Foundation

/// Produces stable candidates from all supported locales matching the detected
/// lyric language or any preferred language. Exact user preferences lead; the
/// remainder are sorted so Set iteration never decides which model is tried.
enum LyricsLocaleCandidates {
    static func ordered(
        detectedLanguages: [String],
        preferredIdentifiers: [String],
        supportedIdentifiers: [String]
    ) -> [String] {
        let normalizedSupported = supportedIdentifiers.map { ($0, normalize($0)) }
        var result: [String] = []
        var seen = Set<String>()

        for preferred in preferredIdentifiers {
            let exact = normalize(preferred)
            if let match = normalizedSupported.first(where: { $0.1 == exact }), seen.insert(match.1).inserted {
                result.append(match.0)
            }
        }

        let relevantCodes = Set((detectedLanguages + preferredIdentifiers).map(languageCode))
        let alternatives = normalizedSupported
            .filter { relevantCodes.contains(languageCode($0.1)) && !seen.contains($0.1) }
            .sorted { $0.1 < $1.1 }
        for candidate in alternatives where seen.insert(candidate.1).inserted {
            result.append(candidate.0)
        }
        return result
    }

    private static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func languageCode(_ identifier: String) -> String {
        normalize(identifier).split(separator: "-").first.map(String.init) ?? ""
    }
}
