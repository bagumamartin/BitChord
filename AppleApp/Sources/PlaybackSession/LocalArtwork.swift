import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lightweight file references let a library retain metadata without retaining
/// every embedded cover. Extraction is serial, off-main, and byte-budgeted.
final class LocalArtwork: @unchecked Sendable {
    static let shared = LocalArtwork()
    private static let scheme = "bitchord-local-artwork"
    private let queue = DispatchQueue(label: "app.bitchord.BitChord.local-artwork", qos: .utility)
    private let memory = NSCache<NSString, NSData>()

    init() {
        memory.totalCostLimit = 16 * 1024 * 1024
        memory.countLimit = 128
    }

    static func reference(path: String) -> String {
        var parts = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        parts.scheme = scheme
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let cover = try? FileManager.default.attributesOfItem(atPath: OfflineArtworkStore.coverURL(audioPath: path).path)
        let coverStamp = (cover?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let coverSize = (cover?[.size] as? NSNumber)?.uint64Value ?? 0
        parts.queryItems = [URLQueryItem(name: "version", value: "\(stamp):\(size):\(coverStamp):\(coverSize)")]
        return parts.string!
    }

    static func isReference(_ value: String) -> Bool {
        URL(string: value)?.scheme == scheme
    }

    static func sizedReference(_ reference: String, pixels: Int) -> String {
        guard var parts = URLComponents(string: reference), parts.scheme == scheme else { return reference }
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == "pixels" }
        items.append(URLQueryItem(name: "pixels", value: String(min(1024, max(64, pixels)))))
        parts.queryItems = items
        return parts.string ?? reference
    }

    func data(for reference: String) async -> Data? {
        guard let url = URL(string: reference), url.scheme == Self.scheme else { return nil }
        let saved = await OfflineArtworkStore.shared.data(audioPath: url.path)
        let requested = URLComponents(string: reference)?.queryItems?.first { $0.name == "pixels" }?.value.flatMap(Int.init) ?? 1024
        let pixels = min(1024, max(64, requested))
        return await withCheckedContinuation { continuation in
            queue.async {
                let result: Data? = autoreleasepool {
                    // Refresh the identity if the file changed since the scan.
                    let key = Self.sizedReference(Self.reference(path: url.path), pixels: pixels) as NSString
                    if let cached = self.memory.object(forKey: key) {
                        return cached.length == 0 ? nil : cached as Data
                    }
                    let bytes = saved ?? readTrackMetadata(path: url.path)?.artwork
                    let thumbnail = bytes.flatMap { Self.thumbnail($0, pixels: pixels) }
                    let cached = (thumbnail ?? Data()) as NSData
                    self.memory.setObject(cached, forKey: key, cost: cached.length)
                    return thumbnail
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Decode at cover size before encoding: a large embedded original must
    /// never become a full-resolution bitmap just to draw a small library row.
    private static func thumbnail(_ data: Data, pixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: hasAlpha = true
        default: hasAlpha = false
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(result, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? result as Data : nil
    }
}
