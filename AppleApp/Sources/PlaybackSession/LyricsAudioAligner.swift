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
    typealias Playhead = @MainActor () -> Double

    /// The legacy recogniser runs a neural acoustic model in this process.
    /// Running it over a whole track the moment the track starts stacked
    /// hundreds of megabytes and several cores on top of the transition's own
    /// analysis, so it trails a little ahead of the listener instead.
    private static let leadSeconds = 40.0
    /// …and its first chunk waits for the blend into this track to settle.
    private static let startDelaySeconds = 12.0
    /// SpeechTranscriber runs out of process and hears a whole song in a few
    /// seconds, so it starts almost at once and takes the whole track. Pacing
    /// it with the listener kept the lyric half-timed for the entire song,
    /// and a half-timed lyric is the one whose highlight wanders.
    private static let transcriberStartDelaySeconds = 2.0

    private static let chunkSeconds = 8.0
    private static let overlapSeconds = 1.25
    private static let minimumChunkSeconds = 1.0
    private static let maximumUnavailableRetries = 30
    private static let minimumProgressSeconds = 0.75

    /// How much of the lyric the audio actually timed: sung lines that now carry
    /// word timings out of those that needed them. The label the listener sees
    /// is built from this, never from "at least one line matched".
    struct Coverage: Sendable, Equatable {
        var timed: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(timed) / Double(total) : 0 }
    }

    /// Returns how many of the lines that lacked word timings received them.
    @discardableResult
    static func align(
        lines: [LyricLineDto],
        durationSeconds: Double,
        decode: @escaping Decode,
        playhead: @escaping Playhead = { 0 },
        onUpdate: @escaping Update
    ) async -> Coverage {
        let needing = lines.indices.filter { needsWords(lines[$0]) }
        let none = Coverage(timed: 0, total: needing.count)
        guard durationSeconds > 0, !needing.isEmpty else { return none }

        var latest = lines
        let track: Update = { updated in
            latest = updated
            onUpdate(updated)
        }
        // SpeechTranscriber (OS 26+) is the recogniser this needs: a long-form
        // model that hears a continuous stream, gives every word a time range
        // and a real confidence, runs out of process (single-digit megabytes
        // here), and asks for no Speech permission. The older recogniser below
        // was fed eight-second slices that cut words in half, heard the full
        // mix as dictation, and rarely matched both ends of a lyric line.
        if #available(iOS 26.0, macOS 26.0, *) {
            try? await Task.sleep(for: .seconds(transcriberStartDelaySeconds))
            guard !Task.isCancelled else { return none }
            let handled = await TranscriberAlignment.run(
                lines: lines,
                durationSeconds: durationSeconds,
                decode: decode,
                chunkSeconds: chunkSeconds,
                onUpdate: track
            )
            if handled { return coverage(of: latest, needing: needing) }
        }
        try? await Task.sleep(for: .seconds(startDelaySeconds))
        guard !Task.isCancelled else { return none }
        _ = await alignWithLegacyRecognizer(
            lines: lines,
            durationSeconds: durationSeconds,
            decode: decode,
            playhead: playhead,
            onUpdate: track
        )
        return coverage(of: latest, needing: needing)
    }

    private static func needsWords(_ line: LyricLineDto) -> Bool {
        guard !line.isGap, line.words.isEmpty else { return false }
        // Chinese, Japanese and Thai lines have no spaces between words.
        return line.text.split(whereSeparator: \.isWhitespace).count >= 2
            || line.text.unicodeScalars.filter(isUnspaced).count >= 2
    }

    private static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF:
            return true
        default:
            return false
        }
    }

    private static func coverage(of lines: [LyricLineDto], needing: [Int]) -> Coverage {
        let timed = needing.filter { $0 < lines.count && !lines[$0].words.isEmpty }.count
        return Coverage(timed: timed, total: needing.count)
    }

    private static func alignWithLegacyRecognizer(
        lines: [LyricLineDto],
        durationSeconds: Double,
        decode: @escaping Decode,
        playhead: @escaping Playhead,
        onUpdate: @escaping Update
    ) async -> Bool {
        guard lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              await requestAuthorization()
        else { return false }

        let phrases = lines.map(\.text).filter { !$0.isEmpty }.prefix(100)
        guard let locale = recognizerLocale(for: phrases.joined(separator: " ")),
              let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            NSLog("[BitChord] local lyric alignment unavailable for this language/device")
            return false
        }

        var observations: [LyricWordObservation] = []
        var lastSignature = timingSignature(lines)
        var startSeconds = 0.0
        var alignedAtLeastOneLine = false
        var noAudioRetries = 0

        while startSeconds < durationSeconds {
            if Task.isCancelled { return alignedAtLeastOneLine }
            while startSeconds > playhead() + leadSeconds {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return alignedAtLeastOneLine }
            }
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
                    // From the lyric as fetched each time; see TranscriberAlignment.
                    let input = AlignmentInput(lines: lines, observations: observations)
                    let output = await Task.detached(priority: .utility) {
                        AlignmentOutput(lines: LyricsAudioAlignment.shared.align(
                            lines: input.lines,
                            observations: input.observations,
                            fold: LyricsAudioAligner.fold
                        ))
                    }.value
                    let updated = output.lines
                    let signature = timingSignature(updated)
                    if signature != lastSignature,
                       updated.contains(where: { !$0.words.isEmpty })
                    {
                        lastSignature = signature
                        alignedAtLeastOneLine = true
                        onUpdate(updated)
                    }
                } catch is CancellationError {
                    return alignedAtLeastOneLine
                } catch {
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
        return alignedAtLeastOneLine
    }

    static func recognizerLanguage(for lines: [LyricLineDto]) -> Locale? {
        recognizerLocale(for: lines.map(\.text).filter { !$0.isEmpty }.prefix(100).joined(separator: " "))
    }

    /// Every language the lyric is sung in, most-sung first. A song that
    /// switches language (an English hook over Spanish verses, a Yoruba
    /// bridge) needs a recognizer for each: one model hears another
    /// language's lines as its own words, and none of them match.
    static func lyricLanguages(for lines: [LyricLineDto]) -> [Locale.Language] {
        let texts = lines.filter { !$0.isGap }.map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.prefix(200).joined(separator: "\n"))
        let dominant = recognizer.dominantLanguage
        var counts: [NLLanguage: Int] = [:]
        for text in texts {
            recognizer.reset()
            recognizer.processString(text)
            // A short line is easy to misread as another language; only a
            // line the detector is sure of counts.
            guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
                  confidence >= 0.75 || (confidence >= 0.5 && text.count >= 24)
            else { continue }
            counts[language, default: 0] += 1
        }
        let floor = max(3, texts.count / 10)
        var ordered: [NLLanguage] = dominant.map { [$0] } ?? []
        for (language, count) in counts.sorted(by: { $0.value > $1.value })
        where count >= floor && !ordered.contains(language) {
            ordered.append(language)
        }
        return ordered.prefix(3).map { Locale.Language(identifier: $0.rawValue) }
    }

    private static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    private static func recognizerLocale(for text: String) -> Locale? {
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(text)
        let detectedLanguage = languageRecognizer.dominantLanguage?.rawValue.lowercased()
        let preferredLanguage = Locale.preferredLanguages.first
        let locales = SFSpeechRecognizer.supportedLocales()

        if let detectedLanguage,
           let match = locales.first(where: {
               languageCode(for: $0) == detectedLanguage
           }) {
            return match
        }
        if let preferredLanguage,
           let match = locales.first(where: {
               $0.identifier.replacingOccurrences(of: "_", with: "-")
                   .caseInsensitiveCompare(preferredLanguage.replacingOccurrences(of: "_", with: "-")) == .orderedSame
           }) {
            return match
        }
        return locales.first(where: { languageCode(for: $0) == "en" })
    }

    private static func languageCode(for locale: Locale) -> String {
        locale.identifier
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first
            .map(String.init)?
            .lowercased() ?? ""
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

    /// How a word is compared with what was heard: without case, accents,
    /// tone marks or character width, so "mọ'lẹ" matches "mo'le" and
    /// full-width kana matches half-width. Lyrics and recognizers disagree
    /// on all of these, most in languages written with diacritics.
    nonisolated static let fold: (String) -> String = { text in
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// Runs the shared text-constrained matcher off the UI actor.
    static func match(_ lines: [LyricLineDto], _ observations: [LyricWordObservation]) async -> [LyricLineDto] {
        let input = AlignmentInput(lines: lines, observations: observations)
        let started = Date()
        let output = await Task.detached(priority: .utility) {
            AlignmentOutput(lines: LyricsAudioAlignment.shared.align(
                lines: input.lines,
                observations: input.observations,
                fold: LyricsAudioAligner.fold
            ))
        }.value.lines
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0.25 {
            PlaybackDebugLog.shared.record(String(
                format: "lyrics: matching %d heard words took %.0f ms", observations.count, elapsed * 1_000
            ))
        }
        return output
    }

    static func signature(_ lines: [LyricLineDto]) -> String { timingSignature(lines) }
}

/// Word timing from SpeechTranscriber over one continuous stream of the track.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
private enum TranscriberAlignment {
    /// What every pass has heard so far, and the timing last sent out.
    private final class Heard {
        var words: [LyricWordObservation] = []
        var signature: String
        init(signature: String) { self.signature = signature }
    }

    /// Re-matching the whole song costs a few hundred milliseconds of one
    /// core; results arrive every second or two, so it waits for this many
    /// new words, or this long, before matching again.
    private static let rematchWords = 40
    private static let rematchSeconds = 4.0

    /// Returns false when the transcriber cannot serve this language or device,
    /// so the caller can fall back; true once it has run (matched or not).
    static func run(
        lines: [LyricLineDto],
        durationSeconds: Double,
        decode: @escaping LyricsAudioAligner.Decode,
        chunkSeconds: Double,
        onUpdate: @escaping LyricsAudioAligner.Update
    ) async -> Bool {
        var locales: [Locale] = []
        for language in LyricsAudioAligner.lyricLanguages(for: lines) {
            guard let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: language.maximalIdentifier)
            ), !locales.contains(locale) else { continue }
            locales.append(locale)
        }
        if locales.isEmpty, let wanted = LyricsAudioAligner.recognizerLanguage(for: lines),
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            locales = [locale]
        }
        guard !locales.isEmpty else { return false }

        // One pass per language, each over the whole track. Every pass adds
        // what it heard to the same pool, and the lyric is matched against
        // all of it: a verse the English model heard as noise is matched by
        // the Spanish one, and the chain sorts out which words belong where.
        let heard = Heard(signature: LyricsAudioAligner.signature(lines))
        var ran = false
        for locale in locales {
            if Task.isCancelled { return true }
            let done = await transcribe(
                locale: locale,
                lines: lines,
                durationSeconds: durationSeconds,
                decode: decode,
                chunkSeconds: chunkSeconds,
                heard: heard,
                onUpdate: onUpdate
            )
            ran = ran || done
        }
        if locales.count > 1 {
            PlaybackDebugLog.shared.record(
                "lyrics: heard \(heard.words.count) words over \(locales.map(\.identifier).joined(separator: ", "))"
            )
        }
        return ran || Task.isCancelled
    }

    private static func transcribe(
        locale: Locale,
        lines: [LyricLineDto],
        durationSeconds: Double,
        decode: @escaping LyricsAudioAligner.Decode,
        chunkSeconds: Double,
        heard: Heard,
        onUpdate: @escaping LyricsAudioAligner.Update
    ) async -> Bool {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
        } catch {
            PlaybackDebugLog.shared.record("lyrics: speech model for \(locale.identifier) unavailable: \(error)")
            return false
        }
        guard !Task.isCancelled,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { return Task.isCancelled }

        let context = AnalysisContext()
        let vocabulary = Set(lines.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 })
        context.contextualStrings[.general] = Array(vocabulary.prefix(200))
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // The lyric's own words, as hints. Not required: a context the
        // analyzer refuses only costs the hints.
        try? await analyzer.setContext(context)

        // Words arrive as each stretch of audio is finalised; the shared
        // matcher re-runs over everything heard every few dozen words.
        let consumer = Task { @MainActor in
            var matchedCount = heard.words.count
            var matchedAt = Date()
            @MainActor func rematch() async {
                matchedCount = heard.words.count
                matchedAt = Date()
                // Always from the lyric as fetched, with everything heard so
                // far. Matching on top of the previous pass let a line missed
                // then take words after lines already timed below it, so times
                // ran backwards and the highlight bounced between sections.
                let updated = await LyricsAudioAligner.match(lines, heard.words)
                let next = LyricsAudioAligner.signature(updated)
                if next != heard.signature {
                    heard.signature = next
                    onUpdate(updated)
                }
            }
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = CMTimeGetSeconds(range.start)
                    let end = CMTimeGetSeconds(range.end)
                    guard start.isFinite, end.isFinite, end > start else { continue }
                    heard.words.append(LyricWordObservation(
                        startMs: Int64((start * 1_000).rounded()),
                        endMs: Int64((end * 1_000).rounded()),
                        text: text,
                        confidence: run.transcriptionConfidence ?? 0.5
                    ))
                }
                if heard.words.count - matchedCount >= rematchWords
                    || Date().timeIntervalSince(matchedAt) >= rematchSeconds {
                    await rematch()
                }
            }
            if heard.words.count != matchedCount { await rematch() }
        }

        let analysis = Task {
            try await analyzer.start(inputSequence: stream)
        }
        defer {
            input.finish()
            analysis.cancel()
        }

        // Feed the whole track as one continuous stream, a few seconds at a
        // time. Slices queue at the analyzer's 16 kHz mono format (about 0.5 MB
        // each), so even a song queued whole before it is heard is ~15 MB.
        var position = 0.0
        var misses = 0
        while position < durationSeconds - 0.05 {
            if Task.isCancelled { break }
            let length = min(chunkSeconds, durationSeconds - position)
            let start = position
            // Each slice takes a turn with the app's other heavy analyses. Fed
            // back to back the whole song decoded at a full core beside the
            // transition planner, which is a core of its own; slices are a few
            // tens of milliseconds each, so they fit between those jobs and the
            // transcriber, out of process, is never starved for long.
            let region = await AnalysisTurns.take {
                await Task.detached(priority: .utility) { decode(start, length) }.value
            }
            guard let region, region.sampleRate > 0, !region.samples.isEmpty else {
                // A progressive file may not have this stretch yet.
                misses += 1
                if misses > 30 { break }
                try? await Task.sleep(for: .milliseconds(700))
                continue
            }
            misses = 0
            guard let buffer = convert(region, to: format) else { break }
            input.yield(AnalyzerInput(
                buffer: buffer,
                bufferStartTime: CMTime(seconds: region.startSeconds, preferredTimescale: 48_000)
            ))
            let advanced = region.startSeconds + Double(region.samples.count) / region.sampleRate
            guard advanced > position + 0.05 else { break }
            position = advanced
        }

        if Task.isCancelled {
            await analyzer.cancelAndFinishNow()
            consumer.cancel()
            return true
        }
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            PlaybackDebugLog.shared.record("lyrics: transcription ended early: \(error)")
        }
        _ = try? await consumer.value
        return true
    }

    private static func convert(_ region: LyricsAudioAligner.Region, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: region.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(region.samples.count)),
        let channel = source.floatChannelData?[0]
        else { return nil }
        source.frameLength = AVAudioFrameCount(region.samples.count)
        region.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        if sourceFormat == format { return source }
        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil else { return nil }
        return output
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

