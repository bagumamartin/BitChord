import Foundation

struct ReleaseIdentity: Equatable {
    let version: String
    let build: Int?
    var label: String { build.map { "\(version) (build \($0))" } ?? version }
    var key: String { build.map { "\(version)-build\($0)" } ?? version }
    enum Comparison { case newer, same, older, unknownBuild }
    func compared(to current: ReleaseIdentity) -> Comparison? {
        guard let latestParts = Self.parts(version), let currentParts = Self.parts(current.version) else { return nil }
        for index in 0..<max(latestParts.count, currentParts.count) {
            let latest = index < latestParts.count ? latestParts[index] : 0
            let installed = index < currentParts.count ? currentParts[index] : 0
            if latest != installed { return latest > installed ? .newer : .older }
        }
        guard let build, let installed = current.build else { return .unknownBuild }
        return build == installed ? .same : build > installed ? .newer : .older
    }
    private static func parts(_ raw: String) -> [Int]? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = value.hasPrefix("v") || value.hasPrefix("V") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part), number >= 0 else { return nil }
            return number
        }
        return numbers.count == parts.count ? numbers : nil
    }
}

struct ReleaseAsset: Decodable {
    let name: String
    let browser_download_url: String
    let size: Int64
    var url: URL? {
        guard let url = URL(string: browser_download_url), url.scheme == "https",
              url.host == "github.com", url.user == nil, url.password == nil,
              url.path.hasPrefix("/bagumamartin/BitChord/releases/download/"), !url.path.contains("..") else { return nil }
        return url
    }
}

struct GitHubReleasePayload: Decodable {
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let assets: [ReleaseAsset]
}

struct ReleaseManifest: Codable {
    let schema: Int
    let version: String
    let build: Int
    let revision: String
    let artifacts: [Artifact]
    struct Artifact: Codable {
        let platform: String
        let name: String
        let sha256: String
        let minimumOS: String
        let installation: String
    }
    func artifact(for platform: String, assets: [ReleaseAsset]) -> Artifact? {
        guard schema == 1, build > 0,
              artifacts.filter({ $0.platform == platform }).count == 1,
              let artifact = artifacts.first(where: { $0.platform == platform }),
              artifact.sha256.count == 64, artifact.sha256.allSatisfy(\.isHexDigit),
              assets.filter({ $0.name == artifact.name && $0.url != nil && $0.size > 0 }).count == 1 else { return nil }
        let suffix = platform == "ios" ? ".ipa" : ".dmg"
        return artifact.name.lowercased().hasSuffix(suffix) ? artifact : nil
    }
}

struct AppReleaseUpdate: Identifiable {
    let identity: ReleaseIdentity
    let releaseUrl: URL
    let notes: String?
    let publishedAt: Date?
    let download: ReleaseAsset?
    let artifact: ReleaseManifest.Artifact?
    let revision: String?
    var id: String { identity.key }
    var version: String { identity.version }

    /// Ambiguous legacy packages are deliberately left for the release page.
    static func legacyAsset(platform: String, assets: [ReleaseAsset], version: String? = nil) -> ReleaseAsset? {
        let suffix = platform == "ios" ? ".ipa" : ".dmg"
        let matches = assets.filter { asset in
            let name = asset.name.lowercased()
            if let version {
                let prefix = "bitchord-" + version.lowercased()
                guard name == prefix + suffix || name.hasPrefix(prefix + "-") else { return false }
            }
            return name.hasPrefix("bitchord-") && name.hasSuffix(suffix) && asset.size > 0 && asset.url != nil
                && !name.contains("x64") && !name.contains("x86") && !name.contains("intel")
                && !name.contains("debug") && !name.contains("simulator")
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
