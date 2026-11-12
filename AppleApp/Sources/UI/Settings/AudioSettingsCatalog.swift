import Foundation

enum AudioSettingsPage: String, CaseIterable, Identifiable {
    case source, processing, output, technical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: return "Source Quality"
        case .processing: return "Sound Processing"
        case .output: return "Current Output"
        case .technical: return "Technical Audio & DAC"
        }
    }
    var detail: String {
        switch self {
        case .source: return "Sources and the quality requested on Wi-Fi and mobile data"
        case .processing: return "Sound mode, normalization, equalizer and spatial effects"
        case .output: return "The decoded track, output route and processing actually in use"
        case .technical: return "PCM precision, sample-rate matching and exclusive output"
        }
    }
}

/// One catalogue drives navigation and row-level search, including nested pages.
enum AudioSettingsItem: String, CaseIterable, Identifiable {
    case sources, wifi, cellular, soundMode, clarityPreset, clarityMix, normalization
    case spatial, equalizer, dolby, requested, decoded, device, activeProcessing, pipeline, technical
    case pcm, sampleRate, bitPerfect, usb
    var id: String { rawValue }
    var page: AudioSettingsPage {
        switch self {
        case .sources, .wifi, .cellular: return .source
        case .soundMode, .clarityPreset, .clarityMix, .normalization, .spatial, .equalizer, .dolby: return .processing
        case .requested, .decoded, .device, .activeProcessing, .pipeline, .technical: return .output
        case .pcm, .sampleRate, .bitPerfect, .usb: return .technical
        }
    }
    var title: String {
        switch self {
        case .sources: return "Sources"
        case .wifi: return "On Wi-Fi"
        case .cellular: return "On Mobile Data"
        case .soundMode: return "Sound Mode"
        case .clarityPreset: return "Clarity Preset"
        case .clarityMix: return "Clarity Mix"
        case .normalization: return "Loudness Normalization"
        case .spatial: return "BitChord spatial effect"
        case .equalizer: return "Equalizer"
        case .dolby: return "Dolby Atmos"
        case .requested: return "Requested Quality"
        case .decoded: return "Decoded Audio"
        case .device: return "Output Device"
        case .activeProcessing: return "Active Processing"
        case .pipeline: return "Audio Pipeline"
        case .technical: return AudioSettingsPage.technical.title
        case .pcm: return "Output Precision"
        case .sampleRate: return "Match Source Sample Rate"
        case .bitPerfect: return "Bit-perfect Output"
        case .usb: return "Prefer USB DAC"
        }
    }
    var keywords: [String] {
        switch self {
        case .sources: return ["addons", "server", "source order", "priority", "refresh", "webdav", "smb", "nas", "jiosaavn"]
        case .wifi: return ["wifi", "wi-fi", "lossless", "flac", "hi-res", "streaming", "bitrate", "unmetered", "highest", "best", "preferred quality", "data saver"]
        case .cellular: return ["mobile data", "cellular", "lossless", "flac", "streaming", "bitrate", "metered", "highest", "best", "preferred quality", "data saver"]
        case .soundMode: return ["transparent", "enhanced", "dsp", "clarity"]
        case .clarityPreset: return ["reference", "speaker", "headphone", "dac", "enhanced"]
        case .clarityMix: return ["wet", "tone", "enhanced"]
        case .normalization: return ["loudness", "track", "album", "off on iphone speaker", "normalize"]
        case .spatial: return ["head tracking", "widening", "airpods", "mono", "spatial audio"]
        case .equalizer: return ["eq", "bands", "bass", "treble", "tone"]
        case .dolby: return ["atmos", "surround", "immersive", "renderer"]
        case .requested: return ["quality", "requested", "wifi", "mobile data", "lossless"]
        case .decoded: return ["actual", "format", "codec", "bitrate", "sample rate", "flac", "opus"]
        case .device: return ["bluetooth", "airpods", "speaker", "wired", "usb", "output", "dac"]
        case .activeProcessing: return ["dsp", "active", "bypass", "normalization", "effects"]
        case .pipeline: return ["diagnostics", "measured", "format", "quality", "decoder"]
        case .technical: return ["pcm", "dac", "precision", "exclusive", "bit perfect"]
        case .pcm: return ["pcm 16", "float 32", "bit depth", "precision", "output"]
        case .sampleRate: return ["rate", "clock", "hz", "route", "dac"]
        case .bitPerfect: return ["bit perfect", "exclusive", "hog", "lossless", "bypass", "dac"]
        case .usb: return ["usb", "dac", "headphone", "route", "output"]
        }
    }
}

/// Presentation never infers a measured result from a stored preference.
struct AudioSettingsReadout {
    var loaded = false
    var appleRenderer = false
    var outputStarted = false
    var sourceRate: UInt32 = 0
    var outputRate: UInt32 = 0
    var outputFormat = ""
    var bitPerfectActive = false
    var bitPerfectReason = ""
    var activeStages: [String] = []

    var processingBypass: String? {
        if appleRenderer { return "Apple’s Dolby renderer handles this track; BitChord’s PCM effects are bypassed." }
        if loaded && outputStarted && bitPerfectActive { return "Exclusive bit-perfect output bypasses BitChord’s volume, effects and transitions." }
        return nil
    }
    func bitPerfectStatus(requested: Bool) -> String {
        guard loaded else { return "Play a track to check exclusive output." }
        if appleRenderer { return "Inactive · Apple’s Dolby renderer is in use." }
        guard outputStarted else { return "Waiting for the output device." }
        if bitPerfectActive { return "Active · exclusive integer PCM confirmed by CoreAudio." }
        guard requested else { return "Off · standard CoreAudio output." }
        if !bitPerfectReason.isEmpty && bitPerfectReason != "Bit-perfect output is off" { return "Inactive · \(bitPerfectReason)" }
        return "Inactive · requires a supported lossless stereo track and a direct output that grants exclusive access."
    }
    func sampleRateStatus(requested: Bool) -> String {
        guard loaded && !appleRenderer && outputStarted && sourceRate > 0 && outputRate > 0 else {
            return "The actual rate is shown when native PCM playback opens the output."
        }
        if sourceRate == outputRate { return "Currently matched · \(outputRate) Hz. The system may also choose this rate automatically." }
        let conversion = "\(sourceRate) → \(outputRate) Hz"
        return requested ? "Requested native rate; current output is \(conversion). The route may keep a fixed rate." : "Currently resampling · \(conversion)."
    }
    func stageStatus(_ stage: String) -> String {
        if let processingBypass { return processingBypass }
        guard loaded else { return "Stored preference · play a track to check its effect." }
        return activeStages.contains(stage) ? "Active in the current audio path." : "Not active in the current audio path."
    }
    static func pcmLabel(_ mode: String) -> String {
        switch mode {
        case "FLOAT_32": return "Float 32"
        case "PCM_16": return "PCM 16"
        case "PCM_24": return "PCM 24"
        case "": return "Not reported"
        default: return "Unknown format (\(mode))"
        }
    }
}
