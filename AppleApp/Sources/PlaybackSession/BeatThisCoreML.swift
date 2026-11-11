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

    private let model: MLModel
    /// Predicted one window at a time. `MLModel` is documented as safe to call
    /// concurrently, but serialising keeps the Neural Engine request queue
    /// predictable and makes the failure accounting single-threaded.
    private let predictionLock = NSLock()
    private let failureLock = NSLock()
    private var loggedFailure = false

    init?(modelURL: URL) {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            Self.logFailure("could not load \(modelURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    func infer(mel: [Float]) -> BeatLogits? {
        guard mel.count == Self.inputFrames * Self.melBins else {
            logOnce("unexpected input of \(mel.count) values")
            return nil
        }
        // A backgrounded iOS app must not start accelerator work, even on the
        // Neural Engine. rten's CPU pass is always available, so returning nil
        // is the safe answer and the planner recomputes the track there.
        guard !MusicUnderstandingAnalyzer.isBackgrounded else { return nil }

        predictionLock.lock()
        defer { predictionLock.unlock() }

        do {
            let input = try MLMultiArray(
                shape: [1, NSNumber(value: Self.inputFrames), NSNumber(value: Self.melBins)],
                dataType: .float32
            )
            mel.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                input.dataPointer
                    .bindMemory(to: Float.self, capacity: mel.count)
                    .update(from: base, count: mel.count)
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

    /// Reads the output buffer directly. An `MLMultiArray` is contiguous for a
    /// freshly produced prediction, and the contract is float32; boxed
    /// `NSNumber` access here would cost 3000 objects per window.
    private func floats(from array: MLMultiArray) -> [Float]? {
        guard array.dataType == .float32, array.count == Self.inputFrames else {
            logOnce("unexpected output type or length")
            return nil
        }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        return Array(UnsafeBufferPointer(start: pointer, count: array.count))
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
