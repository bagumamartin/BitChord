import SwiftUI
import Observation

/// One published app release's notes, as shown in the update sheets.
struct ReleaseNotesEntry: Identifiable {
    let version: String
    let publishedAt: Date?
    let notes: String
    let url: URL
    var id: String { version }
}

/// The app's published releases between two versions, newest first. Tags that
/// are not plain app versions (the Automix model releases, for example) and
/// drafts or pre-releases are left out.
enum ReleaseHistory {
    private static let listURL = URL(string: "https://api.github.com/repos/bagumamartin/BitChord/releases?per_page=50")!

    /// Releases newer than `installed` up to and including `through`.
    static func entries(after installed: String, through: String) async -> [ReleaseNotesEntry]? {
        var request = URLRequest(url: listURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BitChord Apple updater", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payloads = try? JSONDecoder().decode([GitHubReleasePayload].self, from: data) else { return nil }
        let lower = ReleaseIdentity(version: installed, build: nil)
        let upper = ReleaseIdentity(version: through, build: nil)
        let formatter = ISO8601DateFormatter()
        return payloads.compactMap { payload -> (ReleaseIdentity, ReleaseNotesEntry)? in
            guard !payload.draft, !payload.prerelease,
                  payload.tag_name.range(of: #"^[vV]?\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                  let page = URL(string: payload.html_url), page.scheme == "https", page.host == "github.com",
                  page.path.hasPrefix("/bagumamartin/BitChord/releases/tag/") else { return nil }
            let version = payload.tag_name.replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
            let identity = ReleaseIdentity(version: version, build: nil)
            guard identity.compared(to: lower) == .newer,
                  let ceiling = upper.compared(to: identity), ceiling != .older else { return nil }
            return (identity, ReleaseNotesEntry(version: version,
                                                publishedAt: payload.published_at.flatMap { formatter.date(from: $0) },
                                                notes: payload.body ?? "", url: page))
        }
        .sorted { $0.0.compared(to: $1.0) == .newer }
        .map(\.1)
    }
}

/// Shows what changed since the version that last ran, once, on the first
/// launch of a newer version. On the Mac this is where people who update
/// through Sparkle see the notes of every release they skipped.
@MainActor @Observable final class WhatsNewCenter {
    static let shared = WhatsNewCenter()
    var entries: [ReleaseNotesEntry] = []
    private static let lastRunKey = "bitchord.lastRunVersion"

    func checkAfterLaunch() async {
        let current = UpdateChecker.shared.currentIdentity.version
        let defaults = UserDefaults.standard
        guard let previous = defaults.string(forKey: Self.lastRunKey),
              ReleaseIdentity(version: current, build: nil).compared(to: ReleaseIdentity(version: previous, build: nil)) == .newer else {
            defaults.set(current, forKey: Self.lastRunKey)
            return
        }
        // Remember the new version only once the notes were fetched, so an
        // offline first launch shows them on the next one instead.
        guard let found = await ReleaseHistory.entries(after: previous, through: current) else { return }
        defaults.set(current, forKey: Self.lastRunKey)
        entries = found
    }
}

struct WhatsNewSheet: View {
    let entries: [ReleaseNotesEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ReleaseNotesSections(entries: entries)
            }
            .formStyle(.grouped)
            .navigationTitle("What’s New")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}

/// One section per release, newest first.
struct ReleaseNotesSections: View {
    let entries: [ReleaseNotesEntry]

    var body: some View {
        ForEach(entries) { entry in
            Section {
                ReleaseNotesView(markdown: entry.notes)
                Link("Release page", destination: entry.url).font(.footnote)
            } header: {
                if let date = entry.publishedAt {
                    Text("BitChord \(entry.version) · \(date.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    Text("BitChord \(entry.version)")
                }
            }
        }
    }
}

/// Renders the Markdown the release notes are written in: headings, bullets,
/// paragraphs, and inline bold, italics, code and links. The leading
/// "# BitChord x.y.z" title is dropped because the section header names the
/// release, and image lines are skipped.
struct ReleaseNotesView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(String, level: Int)
        case bullet(String)
        case numbered(String, number: String)
        case code(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var fence: [String]?
        var lastWasBlank = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = fence { result.append(.code(Self.dedented(open))); fence = nil } else { fence = [] }
                continue
            }
            if fence != nil { fence?.append(raw); continue }
            if line.isEmpty { lastWasBlank = true; continue }
            defer { lastWasBlank = false }
            if line.hasPrefix("![") { continue }
            if let match = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                let level = line.distance(from: line.startIndex, to: match.upperBound) - 1
                let text = String(line[match.upperBound...])
                if level == 1, result.isEmpty, text.lowercased().hasPrefix("bitchord") { continue }
                result.append(.heading(text, level: level))
            } else if let match = line.range(of: #"^[-*+] "#, options: .regularExpression) {
                result.append(.bullet(String(line[match.upperBound...])))
            } else if let match = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                let number = String(line[..<match.upperBound]).trimmingCharacters(in: .whitespaces)
                result.append(.numbered(String(line[match.upperBound...]), number: number))
            } else if !lastWasBlank, case .paragraph(let previous)? = result.last {
                result[result.count - 1] = .paragraph(previous + " " + line)
            } else {
                result.append(.paragraph(line))
            }
        }
        return result
    }

    var body: some View {
        let items = blocks
        if items.isEmpty {
            Text("No release notes were supplied.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, block in
                    switch block {
                    case .heading(let text, let level):
                        Self.inline(text)
                            .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                            .padding(.top, index == 0 ? 0 : 6)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Self.inline(text)
                        }
                    case .numbered(let text, let number):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(number).monospacedDigit().foregroundStyle(.secondary)
                            Self.inline(text)
                        }
                    case .code(let text):
                        Text(text)
                            .font(.callout.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    case .paragraph(let text):
                        Self.inline(text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    /// A fence inside a list item is indented with it; drop the shared indent.
    private static func dedented(_ lines: [String]) -> String {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
        return lines.map { String($0.dropFirst(indent)) }.joined(separator: "\n")
    }

    private static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) { return Text(attributed) }
        return Text(text)
    }
}
