import SwiftUI
import BitChordShared

/// Bind to the owning Settings screen so the existing persistence path stays authoritative.
struct AudioSettingsPreferences: DynamicProperty {
    @Binding var wifiQuality: String
    @Binding var cellQuality: String
    @Binding var outputPcm: String
    @Binding var matchSourceRate: Bool
    @Binding var bitPerfect: Bool
    @Binding var preferUsbDac: Bool
    @Binding var loudness: Bool
    @Binding var loudnessMode: String
    @Binding var loudnessOffOnSpeaker: Bool
    @Binding var spatial: Bool
    @Binding var dolbyAtmos: Bool
}

struct AudioSettingsPageView: View {
    let page: AudioSettingsPage
    var preferences: AudioSettingsPreferences
    var focus: AudioSettingsItem? = nil
    @Environment(PlaybackController.self) private var controller
    @State private var showingPipeline = false
    @State private var qualityApplyNotice: String?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    ForEach(AudioSettingsItem.allCases.filter { $0.page == page }) { item in
                        itemView(item).id(item)
                    }
                } header: {
                    Text(page.title)
                } footer: {
                    Text(footer)
                }
                if page == .source {
                    Section {
                        itemView(.requested)
                        itemView(.decoded)
                        Button {
                            controller.applySavedQualityToCurrentTrack()
                            qualityApplyNotice = OfflinePlaybackPolicy.isEnabled
                                ? "Turn off Offline Playback before resolving a new stream."
                                : "Applying the saved quality at the current position. Playback intent is preserved."
                        } label: {
                            Label("Apply to Current Track", systemImage: "arrow.clockwise")
                        }
                        .disabled(controller.current == nil || controller.current?.isLocal == true)
                        if let qualityApplyNotice { note(qualityApplyNotice) }
                        PushLink {
                            AudioSettingsPageView(page: .output, preferences: preferences)
                        } label: {
                            Label("View Current Output", systemImage: "hifispeaker")
                        }
                    } header: {
                        Text("Current Track")
                    } footer: {
                        Text("New stream requests use your saved preference. Already loaded or queued audio may keep its current format.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(page.title)
            .onAppear {
                if let focus {
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(focus, anchor: .center)
                    }
                }
            }
            .sheet(isPresented: $showingPipeline) { AudioPipelineSheet() }
        }
    }

    private var metered: Bool { NetworkQuality.shared.metered }
    private var loaded: Bool {
        guard let id = controller.current?.id else { return false }
        return controller.engineLoadedId == id
    }
    private var readout: AudioSettingsReadout { controller.settingsAudioReadout }
    private var footer: String {
        switch page {
        case .source: return String(localized: "Low caps streams at 64 kbps and Medium at 128 kbps. The source must provide a known format within the cap; otherwise a track may be unavailable. Highest Available prefers lossless and Hi-Res when supplied, with fallback to available audio. Downloads have their own quality setting.")
        case .processing: return "Preferences stay saved when an effect cannot run. The status under each option describes the current audio path. Playback speed and transitions remain under Playback."
        case .output: return "Decoded source quality and device output are different stages. Bluetooth may compress a lossless source. Unknown values stay unreported until playback measures them."
        case .technical: return "These preferences affect the device output, not the quality supplied by an addon. The operating system and connected hardware determine which formats are available."
        }
    }

    @ViewBuilder private func itemView(_ item: AudioSettingsItem) -> some View {
        switch item {
        case .sources:
            PushLink { SourcesView() } label: {
                SettingsLine(glyph: .sources, title: item.title, subtitle: "Where audio comes from, and in what order") { EmptyView() }
            }
        case .wifi:
            qualityPicker(item.title, selection: preferences.$wifiQuality, inUse: !metered)
        case .cellular:
            qualityPicker(item.title, selection: preferences.$cellQuality, inUse: metered)
        case .soundMode:
            VStack(alignment: .leading, spacing: 6) {
                Picker(item.title, selection: Binding(get: { controller.soundMode }, set: { controller.updateSoundMode($0) })) {
                    Text("Transparent").tag("TRANSPARENT")
                    Text("Enhanced").tag("ENHANCED")
                }
                .disabled(readout.processingBypass != nil)
                note(readout.processingBypass ?? (controller.soundMode == "TRANSPARENT"
                     ? "Transparent preserves the recording. Normalization, speed and transitions retain their own preferences."
                     : readout.stageStatus("Enhanced clarity (4× exciter)")))
            }
        case .clarityPreset:
            VStack(alignment: .leading, spacing: 6) {
                Picker(item.title, selection: Binding(get: { controller.clarityPreset }, set: { controller.updateClarity(preset: $0) })) {
                    Text("Reference").tag("REFERENCE")
                    Text("Speaker").tag("SPEAKER")
                    Text("Headphone").tag("HEADPHONE")
                    Text("DAC").tag("DAC")
                }.disabled(clarityUnavailable != nil)
                note(clarityUnavailable ?? readout.stageStatus("Enhanced clarity (4× exciter)"))
            }
        case .clarityMix:
            VStack(alignment: .leading, spacing: 6) {
                Text("Clarity Mix · \(Int(controller.clarityWet * 100))%")
                Slider(value: Binding(get: { controller.clarityWet }, set: { controller.updateClarity(wet: $0) }), in: 0...1)
                    .disabled(clarityUnavailable != nil)
                    .accessibilityLabel("Clarity Mix")
                note(clarityUnavailable ?? (controller.clarityWet == 0 ? "Inactive · mix is set to zero." : readout.stageStatus("Enhanced clarity (4× exciter)")))
            }
        case .normalization:
            VStack(alignment: .leading, spacing: 6) {
                SettingsToggleLine(glyph: .loudness, title: item.title, subtitle: "Levels tracks to a consistent loudness", isOn: preferences.$loudness)
                    .disabled(readout.processingBypass != nil)
                Picker("Normalization Mode", selection: preferences.$loudnessMode) {
                    Text("Track").tag("TRACK")
                    Text("Album").tag("ALBUM")
                }.pickerStyle(.segmented)
                    .disabled(!preferences.loudness || readout.processingBypass != nil)
                #if os(iOS)
                SettingsSubToggle(title: "Off on iPhone Speaker", isOn: preferences.$loudnessOffOnSpeaker)
                #endif
                note(normalizationStatus)
            }
        case .spatial:
            VStack(alignment: .leading, spacing: 6) {
                SettingsToggleLine(glyph: .spatial, title: item.title, subtitle: "Stereo widening and head tracking", isOn: preferences.$spatial)
                    .disabled(spatialUnavailable != nil)
                note(spatialUnavailable ?? (preferences.spatial ? readout.stageStatus("Spatial / head tracking") : "Off · preference is disabled."))
                note("Apple’s Spatial Audio, Headphone Accommodations and Adaptive Audio are managed in system settings.")
            }
        case .equalizer:
            VStack(alignment: .leading, spacing: 6) {
                PushLink { EqualizerView() } label: {
                    SettingsLine(glyph: .equalizer, title: item.title, subtitle: "Ten-band EQ and tone controls") { EmptyView() }
                }
                note(readout.processingBypass ?? (controller.soundMode == "TRANSPARENT" ? "Inactive in Transparent mode · choose Enhanced to hear your EQ settings." : readout.stageStatus("Manual EQ / tone")))
            }
        case .dolby:
            VStack(alignment: .leading, spacing: 6) {
                SettingsToggleLine(glyph: .dolby, title: item.title, subtitle: "Prefer supported Dolby audio when a source supplies it", isOn: preferences.$dolbyAtmos)
                    .disabled(!AppleDolbyRenderer.available)
                note(dolbyStatus)
            }
        case .requested:
            VStack(alignment: .leading, spacing: 6) {
                valueRow(item.title, "\(AudioQualityOption.label(metered ? preferences.cellQuality : preferences.wifiQuality, in: AudioQualityOption.stream)) · \(metered ? "Mobile Data" : "Wi-Fi")")
                if controller.current?.isLocal == true || controller.current.flatMap({ controller.resolvedOrigin[$0.id] }) == .local {
                    note("This track is a local file or saved download. Streaming quality does not change its stored format.")
                }
            }
        case .decoded:
            VStack(alignment: .leading, spacing: 6) {
                valueRow("Actual Source", loaded ? controller.playbackSourceName ?? "Not reported" : "Not loaded")
                valueRow(item.title, decodedFormat)
                if loaded, let id = controller.current?.id, let decision = controller.sourceDecisionNotes[id] { note(decision) }
            }
        case .device:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    valueRow(item.title, AudioRouteState.shared.name)
                    valueRow("Actual PCM Output", outputFormat)
                    if !AudioRouteState.shared.carriesLossless {
                        note("Bluetooth compresses the device output. The source can still be FLAC or another lossless format.")
                    }
                }
            }
        case .activeProcessing:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                valueRow(item.title, processingStatus)
            }
        case .pipeline:
            Button { showingPipeline = true } label: {
                SettingsLine(glyph: .nerd, title: item.title, subtitle: "Detailed measurements and source decisions") { EmptyView() }
            }.buttonStyle(.plain)
        case .technical:
            PushLink { AudioSettingsPageView(page: .technical, preferences: preferences) } label: {
                SettingsLine(glyph: .precision, title: item.title, subtitle: AudioSettingsPage.technical.detail) { EmptyView() }
            }
        case .pcm:
            VStack(alignment: .leading, spacing: 6) {
                Picker(item.title, selection: preferences.$outputPcm) {
                    #if os(macOS)
                    Text("PCM 16").tag("PCM_16")
                    #endif
                    Text("Float 32").tag("FLOAT_32")
                }.pickerStyle(.segmented)
                .disabled(outputPrecisionIsFixed)
                #if os(iOS)
                note("iPhone and iPad use Float 32 for CoreAudio. PCM 16 is not selectable on iOS.")
                #else
                note("Requested \(AudioSettingsReadout.pcmLabel(preferences.outputPcm)). This does not add detail to the source recording.")
                #endif
                note("Actual output: \(outputFormat)")
            }
        case .sampleRate:
            VStack(alignment: .leading, spacing: 6) {
                SettingsToggleLine(glyph: .precision, title: item.title, subtitle: "Request each track’s native rate from the output route", isOn: preferences.$matchSourceRate)
                note(readout.sampleRateStatus(requested: preferences.matchSourceRate))
            }
        case .bitPerfect:
            #if os(macOS)
            VStack(alignment: .leading, spacing: 6) {
                SettingsToggleLine(glyph: .precision, title: item.title, subtitle: "Request exclusive output for supported lossless stereo", isOn: preferences.$bitPerfect)
                note(readout.bitPerfectStatus(requested: preferences.bitPerfect))
            }
            #else
            valueRow(item.title, "Unavailable on iOS · exclusive integer PCM output is supported on Mac only.")
            #endif
        case .usb:
            VStack(alignment: .leading, spacing: 6) {
                SettingsToggleLine(glyph: .precision, title: item.title, subtitle: "Prefer a supported USB device when opening audio output", isOn: preferences.$preferUsbDac)
                note(AudioRouteState.shared.kind.lowercased().contains("usb") ? "USB is the current route." : "No USB route is currently in use. This preference does not connect or unlock a DAC.")
            }
        }
    }

    private var dolbyStatus: String {
        guard AppleDolbyRenderer.available else { return "Unavailable · this system does not support the Apple Dolby renderer." }
        if controller.dolbyRenderer != nil { return "Active · this track uses Apple’s Dolby renderer." }
        return preferences.dolbyAtmos ? "Requested · the current track is not using Apple’s Dolby renderer." : "Off · preference is disabled."
    }
    private var processingStatus: String {
        if let bypass = readout.processingBypass { return bypass }
        guard loaded else { return "Play a track to inspect processing." }
        return readout.activeStages.isEmpty ? "No processing stages reported." : readout.activeStages.joined(separator: " · ")
    }
    private var outputPrecisionIsFixed: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
    private var clarityUnavailable: String? {
        readout.processingBypass ?? (controller.soundMode == "TRANSPARENT" ? "Inactive in Transparent mode · choose Enhanced to use Clarity." : nil)
    }
    private var spatialUnavailable: String? {
        if let reason = readout.processingBypass { return reason }
        if AudioRouteState.shared.monoAudioEnabled { return "Inactive while system Mono Audio is enabled." }
        if AudioRouteState.shared.systemSpatialEnabled == true { return "Inactive while Apple’s Spatial Audio is enabled, to avoid processing twice." }
        if controller.soundMode == "TRANSPARENT" { return "Inactive in Transparent mode · choose Enhanced to use this effect." }
        return nil
    }
    private var normalizationStatus: String {
        if let reason = readout.processingBypass { return reason }
        guard preferences.loudness else { return "Off · choose Track or Album after enabling normalization." }
        #if os(iOS)
        if preferences.loudnessOffOnSpeaker && AudioRouteState.shared.kind == "Speaker" {
            return "Requested \(preferences.loudnessMode.capitalized) · inactive on the iPhone speaker because Off on iPhone Speaker is enabled."
        }
        #endif
        return "Requested \(preferences.loudnessMode.capitalized) · \(readout.stageStatus("Normalization"))"
    }
    private var decodedFormat: String {
        guard loaded else { return "Play a track to measure its format." }
        if controller.dolbyRenderer != nil { return "Apple Dolby renderer · PCM decoder measurements do not apply." }
        guard let stats = controller.nerd else { return "Waiting for decoder measurements." }
        var values: [String] = []
        if !stats.codec.isEmpty { values.append(stats.codec) }
        if stats.kbps > 0 { values.append("\(stats.kbps) kbps") }
        if stats.bitDepth > 0 { values.append("\(stats.bitDepth)-bit") }
        if stats.sampleRate > 0 { values.append("\(stats.sampleRate) Hz") }
        if stats.channels > 0 { values.append("\(stats.channels) ch") }
        return values.isEmpty ? "Not reported" : values.joined(separator: " · ")
    }
    private var outputFormat: String {
        guard loaded else { return "Not open for the selected track." }
        if controller.dolbyRenderer != nil { return "Managed by Apple’s renderer; native PCM format is not reported." }
        let device = controller.outputDevice
        guard device.started else { return "Waiting for output." }
        return "\(AudioSettingsReadout.pcmLabel(device.sampleFormat)) · \(device.sampleRate) Hz · \(device.channels) ch"
    }
    private func qualityPicker(_ title: String, selection: Binding<String>, inUse: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: selection) {
                ForEach(AudioQualityOption.stream) { option in Text(option.title).tag(option.id) }
            }
            note("\(inUse ? "In use on this connection" : "Saved for this connection") · \(AudioQualityOption.stream.first { $0.id == selection.wrappedValue }?.detail ?? selection.wrappedValue)")
        }
    }
    private func valueRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor extension PlaybackController {
    var settingsAudioReadout: AudioSettingsReadout {
        let loaded = current != nil && current?.id == engineLoadedId
        let device = outputDevice
        return AudioSettingsReadout(loaded: loaded, appleRenderer: dolbyRenderer != nil,
            outputStarted: device.started, sourceRate: loaded ? nerd?.sampleRate ?? 0 : 0,
            outputRate: device.sampleRate, outputFormat: device.sampleFormat,
            bitPerfectActive: device.bitPerfectActive, bitPerfectReason: device.bitPerfectReason,
            activeStages: loaded ? nerd?.activeStages ?? [] : [])
    }
}
