import Foundation

/// Containers AVFoundation does not open, recognised by their first bytes.
///
/// Streamed tracks are cached as WebM/Opus under an `.m4a` name, so the
/// extension says nothing; the header does. Matroska/WebM and Ogg are the two
/// the app's own decoder reads and Apple's frameworks reject.
enum AVFoundationReadable {
    static func canOpen(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let bytes = [UInt8](head)
        if bytes == [0x1A, 0x45, 0xDF, 0xA3] { return false } // Matroska / WebM
        if bytes == Array("OggS".utf8) { return false }
        return true
    }
}

/// Writes a track the app can decode, but AVFoundation cannot, as a temporary
/// 16-bit mono WAV that Apple's analysis frameworks accept.
///
/// The native core decodes the track once, start to end, straight into the
/// file: no sample crosses the bridge and no stretch is held in memory. (It
/// used to come over thirty seconds at a time as a float array, and reading
/// that array back element by element cost about a core for the whole
/// analysis.) The file is about 23 MB for four minutes and is deleted as soon
/// as the analysis returns.
enum PCMTranscode {
    /// Writes the decoded track to the given file URL; false on failure.
    typealias Writer = @Sendable (_ path: String, _ destination: URL) -> Bool

    static func write(path: String, writer: Writer) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitchord-analysis-\(UUID().uuidString).wav")
        guard writer(path, url) else {
            try? FileManager.default.removeItem(at: url)
            NSLog("[BitChord] analysis transcode failed for %@", path)
            return nil
        }
        return url
    }
}
