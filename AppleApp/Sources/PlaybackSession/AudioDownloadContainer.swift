import Foundation

/// The bytes decide the saved extension. A playlist/error page is not an audio file.
enum AudioDownloadContainer {
    static func fileExtension(at path: String) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 4096), data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        func ascii(_ start: Int, _ end: Int) -> String {
            guard end <= bytes.count else { return "" }
            return String(bytes: bytes[start..<end], encoding: .ascii) ?? ""
        }
        if ascii(0, 4) == "fLaC" { return "flac" }
        if ascii(0, 4) == "RIFF", ascii(8, 12) == "WAVE" { return "wav" }
        if ascii(0, 4) == "FORM", ["AIFF", "AIFC"].contains(ascii(8, 12)) { return "aiff" }
        if ascii(4, 8) == "ftyp" { return "m4a" }
        if ascii(0, 4) == "OggS" { return "ogg" }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        if ascii(0, 3) == "ID3" { return "mp3" }
        if bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "aac" }
        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return "mp3" }
        return nil
    }

    static func validate(_ path: String) throws {
        guard fileExtension(at: path) != nil else {
            throw NSError(domain: "Download", code: 3, userInfo: [NSLocalizedDescriptionKey: "The source returned a playlist or an unsupported file instead of downloadable audio."])
        }
    }
}
