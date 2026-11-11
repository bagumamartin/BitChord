import Foundation
import os

enum AutomixModelPolicy {
    static func paths(
        beat: String,
        vocal: String,
        accelerator: AutomixAccelerator?,
        playbackStarted: Bool,
        enabled: Bool,
        efficient: Bool
    ) -> (beat: String, vocal: String, accelerator: AutomixAccelerator?) {
        guard playbackStarted && enabled else { return ("", "", nil) }
        // The accelerator only makes sense beside the ONNX beat graph: that graph
        // is the fallback, runs short tracks, and gates `analyzer_ready`.
        let accelerated = efficient || beat.isEmpty ? nil : accelerator
        return (beat, efficient ? "" : vocal, accelerated)
    }
}

/// Serialize native model replacement off-main so rapid preference changes
/// finish in request order and never interleave two graph configurations.
actor AutomixModelLoader {
    static let shared = AutomixModelLoader()

    /// The Core ML model the analyzer holds, by the archive it came from.
    ///
    /// Every reload (playback start, the Automix toggle, a performance mode
    /// change, the model store's refresh) used to compile a fresh `MLModel`
    /// while the analyzer still held the last one, so for the length of the
    /// load two copies of the Neural Engine program — hundreds of megabytes of
    /// device buffers each — were resident together. The model is now kept
    /// while its archive is unchanged, and the old one is let go before a
    /// different one is loaded.
    private var registered: (identity: String, model: BeatThisCoreML)? {
        didSet {
            let present = registered != nil
            Self.acceleratorFlag.withLock { $0 = present }
        }
    }

    /// Whether the Neural Engine beat model is registered with the analyzer.
    ///
    /// Music Understanding reads it to decide whether to run its rhythm pass.
    /// That pass cost about 5 s of CPU per track — most of a transition's
    /// burst — where Beat This! on the Neural Engine costs about 0.15 s and
    /// tracks the beats themselves rather than a fixed-tempo grid. Without the
    /// Neural Engine model, Music Understanding's grid still beats the
    /// fallbacks, so it runs.
    nonisolated static var hasNeuralEngineBeatModel: Bool {
        acceleratorFlag.withLock { $0 }
    }
    private static let acceleratorFlag = OSAllocatedUnfairLock(initialState: false)

    func configure(beat: String, vocal: String, accelerator: AutomixAccelerator?) async -> Bool {
        let ready = configureAnalyzer(beatModelPath: beat, vocalModelPath: vocal)
        guard ready, !beat.isEmpty, let accelerator else {
            release()
            return ready
        }
        if registered?.identity == accelerator.identity { return ready }
        release()
        if let model = BeatThisCoreML(modelURL: accelerator.modelURL) {
            register(model, identity: accelerator.identity)
            return ready
        }
        // A compiled model an OS update invalidated: rebuild once from the
        // verified archive, then give up and leave the analysis on rten. The
        // rebuild itself runs off the main actor inside the store.
        let rebuilt = await AutomixModelStore.shared.recompileBeatCoreML()
        if let rebuilt, let model = BeatThisCoreML(modelURL: rebuilt.modelURL) {
            register(model, identity: rebuilt.identity)
        } else {
            release()
        }
        return ready
    }

    private func register(_ model: BeatThisCoreML, identity: String) {
        setBeatAccelerator(accelerator: model, identity: identity)
        registered = (identity, model)
    }

    private func release() {
        guard registered != nil else {
            setBeatAccelerator(accelerator: nil, identity: "")
            return
        }
        registered = nil
        setBeatAccelerator(accelerator: nil, identity: "")
    }
}
