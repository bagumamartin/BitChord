import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

/// On-device Music Understanding → Automix analysis overlay.
///
/// Available on iOS 27 / macOS 27+. Older OS versions no-op and leave the
/// Rust DSP / Beat This path alone.
///
/// GPU note: Music Understanding runs Core ML / MPS graph work. That asserts
/// (and can abort the process) when the app is backgrounded, and Apple's
/// `InstrumentActivityModel` has been observed to hard-crash with
/// `shape for TensorData is not static`. We therefore only analyze in the
/// foreground and never request `.instrumentActivity`.
enum MusicUnderstandingAnalyzer {
    /// True while GPU work must not be started. Set synchronously from the
    /// scene's background transition and cleared on foreground return.
    ///
    /// Why sticky instead of just checking `applicationState` before each
    /// analysis: the check-then-submit races the lock button — the state reads
    /// `.active`, the app backgrounds mid-inference, and the submission fails
    /// with `BackgroundExecutionNotPermitted`, spraying a wall of Metal/E5RT
    /// errors into the log once *per track*. The queue now cancels active
    /// sessions through the framework API and prevents subsequent attempts
    /// during this background stretch from touching the GPU again.
    ///
    /// iOS only: macOS allows background GPU work, so the flag is never set
    /// there.
    private static var gpuSuspended = false
    private static let gpuSuspendLock = NSLock()

    /// Call from the scene's `.background` transition.
    static func noteBackground() {
#if canImport(UIKit)
        setGpuSuspended(true)
        Task { await MusicAnalysisQueue.shared.cancelAll() }
#endif
    }

    /// Call from the scene's `.active` transition.
    static func noteForeground() {
        setGpuSuspended(false)
    }

    private static func isGpuSuspended() -> Bool {
        gpuSuspendLock.lock()
        defer { gpuSuspendLock.unlock() }
        return gpuSuspended
    }

    /// True while the scene is backgrounded on iOS. The Core ML beat backend
    /// reuses this: `.cpuAndNeuralEngine` never touches the GPU, but background
    /// analysis stays on rten rather than betting on that distinction.
    static var isBackgrounded: Bool { isGpuSuspended() }

    /// Synchronous so it can be called from async contexts without tripping
    /// Swift 6's scoped-locking rule (`lock()`/`unlock()` must not appear
    /// lexically inside an async function).
    private static func setGpuSuspended(_ value: Bool) {
        gpuSuspendLock.lock()
        defer { gpuSuspendLock.unlock() }
        gpuSuspended = value
    }

    /// True when the current OS can run Music Understanding analysis.
    static var isAvailable: Bool {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return true
        }
        return false
    }

    /// Writes a track the app's own decoder reads to a PCM file AVFoundation
    /// opens; false on failure.
    typealias Decode = PCMTranscode.Writer

    /// Analyze a local file and seed the native Automix overlay cache.
    /// Returns true when an overlay was seeded.
    ///
    /// `decode` is how a file AVFoundation cannot open still gets analysed:
    /// streamed tracks are cached as WebM/Opus, which `AVURLAsset` rejects
    /// (`invalidAsset`), so those are decoded natively and handed over as a
    /// temporary PCM file.
    @discardableResult
    static func analyzeAndSeed(
        filePath: String,
        allowAccelerator: Bool = true,
        decode: Decode? = nil
    ) async -> Bool {
        #if DEBUG
        // Isolate native timer/mixer validation from the system GPU models.
        // A device run exposed a StructuralFeaturesModel MPS assertion on the
        // synthetic tone fixture; that assertion aborts outside Swift errors.
        if ProcessInfo.processInfo.arguments.contains("--verify-sleep") { return false }
        #endif
        guard isAvailable else {
            return AutomixOverlayCache.seedCached(forFilePath: filePath)
        }
        let path = filePath.hasPrefix("file://")
            ? (URL(string: filePath)?.path ?? filePath)
            : filePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return false
        }
        guard !Task.isCancelled else { return false }
        guard let fingerprint = AutomixOverlayCache.fingerprint(forFilePath: path) else { return false }
        // Completed, unchanged files already have the needed result. Reusing
        // it avoids an entire GPU analysis on each queue/transport update.
        if AutomixOverlayCache.seedCached(forFilePath: path) { return true }
        guard allowAccelerator else { return false }
        // A background stretch goes straight to the disk cache without an
        // await: no MainActor hop, no race with the lock button.
        if isGpuSuspended() {
            return AutomixOverlayCache.seedCached(forFilePath: path)
        }
        // Only an uncached, complete file needs accelerator work. Otherwise
        // the native planner retains its cached/CPU fallback.
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *),
           await isForeground()
        {
            let key = "\(path)|\(fingerprint.size)|\(fingerprint.modified)"
            if await MusicAnalysisQueue.shared.perform(key: key, operation: {
                if AutomixOverlayCache.seedCached(forFilePath: path) { return true }
                return await analyzeAvailable(path: path, decode: decode)
            }) {
                return true
            }
        }
        return AutomixOverlayCache.seedCached(forFilePath: path)
    }

    /// Music Understanding needs GPU; never start a session off-screen.
    private static func isForeground() async -> Bool {
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        #else
        true
        #endif
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private static func analyzeAvailable(path: String, decode: Decode?) async -> Bool {
        #if canImport(MusicUnderstanding)
        // Synchronous pre-check before the MainActor hop below narrows the
        // race further: a backgrounding that landed between the caller's check
        // and this one still turns back here.
        guard !isGpuSuspended() else { return false }
        // Re-check right before GPU work — the first await can race a lock.
        guard await isForeground() else { return false }
        var transcoded: URL?
        defer { if let transcoded { try? FileManager.default.removeItem(at: transcoded) } }
        do {
            guard let fingerprint = AutomixOverlayCache.fingerprint(forFilePath: path) else { return false }
            var url = URL(fileURLWithPath: path)
            if !AVFoundationReadable.canOpen(path) {
                guard let decode, let pcm = await Task.detached(priority: .utility, operation: {
                    PCMTranscode.write(path: path, writer: decode)
                }).value else {
                    NSLog("[BitChord] Music Understanding: could not decode %@", path)
                    return false
                }
                transcoded = pcm
                url = pcm
            }
            guard !Task.isCancelled else { return false }
            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            let session = try await MusicUnderstandingSession(asset: asset)
            guard !Task.isCancelled, !isGpuSuspended(), await isForeground() else { await session.cancel(); return false }
            // Omit `.instrumentActivity` — its MPS graph aborts the process.
            // Omit `.pace` for the same Metal family until Apple stabilizes it.
            let result: MusicUnderstandingSession.SessionResult
            do {
                result = try await withTaskCancellationHandler {
                    // `.structure` is left out on purpose: measured on a
                    // four-minute track its model holds about 270 MB resident
                    // in this process after the session is over (rhythm and
                    // key together hold about 90 MB), and the native DSP pass
                    // already produces sections, phrases and the mix points.
                    // Rhythm is the part worth having: its beat and bar grid
                    // stands in for the Beat This! pass, so a track it covers
                    // never runs that model on the Neural Engine at all.
                    try await session.analyze(for: [.rhythm, .key])
                } onCancel: {
                    Task { await session.cancel() }
                }
            } catch {
                await session.cancel()
                throw error
            }
            guard !Task.isCancelled, !isGpuSuspended(), fingerprint == AutomixOverlayCache.fingerprint(forFilePath: path) else { await session.cancel(); return false }
            let overlay = overlay(from: result)
            AutomixOverlayCache.store(overlay, forFilePath: path, expected: fingerprint)
            MemoryRelief.soon()
            return seedAutomixAnalysis(path: path, overlay: overlay)
        } catch {
            guard !Task.isCancelled else { return false }
            if await isForeground() {
                NSLog("[BitChord] Music Understanding failed for %@: %@", path, String(describing: error))
            } else {
                // Expected, not news: the GPU submission raced a lock and lost.
                // Suspend the rest of this background stretch so the failure —
                // and Apple's own Metal/E5RT wall that comes with it — happens
                // once per stretch instead of once per track.
                setGpuSuspended(true)
            }
            return false
        }
        #else
        return false
        #endif
    }

    #if canImport(MusicUnderstanding)
    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private static func overlay(from result: MusicUnderstandingSession.SessionResult) -> AutomixAnalysisOverlayRec {
        var bpm: Double?
        var beatConfidence: Double?
        var beatInterval: Double?
        var beats: [Double]?
        var downbeats: [Double]?
        if let rhythm = result.rhythm {
            if let value = rhythm.beatsPerMinute, value.isFinite, value > 0 {
                bpm = Double(value)
                beatInterval = 60.0 / Double(value)
                beatConfidence = 0.85
            }
            let beatTimes = rhythm.beats.compactMap { cmSeconds($0) }
            if beatTimes.count >= 2 {
                beats = beatTimes
                if bpm == nil {
                    let span = beatTimes.last! - beatTimes.first!
                    if span > 0 {
                        bpm = Double(beatTimes.count - 1) * 60.0 / span
                        beatInterval = 60.0 / bpm!
                        beatConfidence = 0.7
                    }
                }
            }
            let barTimes = rhythm.bars.compactMap { cmSeconds($0) }
            if !barTimes.isEmpty {
                downbeats = barTimes
            }
        }

        var key: String?
        var keyConfidence: Double?
        if let keyResult = result.key, let first = keyResult.ranges.first {
            key = "\(tonicName(first.value.tonic)) \(first.value.mode == .minor ? "minor" : "major")"
            keyConfidence = 0.8
        }

        var phrases: [Double]?
        var mixIn: Double?
        var outro: Double?
        var audibleStart: Double?
        var contentEnd: Double?
        if let structure = result.structure {
            let phraseStarts = structure.phrases.compactMap { cmSeconds($0.start) }
            if !phraseStarts.isEmpty {
                phrases = phraseStarts
            }
            if let firstSection = structure.sections.first {
                audibleStart = cmSeconds(firstSection.start)
                mixIn = cmSeconds(firstSection.end)
            }
            if let lastSection = structure.sections.last {
                outro = cmSeconds(lastSection.start)
                contentEnd = cmSeconds(lastSection.end)
            }
            if let firstPhrase = structure.phrases.first {
                audibleStart = audibleStart ?? cmSeconds(firstPhrase.start)
            }
        }

        // Vocal probability comes from Rust / Beat This — InstrumentActivity
        // is intentionally not requested (see analyzeAvailable).
        let vocalProbability: Double? = nil

        return AutomixAnalysisOverlayRec(
            bpm: bpm,
            beatConfidence: beatConfidence,
            beatInterval: beatInterval,
            beats: beats,
            downbeats: downbeats,
            key: key,
            keyConfidence: keyConfidence,
            phraseBoundaries: phrases,
            vocalProbability: vocalProbability,
            contentEnd: contentEnd,
            audibleStart: audibleStart,
            outroStart: outro,
            mixInTime: mixIn,
            source: "music_understanding"
        )
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private static func cmSeconds(_ time: CMTime) -> Double? {
        guard time.isValid, !time.isIndefinite else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private static func tonicName(_ tonic: KeyResult.Tonic) -> String {
        switch tonic {
        case .c: return "C"
        case .cSharp: return "C♯"
        case .dFlat: return "D♭"
        case .d: return "D"
        case .dSharp: return "D♯"
        case .eFlat: return "E♭"
        case .e: return "E"
        case .f: return "F"
        case .fSharp: return "F♯"
        case .gFlat: return "G♭"
        case .g: return "G"
        case .gSharp: return "G♯"
        case .aFlat: return "A♭"
        case .a: return "A"
        case .aSharp: return "A♯"
        case .bFlat: return "B♭"
        case .b: return "B"
        @unknown default: return "C"
        }
    }
    #endif
}
