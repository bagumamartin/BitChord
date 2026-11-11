import CoreML
import Foundation
import os

/// The accelerated Beat This! final0 path: the same log-mel window the rten
/// graph reads, run through the compiled Core ML model on the CPU and Neural
/// Engine.
///
/// Deliberately never `.all` or `.cpuAndGPU`. This app analyses while audio
/// continues in the background on iOS, and Core ML/Metal work submitted there
/// has been observed to trip an assertion that aborts the process (see
/// `MusicUnderstandingAnalyzer`). `.cpuAndNeuralEngine` keeps the accelerator
/// out of the GPU; the scene's background flag is still honoured, so a
/// background stretch simply returns `nil` and the planner uses rten.
final class BeatThisCoreML: BeatAccelerator, @unchecked Sendable {
    static let inputFrames = 1500
    static let melBins = 128

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.bitchord.app",
        category: "Automix"
    )

    /// Profiling override: `defaults write <bundle> BeatThisComputeUnits cpu|ane`.
    static var computeUnits: MLComputeUnits {
        switch UserDefaults.standard.string(forKey: "BeatThisComputeUnits") {
        case "cpu": return .cpuOnly
        default: return .cpuAndNeuralEngine
        }
    }

    /// How long the loaded model outlives its last prediction.
    ///
    /// The first prediction makes the Neural Engine allocate its working
    /// buffers, about 430 MB for this graph, and macOS charges them to the app
    /// for as long as the `MLModel` lives — up to a minute after a plan's beat
    /// pass ended. A plan predicts its windows a few hundred milliseconds
    /// apart, so the model stays for the whole pass and is let go soon after;
    /// loading it again from the compiled cache costs about 60 ms.
    static let idleRelease: TimeInterval = 2

    private let modelURL: URL
    private let configuration: MLModelConfiguration
    /// Guarded by `predictionLock`; `nil` while idle.
    private var model: MLModel?
    private var lastPrediction = Date.distantPast
    private var releaseScheduled = false
    /// Predicted one window at a time. `MLModel` is documented as safe to call
    /// concurrently, but serialising keeps the Neural Engine request queue
    /// predictable and makes the failure accounting single-threaded.
    private let predictionLock = NSLock()
    private let failureLock = NSLock()
    private var loggedFailure = false
    private static let releaseQueue = DispatchQueue(label: "BeatThisCoreML.release", qos: .utility)

    init?(modelURL: URL) {
        self.modelURL = modelURL
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        self.configuration = configuration
        // Loaded once up front so a model an OS update invalidated is found
        // here, where the loader can rebuild it, rather than mid-plan. Loading
        // alone does not allocate the Neural Engine buffers.
        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            Self.logFailure("could not load \(modelURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        scheduleRelease()
    }

    /// `mel` is little-endian `f32` bytes (the bridge's layout; Apple silicon
    /// and Intel are both little-endian, so it is copied as is).
    func infer(mel: Data) -> BeatLogits? {
        let valueCount = Self.inputFrames * Self.melBins
        guard mel.count == valueCount * MemoryLayout<Float>.size else {
            logOnce("unexpected input of \(mel.count) bytes")
            return nil
        }
        // A backgrounded iOS app must not start accelerator work, even on the
        // Neural Engine. rten's CPU pass is always available, so returning nil
        // is the safe answer and the planner recomputes the track there.
        guard !MusicUnderstandingAnalyzer.isBackgrounded else { return nil }

        predictionLock.lock()
        defer { predictionLock.unlock() }

        // Its own pool per window. This runs on the planner's thread inside one
        // long synchronous FFI call, so Core ML's autoreleased prediction
        // objects would otherwise live until the whole plan returned.
        let logits = autoreleasepool { predict(mel) }
        lastPrediction = Date()
        scheduleRelease()
        return logits
    }

    /// Lets the model go once `idleRelease` has passed with no prediction.
    /// Called with `predictionLock` held.
    private func scheduleRelease() {
        guard !releaseScheduled else { return }
        releaseScheduled = true
        Self.releaseQueue.asyncAfter(deadline: .now() + Self.idleRelease) { [weak self] in
            self?.releaseIfIdle()
        }
    }

    private func releaseIfIdle() {
        predictionLock.lock()
        defer { predictionLock.unlock() }
        releaseScheduled = false
        let idle = Date().timeIntervalSince(lastPrediction)
        if idle >= Self.idleRelease {
            model = nil
        } else {
            releaseScheduled = true
            Self.releaseQueue.asyncAfter(deadline: .now() + (Self.idleRelease - idle)) { [weak self] in
                self?.releaseIfIdle()
            }
        }
    }

    private func predict(_ mel: Data) -> BeatLogits? {
        do {
            let model: MLModel
            if let loaded = self.model {
                model = loaded
            } else {
                model = try MLModel(contentsOf: modelURL, configuration: configuration)
                self.model = model
            }
            let input = try MLMultiArray(
                shape: [1, NSNumber(value: Self.inputFrames), NSNumber(value: Self.melBins)],
                dataType: .float32
            )
            mel.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                input.dataPointer.copyMemory(from: base, byteCount: source.count)
            }
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["spectrogram": MLFeatureValue(multiArray: input)]
            )
            let output = try model.prediction(from: provider)
            guard let beat = output.featureValue(for: "beat")?.multiArrayValue,
                  let downbeat = output.featureValue(for: "downbeat")?.multiArrayValue,
                  let beatValues = floats(from: beat),
                  let downbeatValues = floats(from: downbeat)
            else {
                logOnce("prediction did not carry float32 beat and downbeat heads")
                return nil
            }
            return BeatLogits(beat: beatValues, downbeat: downbeatValues)
        } catch {
            logOnce("prediction failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reads the output buffer directly as the bridge's little-endian `f32`
    /// bytes. An `MLMultiArray` is contiguous for a freshly produced
    /// prediction, and the contract is float32; boxed `NSNumber` access here
    /// would cost 3000 objects per window.
    private func floats(from array: MLMultiArray) -> Data? {
        guard array.dataType == .float32, array.count == Self.inputFrames else {
            logOnce("unexpected output type or length")
            return nil
        }
        return Data(bytes: array.dataPointer, count: array.count * MemoryLayout<Float>.size)
    }

    private func logOnce(_ message: String) {
        failureLock.lock()
        let first = !loggedFailure
        loggedFailure = true
        failureLock.unlock()
        if first {
            Self.logFailure(message)
        }
    }

    private static func logFailure(_ message: String) {
        os_log(.error, log: log, "Beat This! Core ML: %{public}@", message)
    }
}
