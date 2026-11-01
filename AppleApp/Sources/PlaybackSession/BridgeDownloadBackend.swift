import Foundation
import BitChordShared

struct BridgeDownloadBackend: DownloadBackend {
    func resolve(_ entry: QueueEntry, quality: String) async throws -> String {
        try await resolve(entry, quality: quality, youtubeFallback: false)
    }
    func resolve(_ entry: QueueEntry, quality: String, youtubeFallback: Bool) async throws -> String {
        let duration = entry.durationSeconds > 0 ? Int(entry.durationSeconds.rounded()) : nil
        if !youtubeFallback, let selected = await SourceSubstitution.forDownload(title: entry.title, artist: entry.artist,
            durationSec: duration, album: entry.albumName,
            isExplicit: entry.isExplicit.map { KotlinBoolean(value: $0) }, quality: quality) {
            try Task.checkCancellation()
            return try encode(url: selected.url, headers: selected.headers,
                provider: "source:" + (selected.sourceConfigId ?? "selected"),
                identity: DownloadStore.digest(entry.source + "|" + entry.id),
                codec: selected.codec, kbps: selected.kbps, lossless: selected.lossless)
        }
        try Task.checkCancellation()
        if entry.source.hasPrefix("saavn:") || entry.id.hasPrefix("saavn:") {
            let id = String((entry.source.hasPrefix("saavn:") ? entry.source : entry.id).dropFirst(6))
            if let stream = await JioSaavn.streamURL(for: id) {
                return try encode(url: stream.url, headers: [:], provider: "jiosaavn", identity: id,
                    codec: "MP4", kbps: stream.kbps, lossless: false)
            }
        }
        guard entry.source.hasPrefix("yt:"), let videoId = entry.videoId else {
            throw NSError(domain: "Download", code: 1, userInfo: [NSLocalizedDescriptionKey: "No enabled source supplied a downloadable copy of this recording."])
        }
        let stream = try await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: quality == "STANDARD" ? 128 : Int(Int32.max))
        return try encode(url: stream.url, headers: stream.headers, provider: "youtube", identity: videoId,
            codec: stream.mimeType.lowercased().contains("opus") ? "Opus" : "AAC", kbps: stream.kbps,
            lossless: false, youtubeVideoId: videoId)
    }

    private func encode(url: String, headers: [String: String], provider: String, identity: String,
                        codec: String?, kbps: Int?, lossless: Bool, youtubeVideoId: String? = nil) throws -> String {
        var payload: [String: Any] = ["url": url, "headers": headers, "provider": provider,
            "recordingIdentity": identity, "lossless": lossless]
        payload["codec"] = codec; payload["kbps"] = kbps; payload["youtubeVideoId"] = youtubeVideoId
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    func transfer(id: String, url: String, headers: [String: String], progress: @escaping DownloadProgressHandler) async throws -> String {
        guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
        let host = parsed.host?.lowercased() ?? ""
        if host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") {
            let path = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    StreamDownloadBridge.shared.downloadWithProgress(downloadId: id, url: url, headers: headers,
                        progress: TransferProgress(progress), callback: TransferDone { path, message in
                            if let path { continuation.resume(returning: path) }
                            else { continuation.resume(throwing: NSError(domain: "Download", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: message ?? "Download failed"])) }
                        })
                    if Task.isCancelled { StreamDownloadBridge.shared.cancel(downloadId: id) }
                }
            } onCancel: { StreamDownloadBridge.shared.cancel(downloadId: id) }
            try AudioDownloadContainer.validate(path)
            guard NativeStreamVerifier.verifyCachedFile(path) != nil else { throw URLError(.cannotDecodeContentData) }
            return path
        }
        let transport = FileDownloadTransport.requiresRedirectControl(url: parsed, headers: headers) ? FileDownloadTransport.credentialed : FileDownloadTransport.shared
        let path = try await transport.download(id: id, url: parsed, headers: headers,
            allowsCellular: !PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true), progress: progress)
        guard NativeStreamVerifier.verifyCachedFile(path) != nil else {
            transport.finish(id: id)
            throw URLError(.cannotDecodeContentData)
        }
        return path
    }
    func restoreTransfer(id: String, progress: @escaping DownloadProgressHandler) async throws -> String? {
        if let path = try await FileDownloadTransport.shared.restore(id: id, progress: progress) { return path }
        return try await FileDownloadTransport.credentialed.restore(id: id, progress: progress)
    }
    func hasCompletedTransfer(id: String) -> Bool { FileDownloadTransport.shared.hasCompleted(id: id) || FileDownloadTransport.credentialed.hasCompleted(id: id) }
    func cancel(id: String) { StreamDownloadBridge.shared.cancel(downloadId: id); FileDownloadTransport.shared.cancel(id: id); FileDownloadTransport.credentialed.cancel(id: id) }
    func pause(id: String) { StreamDownloadBridge.shared.cancel(downloadId: id); FileDownloadTransport.shared.pause(id: id); FileDownloadTransport.credentialed.pause(id: id) }
    func finish(id: String) { FileDownloadTransport.shared.finish(id: id); FileDownloadTransport.credentialed.finish(id: id) }
    func verify(path: String, entry: QueueEntry, provider: String) async throws {
        guard entry.source.hasPrefix("yt:"), let videoID = entry.videoId, provider != "youtube" else { return }
        if !(await NetworkQuality.shared.connected),
           await StreamFileCache.shared.path(for: videoID, allowGrowing: false, allowQualityFallback: true, onlyOriginal: true) == nil {
            throw URLError(.notConnectedToInternet)
        }
        guard await RecordingIdentityVerifier.matches(videoId: videoID, candidate: path, allowTimingEdits: entry.isVideo) else {
            try Task.checkCancellation()
            if !(await NetworkQuality.shared.connected) { throw URLError(.notConnectedToInternet) }
            throw NSError(domain: "Download", code: 6, userInfo: [NSLocalizedDescriptionKey: "The source audio could not be verified as the selected recording. Trying the original YouTube audio."])
        }
    }
}

private final class TransferDone: StreamDownloadBridgeDownloadCallback {
    let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(path: String?, message: String?) { handler(path, message) }
}
private final class TransferProgress: StreamDownloadBridgeProgressCallback {
    let handler: DownloadProgressHandler
    init(_ handler: @escaping DownloadProgressHandler) { self.handler = handler }
    func onProgress(received: Int64, total: Int64) { handler(received, total > 0 ? total : nil) }
}
