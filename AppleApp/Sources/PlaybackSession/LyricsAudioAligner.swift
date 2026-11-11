import AVFoundation
import Foundation
import NaturalLanguage
import Speech
import BitChordShared

/// Incremental, on-device alignment of fetched lyric text against the playing
/// source. Decoding and speech recognition run away from the render/UI threads;
/// each short result is merged back into the original lyric document as it is
/// ready, so the player never waits for a full-track pass.
@MainActor
enum LyricsAudioAligner {
    struct Region: Sendable {
        var samples: [Float]
        var sampleRate: Double
        var startSeconds: Double
    }

    /// Kotlin DTOs are immutable value snapshots here. Keep them in an explicit
    /// unchecked-Sendable box so matching can run off the UI actor.
    private struct AlignmentInput: @unchecked Sendable {
        var lines: [LyricLineDto]
        var observations: [LyricWordObservation]
    }

    private struct AlignmentOutput: @unchecked Sendable {
        var lines: [LyricLineDto]
    }

    typealias Decode = @Sendable (_ startSeconds: Double, _ durationSeconds: Double) -> Region?
    typealias Update = @MainActor ([LyricLineDto]) -> Void

    private static let chunkSeconds = 8.0
    private static let overlapSeconds = 1.25
    private static let minimumChunkSeconds = 1.0
    private static let maximumUnavailableRetries = 30
    private static let minimumProgressSeconds = 0.75

    /// Returns the final outcome and reports useful progress as chunks finish.
    @discardableResult
    static func align(
        lines: [LyricLineDto],
        durationSeconds: Double,
        decode: @escaping Decode,
        allowPermissionRequest: Bool = false,
        onState: @escaping @MainActor (LyricsAlignmentState) -> Void,
        onUpdate: @escaping Update
    ) async -> LyricsAlignmentState {
        guard durationSeconds > 0,
              lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return .audioUnavailable }
        guard await hasSpeechAuthorization(allowRequest: allowPermissionRequest) else { return .permissionNeeded }

        let phrases = lines.map(\.text).filter { !$0.isEmpty }.prefix(100)
        let detected = detectedLanguage(for: phrases.joined(separator: " "))
        let localeCandidates = LyricsLocaleCandidates.ordered(
            detectedLanguages: detected.map { [$0] } ?? [],
            preferredIdentifiers: Locale.preferredLanguages,
            supportedIdentifiers: SFSpeechRecognizer.supportedLocales().map(\.identifier)
        )
        guard !localeCandidates.isEmpty else { return .languageUnavailable }
        var chosenRecognizer: SFSpeechRecognizer?
        for identifier in localeCandidates {
            guard let candidate = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
                  candidate.isAvailable, candidate.supportsOnDeviceRecognition else { continue }
            chosenRecognizer = candidate
            break
        }
        guard let recognizer = chosenRecognizer else { return .deviceUnavailable }
        onState(.analyzing)

        var observations: [LyricWordObservation] = []
        var alignedLines = lines
        var lastSignature = timingSignature(lines)
        var startSeconds = 0.0
        var alignedAtLeastOneLine = false
        var noAudioRetries = 0
        var hadRecognitionError = false

        while startSeconds < durationSeconds {
            if Task.isCancelled { return alignedAtLeastOneLine ? .partial : .noMatch }
            let requestedDuration = min(chunkSeconds, durationSeconds - startSeconds)
            let region = await Task.detached(priority: .utility) {
                decode(startSeconds, requestedDuration)
            }.value

            guard let region,
                  region.sampleRate > 0,
                  region.samples.count >= Int(region.sampleRate * minimumChunkSeconds)
            else {
                noAudioRetries += 1
                guard noAudioRetries <= maximumUnavailableRetries else { break }
                // A progressively fetched stream may not have this region yet.
                // Wait on this worker, never on playback, and re-open the growing
                // source so the analysis decoder sees the newly arrived bytes.
                try? await Task.sleep(for: .milliseconds(700))
                continue
            }
            noAudioRetries = 0

            let endSeconds = region.startSeconds + Double(region.samples.count) / region.sampleRate
            let rms = await Task.detached(priority: .utility) {
                sqrt(region.samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(region.samples.count))
            }.value
            if rms >= 0.001 {
                do {
                    let heard = try await recognize(
                        region,
                        recognizer: recognizer,
                        contextualPhrases: Array(phrases)
                    )
                    observations = merge(observations, heard)
                    let input = AlignmentInput(lines: alignedLines, observations: observations)
                    let output = await Task.detached(priority: .utility) {
                        AlignmentOutput(lines: LyricsAudioAlignment.shared.align(
                            lines: input.lines,
                            observations: input.observations
                        ))
                    }.value
                    let updated = output.lines
                    let signature = timingSignature(updated)
                    if signature != lastSignature,
                       updated.contains(where: { !$0.words.isEmpty })
                    {
                        lastSignature = signature
                        alignedAtLeastOneLine = true
                        alignedLines = updated
                        onUpdate(updated)
                        onState(updated.contains(where: { !$0.isGap && $0.words.isEmpty }) ? .partial : .complete)
                    }
                } catch is CancellationError {
                    return alignedAtLeastOneLine ? .partial : .failed
                } catch {
                    hadRecognitionError = true
                    NSLog("[BitChord] local lyric recognition chunk at %.1fs failed: %@",
                          startSeconds, String(describing: error))
                }
            }

            if endSeconds >= durationSeconds - 0.05 { break }
            // A growing stream may yield only the bytes currently on disk. Move
            // to its available edge with overlap, so the next reopen can pick up
            // newly arrived audio instead of skipping ahead by a full chunk.
            let nextStart = max(startSeconds + minimumProgressSeconds, endSeconds - overlapSeconds)
            guard nextStart > startSeconds + 0.05 else { break }
            startSeconds = nextStart
        }
        if alignedAtLeastOneLine {
            return alignedLines.contains(where: { !$0.isGap && $0.words.isEmpty }) ? .partial : .complete
        }
        if noAudioRetries > 0 { return .audioUnavailable }
        return hadRecognitionError ? .failed : .noMatch
    }

    private static func detectedLanguage(for text: String) -> String? {
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(text)
        return languageRecognizer.dominantLanguage?.rawValue.lowercased()
    }

    private static func hasSpeechAuthorization(allowRequest: Bool) async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined where allowRequest:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    private static func recognize(
        _ region: Region,
        recognizer: SFSpeechRecognizer,
        contextualPhrases: [String]
    ) async throws -> [LyricWordObservation] {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: region.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(region.samples.count)
        ),
        let channel = buffer.floatChannelData?.pointee
        else { return [] }

        buffer.frameLength = AVAudioFrameCount(region.samples.count)
        region.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = contextualPhrases
        let box = SpeechTaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let words = result.bestTranscription.segments.map { segment in
                            LyricWordObservation(
                                startMs: Int64(((region.startSeconds + segment.timestamp) * 1_000).rounded()),
                                endMs: Int64(((region.startSeconds + segment.timestamp + segment.duration) * 1_000).rounded()),
                                text: segment.substring,
                                confidence: Double(segment.confidence)
                            )
                        }
                        box.finish(.success(words))
                    } else if let error {
                        box.finish(.failure(error))
                    }
                }
                box.install(task)
                request.append(buffer)
                request.endAudio()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func merge(
        _ existing: [LyricWordObservation],
        _ incoming: [LyricWordObservation]
    ) -> [LyricWordObservation] {
        var result = existing
        for word in incoming where word.confidence >= 0.12 && word.endMs > word.startMs {
            let duplicate = result.firstIndex(where: {
                normalize($0.text) == normalize(word.text) && abs($0.startMs - word.startMs) <= 180
            })
            if let duplicate {
                if word.confidence > result[duplicate].confidence { result[duplicate] = word }
            } else {
                result.append(word)
            }
        }
        return result.sorted { $0.startMs < $1.startMs }
    }

    private static func timingSignature(_ lines: [LyricLineDto]) -> String {
        lines.map { line in
            line.words.map { "\($0.startMs):\($0.endMs)" }.joined(separator: ",")
        }.joined(separator: "|")
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

private final class SpeechTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[LyricWordObservation], Error>?
    private var task: SFSpeechRecognitionTask?
    private var settled = false

    func install(_ continuation: CheckedContinuation<[LyricWordObservation], Error>) {
        lock.lock()
        let alreadySettled = settled
        if !alreadySettled { self.continuation = continuation }
        lock.unlock()
        if alreadySettled { continuation.resume(throwing: CancellationError()) }
    }

    func install(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let alreadySettled = settled
        if !alreadySettled { self.task = task }
        lock.unlock()
        if alreadySettled { task.cancel() }
    }

    func finish(_ result: Result<[LyricWordObservation], Error>) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        if case .failure = result { task?.cancel() }
        continuation?.resume(with: result)
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}
