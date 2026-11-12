import Foundation

/// Persists Automix analysis overlays (Music Understanding / future disk MIR)
/// under Application Support so a track is not re-analysed every session.
enum AutomixOverlayCache {
    private static let folderName = "AutomixOverlays"
    struct Fingerprint: Codable, Equatable, Sendable {
        let size: UInt64
        let modified: TimeInterval
    }
    private struct Entry: Codable {
        let version: Int
        let fingerprint: Fingerprint
        let systemVersion: String
        let overlay: CodableOverlay
    }

    static func fingerprint(forFilePath path: String) -> Fingerprint? {
        let path = path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
        guard !FileManager.default.fileExists(atPath: path + ".grow") || FileManager.default.fileExists(atPath: path + ".complete"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Fingerprint(size: size.uint64Value, modified: modified.timeIntervalSince1970)
    }

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BitChord", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Seed a previously cached overlay for `path` into the native engine.
    @discardableResult
    static func seedCached(forFilePath path: String) -> Bool {
        guard let overlay = load(forFilePath: path) else { return false }
        return seedAutomixAnalysis(path: path, overlay: overlay)
    }

    static func store(
        _ overlay: AutomixAnalysisOverlayRec,
        rhythmAnalysed: Bool = true,
        forFilePath path: String,
        expected: Fingerprint? = nil,
        directory: URL? = nil
    ) {
        guard let url = cacheURL(forFilePath: path, directory: directory), let fingerprint = fingerprint(forFilePath: path),
              expected == nil || expected == fingerprint else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Entry(version: 2, fingerprint: fingerprint,
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, overlay: CodableOverlay(overlay, rhythmAnalysed: rhythmAnalysed)))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[BitChord] overlay cache write failed: %@", String(describing: error))
        }
    }

    static func load(forFilePath path: String, directory: URL? = nil) -> AutomixAnalysisOverlayRec? {
        guard let url = cacheURL(forFilePath: path, directory: directory),
              let fingerprint = fingerprint(forFilePath: path),
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Entry.self, from: data),
              saved.version == 2, saved.fingerprint == fingerprint,
              saved.systemVersion == ProcessInfo.processInfo.operatingSystemVersionString
        else { return nil }
        // The rhythm grid is wanted only without the Neural Engine beat model
        // (see `MusicUnderstandingAnalyzer`). With it, a saved grid would
        // replace the better one, so it is left out and the key kept; without
        // it, an entry saved with no grid is analysed again to get one.
        if AutomixModelLoader.hasNeuralEngineBeatModel {
            return saved.overlay.withoutRhythm().asRec()
        }
        guard saved.overlay.rhythmAnalysed ?? true else { return nil }
        return saved.overlay.asRec()
    }

    private static func cacheURL(forFilePath path: String, directory: URL? = nil) -> URL? {
        guard let directory = directory ?? Self.directory else { return nil }
        let normalized = path.hasPrefix("file://")
            ? (URL(string: path)?.path ?? path)
            : path
        let digest = normalized.data(using: .utf8).map { data -> String in
            var hash: UInt64 = 5381
            for byte in data {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            return String(hash, radix: 16)
        } ?? "unknown"
        return directory.appendingPathComponent("\(digest).json")
    }
}

/// Codable mirror of `AutomixAnalysisOverlayRec` for disk persistence.
private struct CodableOverlay: Codable {
    var bpm: Double?
    var beatConfidence: Double?
    var beatInterval: Double?
    var beats: [Double]?
    var downbeats: [Double]?
    var key: String?
    var keyConfidence: Double?
    var phraseBoundaries: [Double]?
    var vocalProbability: Double?
    var contentEnd: Double?
    var audibleStart: Double?
    var outroStart: Double?
    var mixInTime: Double?
    var source: String
    /// Whether the rhythm pass was asked for. Absent in entries written before
    /// it became optional, all of which asked for it.
    var rhythmAnalysed: Bool?

    init(_ rec: AutomixAnalysisOverlayRec, rhythmAnalysed: Bool) {
        self.rhythmAnalysed = rhythmAnalysed
        bpm = rec.bpm
        beatConfidence = rec.beatConfidence
        beatInterval = rec.beatInterval
        beats = rec.beats
        downbeats = rec.downbeats
        key = rec.key
        keyConfidence = rec.keyConfidence
        phraseBoundaries = rec.phraseBoundaries
        vocalProbability = rec.vocalProbability
        contentEnd = rec.contentEnd
        audibleStart = rec.audibleStart
        outroStart = rec.outroStart
        mixInTime = rec.mixInTime
        source = rec.source
    }

    func withoutRhythm() -> CodableOverlay {
        var copy = self
        copy.bpm = nil
        copy.beatConfidence = nil
        copy.beatInterval = nil
        copy.beats = nil
        copy.downbeats = nil
        return copy
    }

    func asRec() -> AutomixAnalysisOverlayRec {
        AutomixAnalysisOverlayRec(
            bpm: bpm,
            beatConfidence: beatConfidence,
            beatInterval: beatInterval,
            beats: beats,
            downbeats: downbeats,
            key: key,
            keyConfidence: keyConfidence,
            phraseBoundaries: phraseBoundaries,
            vocalProbability: vocalProbability,
            contentEnd: contentEnd,
            audibleStart: audibleStart,
            outroStart: outroStart,
            mixInTime: mixInTime,
            source: source.isEmpty ? "disk_cache" : source
        )
    }
}
