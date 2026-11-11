import SwiftUI
import Observation

/// One latest-release record supplies version, notes and the platform download.
@MainActor @Observable final class UpdateChecker {
    static let shared = UpdateChecker()
    static let latestReleaseURL = URL(string: "https://github.com/bagumamartin/BitChord/releases/latest")!
    private(set) var available: AppReleaseUpdate?
    private(set) var latest: AppReleaseUpdate?
    private(set) var checking = false
    private(set) var lastCheckedAt: Date?
    var problem: String?
    private var checkedThisSession = false

    var currentIdentity: ReleaseIdentity {
        ReleaseIdentity(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
                        build: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init))
    }
    var currentVersion: String { currentIdentity.label }
    var comparableVersion: String { currentIdentity.version }
    var buildChannel: String {
        #if DEBUG
        return "Development build"
        #else
        return "Release build"
        #endif
    }
    var revision: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BitChordRevision") as? String,
              !value.isEmpty, value != "unknown", !value.contains("$(") else { return nil }
        return value
    }
    var comparison: ReleaseIdentity.Comparison? { latest?.identity.compared(to: currentIdentity) }
    var status: String {
        if checking { return "Checking the latest published release…" }
        if let problem { return problem }
        guard let latest else { return "Latest published version has not been checked yet." }
        switch comparison {
        case .newer: return "Update available · \(latest.identity.label)"
        case .same: return "You have the latest published build."
        case .older: return "Your installed build is ahead of the latest published release (\(latest.identity.label))."
        case .unknownBuild: return "The published version is \(latest.version). Its build number is not reported, so an exact build comparison is unavailable."
        case nil: return "The published version could not be compared with this build."
        }
    }
    func pollOnce() async {
        guard !checkedThisSession else { return }
        _ = await refresh(notify: true)
    }
    @discardableResult func check() async -> AppReleaseUpdate? { await refresh(notify: false) }
    private func refresh(notify: Bool) async -> AppReleaseUpdate? {
        guard !checking else { return available }
        checkedThisSession = true
        checking = true
        problem = nil
        defer { checking = false }
        guard let release = await fetchLatest() else {
            problem = "Couldn’t check GitHub. The last known release may be out of date; try again."
            return nil
        }
        latest = release
        lastCheckedAt = Date()
        guard release.identity.compared(to: currentIdentity) == .newer else {
            available = nil
            return nil
        }
        if !notify || !UpdateAcknowledgementStore.contains(release.id) { available = release }
        return release
    }
    func dismiss() {
        if let id = available?.id { UpdateAcknowledgementStore.record(id) }
        available = nil
    }
    private func fetchLatest() async -> AppReleaseUpdate? {
        do {
            let data = try await fetch(URL(string: "https://api.github.com/repos/bagumamartin/BitChord/releases/latest")!)
            let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            guard !payload.draft, !payload.prerelease,
                  let page = URL(string: payload.html_url), page.scheme == "https", page.host == "github.com",
                  page.path.hasPrefix("/bagumamartin/BitChord/releases/tag/") else { return nil }
            let version = payload.tag_name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
            guard ReleaseIdentity(version: version, build: nil).compared(to: currentIdentity) != nil else { return nil }
            #if os(iOS)
            let platform = "ios"
            #else
            let platform = "macos"
            #endif
            let prefix = "/bagumamartin/BitChord/releases/download/\(payload.tag_name)/"
            let assets = payload.assets.filter { $0.url?.path.hasPrefix(prefix) == true }
            var manifest: ReleaseManifest?
            let manifests = assets.filter { $0.name == "release.json" }
            if !manifests.isEmpty {
                // A malformed/incomplete release must not silently fall back to an arbitrary file.
                guard manifests.count == 1, let url = manifests[0].url,
                      manifests[0].size > 0, manifests[0].size < 128_000 else { return nil }
                let document = try await fetch(url)
                let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: document)
                guard decoded.version == version, decoded.schema == 1, decoded.build > 0,
                      decoded.artifact(for: platform, assets: assets) != nil else { return nil }
                manifest = decoded
            }
            let artifact = manifest?.artifact(for: platform, assets: assets)
            let download = artifact.flatMap { item in assets.first { $0.name == item.name } }
                ?? AppReleaseUpdate.legacyAsset(platform: platform, assets: assets, version: version)
            return AppReleaseUpdate(identity: ReleaseIdentity(version: version, build: manifest?.build),
                releaseUrl: page, notes: payload.body, publishedAt: payload.published_at.flatMap { ISO8601DateFormatter().date(from: $0) },
                download: download, artifact: artifact, revision: manifest?.revision)
        } catch { return nil }
    }
    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BitChord Apple updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}

enum UpdateAcknowledgementStore {
    private static let key = "bitchord.acknowledgedUpdateVersions"
    static func contains(_ version: String) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(version) }
    static func record(_ version: String) {
        var versions = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        versions.insert(version)
        UserDefaults.standard.set(versions.sorted(), forKey: key)
    }
}

struct UpdateSheet: View {
    let release: AppReleaseUpdate
    @Environment(\.dismiss) private var dismiss
    /// Every release between the installed version and this one, so someone
    /// who skipped several updates sees all of their notes, not only the last.
    @State private var missed: [ReleaseNotesEntry] = []
    var body: some View {
        NavigationStack {
            Form {
                Section("Version") {
                    LabeledContent("Installed", value: UpdateChecker.shared.currentVersion)
                    LabeledContent("Published", value: release.identity.label)
                    if let date = release.publishedAt { LabeledContent("Published on", value: date.formatted(date: .abbreviated, time: .omitted)) }
                    if let revision = release.revision { LabeledContent("Revision", value: revision) }
                }
                if missed.isEmpty {
                    Section("What’s New") { ReleaseNotesView(markdown: release.notes ?? "") }
                } else {
                    ReleaseNotesSections(entries: missed)
                }
                Section("Installation") { ReleaseInstallationView(release: release) }
            }
            .formStyle(.grouped)
            .task {
                let installed = UpdateChecker.shared.currentIdentity.version
                guard release.identity.compared(to: UpdateChecker.shared.currentIdentity) == .newer else { return }
                missed = await ReleaseHistory.entries(after: installed, through: release.version) ?? []
            }
            .navigationTitle("Release Details")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}

struct ReleaseInstallationView: View {
    let release: AppReleaseUpdate
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if release.identity.compared(to: UpdateChecker.shared.currentIdentity) == .older {
                Text("This published installer is older than your installed build. Keep the installed build unless you intentionally want to return to this release.")
                Link("View older release", destination: release.releaseUrl)
            } else {
                #if os(macOS)
                Text("Use BitChord’s Mac updater to download, verify and replace the app. It uses the project’s signed update feed.")
                Button("Open Mac Updater") { MacUpdateManager.shared.checkNow() }.buttonStyle(.borderedProminent)
                Text("For a first installation or manual recovery, download the DMG, open it and move BitChord into Applications, replacing the existing app.").font(.footnote).foregroundStyle(.secondary)
                #else
                Text("Download the IPA, then sign and install it with the same signing app and identity used for your current BitChord. Keeping the same app identity preserves its local data.")
                #endif
                if let download = release.download, let url = download.url {
                    Link(destination: url) { Text(download.name.lowercased().hasSuffix(".ipa") ? "Download iOS IPA" : "Download Mac DMG") }
                    Text(download.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("No unambiguous installer for this platform is attached. Check the release page.").font(.footnote)
                }
                if let artifact = release.artifact {
                    Text("Requires \(artifact.minimumOS)").font(.footnote)
                    Text("SHA-256: \(artifact.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                }
                Link("Release notes and all files", destination: release.releaseUrl)
            }
        }
    }
}
