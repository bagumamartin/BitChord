import Foundation
import CryptoKit
import BitChordShared

/// Ordinary files use the OS transfer service, not YouTube's ranged transport.
/// Task identity and completed results survive process termination. No credentials
/// are saved in the result journal; URLSession owns the request and resume data.
final class FileDownloadTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = FileDownloadTransport()
    // Background URLSession follows redirects without consulting the delegate.
    // Credential-bearing requests need a normal session to enforce our policy.
    static let credentialed = FileDownloadTransport(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BitChord/Downloads/AuthenticatedTransfers", isDirectory: true), configuration: .default)
    static let sessionIdentifier = "app.bitchord.offline-files.v1"
    static func requiresRedirectControl(url: URL? = nil, headers: [String: String]) -> Bool {
        let publicHeaders: Set<String> = ["user-agent", "accept", "accept-language", "accept-encoding", "content-type"]
        return url?.user != nil || url?.password != nil || headers.keys.contains { !publicHeaders.contains($0.lowercased()) }
    }
    private let root: URL
    private let lock = NSLock()
    private var waiters: [String: CheckedContinuation<String, Error>] = [:]
    private var progressHandlers: [String: DownloadProgressHandler] = [:]
    private var waiterTasks: [String: Int] = [:]
    private var progressTimes: [String: TimeInterval] = [:]
    private var discarded: Set<String> = []
    private var stopping: Set<String> = []
    private var backgroundCompletion: (() -> Void)?
    private let configuration: URLSessionConfiguration
    private var session: URLSession!
    private struct Record: Codable { var filename: String?; var failure: String? }

    init(directory: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/Downloads/Transfers", isDirectory: true)
        self.configuration = configuration ?? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        self.configuration.isDiscretionary = false
        self.configuration.sessionSendsLaunchEvents = true
        self.configuration.httpMaximumConnectionsPerHost = 2
        self.configuration.timeoutIntervalForRequest = 60
        self.configuration.timeoutIntervalForResource = 24 * 60 * 60
        self.configuration.waitsForConnectivity = true
        self.configuration.httpShouldSetCookies = false
        self.configuration.httpCookieStorage = nil
        self.configuration.urlCredentialStorage = nil
        super.init()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DiskCache.allowLockedPlayback(root)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: self.configuration, delegate: self, delegateQueue: queue)
    }
    private func file(_ id: String, _ ext: String) -> URL {
        // runID is a UUID in production; tests may use readable IDs.
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key).appendingPathExtension(ext)
    }
    private func readRecord(_ id: String) -> Record? {
        guard let data = try? Data(contentsOf: file(id, "json")) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
    func hasCompleted(id: String) -> Bool {
        guard let record = readRecord(id), let name = record.filename else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }
    func restore(id: String, progress: @escaping DownloadProgressHandler) async throws -> String? {
        try await attach(id: id, request: nil, progress: progress)
    }
    func download(id: String, url: URL, headers: [String: String], allowsCellular: Bool, progress: @escaping DownloadProgressHandler) async throws -> String {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.allowsCellularAccess = allowsCellular
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let result = try await attach(id: id, request: request, progress: progress) else { throw URLError(.unknown) }
        return result
    }
    private func attach(id: String, request: URLRequest?, progress: @escaping DownloadProgressHandler) async throws -> String? {
        while lock.withLock({ stopping.contains(id) }) { try await Task.sleep(for: .milliseconds(50)) }
        let active = await session.allTasks
        try Task.checkCancellation()
        let existing = active.first { $0.taskDescription == id && $0.state != .completed && $0.state != .canceling } as? URLSessionDownloadTask
        if request == nil, existing == nil, !hasCompleted(id: id) { return nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let record = readRecord(id), let name = record.filename,
                   FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
                    lock.unlock(); continuation.resume(returning: root.appendingPathComponent(name).path); return
                }
                guard waiters[id] == nil else {
                    lock.unlock(); continuation.resume(throwing: URLError(.requestBodyStreamExhausted)); return
                }
                guard !Task.isCancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                discarded.remove(id); stopping.remove(id)
                waiters[id] = continuation; progressHandlers[id] = progress
                var task = existing
                if task == nil, let request {
                    let signature = (request.url?.absoluteString ?? "") + "|" + (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: "|")
                    let digest = Data(SHA256.hash(data: Data(signature.utf8))).base64EncodedString()
                    let sameRequest = (try? String(contentsOf: file(id, "request"), encoding: .utf8)) == digest
                    if sameRequest, let resume = try? Data(contentsOf: file(id, "resume")) {
                        task = session.downloadTask(withResumeData: resume)
                    } else { task = session.downloadTask(with: request) }
                    try? digest.write(to: file(id, "request"), atomically: true, encoding: .utf8)
                }
                task?.taskDescription = id
                waiterTasks[id] = task?.taskIdentifier
                lock.unlock()
                if let task { task.resume() }
                else { settle(id: id, error: URLError(.unknown)) }
                if Task.isCancelled { pause(id: id) }
            }
        } onCancel: { self.pause(id: id) }
    }
    func pause(id: String) { stop(id: id, discard: false) }
    func cancel(id: String) { stop(id: id, discard: true) }
    private func stop(id: String, discard: Bool) {
        let shouldStop = lock.withLock { () -> Bool in
            if discard { discarded.insert(id) }
            return stopping.insert(id).inserted
        }
        if discard { finish(id: id) }
        guard shouldStop else { return }
        let waiter = lock.withLock { () -> CheckedContinuation<String, Error>? in
            progressHandlers[id] = nil; waiterTasks[id] = nil; progressTimes[id] = nil
            return waiters.removeValue(forKey: id)
        }
        waiter?.resume(throwing: CancellationError())
        Task {
            let tasks = await session.allTasks
            let matching = tasks.compactMap { $0 as? URLSessionDownloadTask }.filter { $0.taskDescription == id }
            if matching.isEmpty { lock.withLock { _ = stopping.remove(id) } }
            for task in matching {
                task.cancel { data in
                    self.lock.withLock {
                        if !self.discarded.contains(id), let data { try? data.write(to: self.file(id, "resume"), options: .atomic) }
                        self.stopping.remove(id)
                    }
                }
            }
        }
    }
    func finish(id: String) {
        for ext in ["audio", "json", "resume", "request"] { try? FileManager.default.removeItem(at: file(id, ext)) }
    }
    private func settle(id: String, error: Error?, taskID: Int? = nil) {
        let (continuation, record) = lock.withLock { () -> (CheckedContinuation<String, Error>?, Record?) in
            if let taskID, waiterTasks[id] != taskID { return (nil, nil) }
            let waiter = waiters.removeValue(forKey: id)
            progressHandlers[id] = nil; waiterTasks[id] = nil; progressTimes[id] = nil
            return (waiter, readRecord(id))
        }
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) }
        else if let filename = record?.filename { continuation.resume(returning: root.appendingPathComponent(filename).path) }
        else { continuation.resume(throwing: NSError(domain: "Download", code: 4, userInfo: [NSLocalizedDescriptionKey: record?.failure ?? "Download produced no audio file."])) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        lock.lock(); defer { lock.unlock() }
        guard !discarded.contains(id), waiterTasks[id] == nil || waiterTasks[id] == downloadTask.taskIdentifier else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  [200, 206].contains(response.statusCode) else { throw URLError(.badServerResponse) }
            let bytes = ((try FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? NSNumber)?.int64Value ?? 0
            let expected: Int64
            if response.statusCode == 206 {
                // URLSession reassembles a resumed file; the response's own
                // Content-Length describes only its remaining suffix.
                let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
                let pieces = range.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
                guard pieces.count == 2, let total = Int64(pieces[1]), total > 0 else { throw URLError(.badServerResponse) }
                expected = total
            } else { expected = downloadTask.countOfBytesExpectedToReceive }
            guard bytes > 0, bytes <= 1024 * 1024 * 1024,
                  expected <= 0 || response.value(forHTTPHeaderField: "Content-Encoding") != nil || bytes == expected else { throw URLError(.networkConnectionLost) }
            try AudioDownloadContainer.validate(location.path)
            let destination = file(id, "audio")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            DiskCache.allowLockedPlayback(destination)
            try JSONEncoder().encode(Record(filename: destination.lastPathComponent)).write(to: file(id, "json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: file(id, "resume"))
            try? JSONEncoder().encode(Record(failure: error.localizedDescription)).write(to: file(id, "json"), options: .atomic)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        if let error, let data = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
            lock.withLock {
                if !discarded.contains(id), waiterTasks[id] == nil || waiterTasks[id] == task.taskIdentifier {
                    try? data.write(to: file(id, "resume"), options: .atomic)
                }
            }
        }
        settle(id: id, error: error, taskID: task.taskIdentifier)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        if totalBytesWritten > 1024 * 1024 * 1024 { cancel(id: id); return }
        let handler = lock.withLock { () -> DownloadProgressHandler? in
            guard waiterTasks[id] == downloadTask.taskIdentifier else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - (progressTimes[id] ?? 0) >= 0.15 || totalBytesWritten == totalBytesExpectedToWrite else { return nil }
            progressTimes[id] = now
            return progressHandlers[id]
        }
        handler?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let handler = lock.withLock { waiterTasks[id] == downloadTask.taskIdentifier ? progressHandlers[id] : nil }
        handler?(fileOffset, expectedTotalBytes > 0 ? expectedTotalBytes : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let headers = task.originalRequest?.allHTTPHeaderFields ?? [:]
        let carriesCredentials = Self.requiresRedirectControl(url: task.originalRequest?.url, headers: headers)
        guard let from = response.url?.absoluteString, let to = request.url?.absoluteString,
              CredentialPolicy.shared.mayRedirect(from: from, to: to, carriesCredentials: carriesCredentials) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
    func invalidate() { session.invalidateAndCancel() }
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { completion(); return }
        lock.withLock { backgroundCompletion = completion }
        _ = session
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (() -> Void)? in
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        Task { @MainActor in
            await DownloadStore.shared.waitUntilReady()
            DownloadStore.shared.networkPolicyChanged()
            completion?()
        }
    }
}
