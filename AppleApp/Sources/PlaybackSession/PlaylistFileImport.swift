import Foundation

struct PlaylistImportRow: Sendable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var durationText: String?
    var matchedVideoId: String?
    var matchedTitle: String?
    var matchedArtist: String?
    var thumbnailUrl: String?

    var importedTrack: ImportedPlaylistTrack {
        ImportedPlaylistTrack(
            id: id,
            title: matchedTitle ?? title,
            artist: matchedArtist ?? artist,
            sourceTitle: title,
            sourceArtist: artist,
            album: album,
            durationText: durationText,
            videoId: matchedVideoId,
            thumbnailUrl: thumbnailUrl
        )
    }
}

struct PlaylistImportDraft: Identifiable, Sendable {
    var id: String { sourceName + "\u{1f}" + title }
    var title: String
    var sourceName: String
    var rows: [PlaylistImportRow]

    var matchedCount: Int { rows.filter { $0.matchedVideoId != nil }.count }
}

enum PlaylistFileImport {
    enum ImportError: LocalizedError {
        case unsupportedFormat
        case noTrackRows
        case tooManyTracks(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Choose a CSV or TSV playlist export with track titles and artists."
            case .noTrackRows:
                return "The file did not contain any recognizable track rows."
            case .tooManyTracks(let count):
                return "This file contains \(count) tracks. BitChord can import up to 500 tracks at a time; split the file and import each part."
            }
        }
    }

    static func parse(data: Data, filename: String) throws -> PlaylistImportDraft {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard ["csv", "tsv", "txt"].contains(ext),
              var text = String(data: data, encoding: .utf8) else {
            throw ImportError.unsupportedFormat
        }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let delimiter: Character
        if ext == "tsv" || (ext == "txt" && text.split(separator: "\n", maxSplits: 1).first?.contains("\t") == true) {
            delimiter = "\t"
        } else {
            delimiter = ","
        }
        let records = parseDelimited(text, delimiter: delimiter)
        guard let headers = records.first else { throw ImportError.noTrackRows }

        let normalized = headers.map(normalizeHeader)
        guard let titleIndex = index(in: normalized, candidates: ["trackname", "songtitle", "track", "title", "song", "name"]),
              let artistIndex = index(in: normalized, candidates: ["artistnames", "artistname", "artists", "artist", "performer"]) else {
            throw ImportError.noTrackRows
        }
        let albumIndex = index(in: normalized, candidates: ["albumname", "album", "release"])
        let durationIndex = index(in: normalized, candidates: ["durationms", "durationmilliseconds", "trackdurationms", "trackduration", "duration", "length", "time"])

        let rows: [PlaylistImportRow] = records.dropFirst().compactMap { fields in
            func field(_ idx: Int?) -> String? {
                guard let idx, fields.indices.contains(idx) else { return nil }
                let value = fields[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            guard let title = field(titleIndex), let artist = field(artistIndex) else { return nil }
            return PlaylistImportRow(
                id: UUID().uuidString,
                title: title,
                artist: artist,
                album: field(albumIndex),
                durationText: field(durationIndex).flatMap(durationText)
            )
        }
        guard !rows.isEmpty else { throw ImportError.noTrackRows }
        guard rows.count <= 500 else { throw ImportError.tooManyTracks(rows.count) }
        return PlaylistImportDraft(
            title: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
            sourceName: URL(fileURLWithPath: filename).lastPathComponent,
            rows: rows
        )
    }

    /// Match a small fixed number at once to avoid flooding catalog search.
    static func match(
        _ draft: PlaylistImportDraft,
        onProgress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> PlaylistImportDraft {
        var result = draft
        result.rows = await mapWithBoundedConcurrency(draft.rows, limit: 4, onProgress: onProgress) { row in
            await match(row)
        }
        return result
    }

    /// Runs only a bounded number of operations at once. Cancellation stops new
    /// work from being scheduled; partial output is intentionally returned so
    /// callers can discard it when their task was canceled.
    static func mapWithBoundedConcurrency<Input: Sendable, Output: Sendable>(
        _ input: [Input],
        limit: Int,
        onProgress: @Sendable (Int, Int) -> Void = { _, _ in },
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard !input.isEmpty else { return [] }
        let concurrency = max(1, limit)
        var output = Array<Output?>(repeating: nil, count: input.count)
        var completed = 0
        var next = 0
        await withTaskGroup(of: (Int, Output).self) { group in
            for index in 0..<min(concurrency, input.count) {
                group.addTask { (index, await operation(input[index])) }
                next += 1
            }
            while let (index, value) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                output[index] = value
                completed += 1
                onProgress(completed, input.count)
                if next < input.count {
                    let scheduled = next
                    group.addTask { (scheduled, await operation(input[scheduled])) }
                    next += 1
                }
            }
        }
        return output.compactMap { $0 }
    }

    static func mayPresentResult(
        requestID: UUID,
        activeRequestID: UUID?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && activeRequestID == requestID
    }

    private static func match(_ row: PlaylistImportRow) async -> PlaylistImportRow {
        var matched = row
        do {
            let hits = try await InnertubeSearch.shared.search("\(row.title) \(row.artist)", scope: "songs")
            let tracks = hits.filter(\.isTrack)
            let candidates = tracks.map {
                TrackMatch.Candidate(title: $0.title, artist: $0.resolvedArtist, durationText: $0.durationText)
            }
            guard let index = TrackMatch.bestIndex(
                in: candidates,
                target: TrackMatch.Target(
                    title: row.title,
                    artist: row.artist,
                    durationSec: TrackMatch.seconds(of: row.durationText)
                )
            ) else { return matched }
            let hit = tracks[index]
            matched.matchedVideoId = hit.videoId
            matched.matchedTitle = hit.title
            matched.matchedArtist = hit.resolvedArtist
            matched.thumbnailUrl = hit.thumbnailUrl
        } catch {
            // A search miss leaves the source row visible in the review step.
        }
        return matched
    }

    private static func durationText(_ raw: String) -> String? {
        if let milliseconds = Double(raw), milliseconds > 0 {
            return QueueEntry.formatDuration(milliseconds / 1000)
        }
        if TrackMatch.seconds(of: raw) != nil { return raw }
        return nil
    }

    private static func normalizeHeader(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func index(in headers: [String], candidates: [String]) -> Int? {
        headers.firstIndex { candidates.contains($0) }
    }

    /// RFC 4180 fields: quoted commas, CRLF records and doubled quotes.
    private static func parseDelimited(_ input: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(input)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" && field.isEmpty {
                quoted = true
            } else if char == delimiter {
                record.append(field)
                field = ""
            } else if char == "\n" || char == "\r" || char == "\r\n" {
                record.append(field)
                field = ""
                if record.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    records.append(record)
                }
                record = []
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
            } else {
                field.append(char)
            }
            index += 1
        }
        record.append(field)
        if record.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            records.append(record)
        }
        return records
    }
}
