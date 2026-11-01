import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Playback: crossfade, AutoMix and its models, and the rest of playback.
extension SettingsView {
    func buildPlaybackRows(_ rows: inout SettingsRows) {
        rows.row("Crossfade", "blend", "fade", "transition", "gapless", "automix") {
            VStack(alignment: .leading, spacing: 6) {
                SettingsSliderRow(glyph: .crossfade, title: "Crossfade",
                    subtitle: automix ? "Inactive while Automix controls transition timing" : "Blends one track into the next; 0s keeps gapless playback",
                    valueText: crossfade == 0 ? "Off" : "\(crossfade)s",
                    value: Binding(get: { Double(crossfade) }, set: { crossfade = Int($0.rounded()) }),
                    range: 0...12, step: 1)
                    .disabled(automix || controller.settingsAudioReadout.processingBypass != nil)
                if let reason = controller.settingsAudioReadout.processingBypass {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        rows.row("Automix", "blend", "transition", "beat", "model", "timing", "crossfade", "overheating", "lag") {
            SettingsToggleLine(
                glyph: .automix,
                title: "Automix [Beta]",
                subtitle: automixSubtitle,
                isOn: $automix
            )
        }
        rows.row("Phrase Length", "automix", "phrase", "bars", "adaptive", "8 bars", "16 bars") {
            Picker("Phrase Length", selection: Binding(
                get: { controller.automixPhraseBars },
                set: { controller.setAutomixPhraseBars($0) }
            )) {
                Text("Adaptive").tag(0)
                Text("8 bars").tag(8)
                Text("16 bars").tag(16)
            }
            .disabled(!automix)
            .accessibilityHint(automix ? "Choose the phrase length for AutoMix effects" : "Enable Automix to use phrase timing")
            if !automix { Text("Inactive · enable Automix to use phrase timing.").font(.footnote).foregroundStyle(.secondary) }
        }
        rows.row("Smart Sequencing", "sequence", "order", "suggestions", "autoplay", "transition", "shuffle") {
            SettingsToggleLine(
                glyph: .automix,
                title: "Smart Sequencing",
                subtitle: automix ? "Order upcoming tracks for smooth transitions. Takes priority over Shuffle; manually queued tracks keep their order." : "Inactive · enable Automix to use Smart Sequencing.",
                isOn: $automixSequence
            ).disabled(!automix)
        }
        rows.row("Mix on Skip", "skip", "next", "transition", "echo", "beat") {
            SettingsToggleLine(
                glyph: .automix,
                title: "Mix on Skip",
                subtitle: automix ? "Pressing Next blends into the next track. Inactive during a party and on Repeat One." : "Inactive · enable Automix to blend on Next.",
                isOn: Binding(
                    get: { controller.automixOnSkipEnabled },
                    set: { controller.setAutomixOnSkipEnabled($0) }
                )
            ).disabled(!automix)
        }
        rows.row("Show Music Videos", "video", "music video", "clip", "picture", "avc", "mv") {
            SettingsToggleLine(
                glyph: .video,
                title: "Show Music Videos",
                subtitle: "Shows the music video while the player is open. Off at the start of every session; the Now Playing pill turns it on too.",
                isOn: $showMusicVideos
            )
        }
        rows.row("Play Music Videos over Cellular", "video", "cellular", "mobile data") {
            SettingsSubToggle(title: "Play Music Videos over Cellular", isOn: $videoOverCellular).disabled(!showMusicVideos)
            if !showMusicVideos { Text("Inactive · Show Music Videos is off.").font(.footnote).foregroundStyle(.secondary) }
        }
        rows.row("Trim Leading and Trailing Silence", "silence", "trim", "edges", "gap") {
            Toggle("Trim Leading and Trailing Silence", isOn: $trimEdges)
                .onChange(of: trimEdges) { _, value in
                    PlatformSettings.shared.putBoolean(key: "trim_edge_silence", value: value)
                    controller.refreshPlaybackRegions()
                }
        }
        rows.row("Skip Non-Music Segments", "non-music", "segments", "skit", "intro", "podcast") {
            Toggle("Skip Non-Music Segments", isOn: $skipNonMusic)
                .onChange(of: skipNonMusic) { _, value in
                    PlatformSettings.shared.putBoolean(key: "skip_non_music", value: value)
                    controller.refreshPlaybackRegions()
                }
        }
        rows.row("Non-music Segments", "automix", "boundaries", "segments") {
            Text("Non-music segments and audible boundaries are always used by Automix.")
                .font(.caption).foregroundStyle(.secondary)
        }
        rows.row("Diagnostic Reports", "debug", "log", "report", "diagnostics") {
            PushLink("Diagnostic Reports") { DiagnosticReportsView() }
        }
        rows.row("Skip Silence", "silence", "gaps", "trim") {
            SettingsToggleLine(
                glyph: .skipSilence,
                title: "Skip Silence",
                subtitle: controller.soundMode == "TRANSPARENT" ? "Inactive in Transparent mode · choose Enhanced to skip silence" : controller.settingsAudioReadout.processingBypass ?? "Trim gaps longer than a second",
                isOn: $skipSilence
            )
        }
        rows.row("Playback Speed", "speed", "tempo", "rate", "pitch", "slow", "fast") {
            SettingsSliderRow(
                glyph: .speed,
                title: "Playback Speed",
                subtitle: "Slows or speeds the mix without changing pitch on the engine",
                valueText: String(format: "%.2fx", playbackSpeed),
                value: $playbackSpeed,
                range: 0.5...2.0,
                step: 0.05
            )
        }
#if os(iOS)
        rows.row("Play Alongside Other Apps", "mix", "other apps", "background audio", "interrupt") {
            SettingsToggleLine(
                glyph: .musicOnly,
                title: "Play Alongside Other Apps",
                subtitle: "Keep other apps audible alongside BitChord. This can prevent iOS Lock Screen, Control Center and headphone controls from controlling BitChord. Turn off to give BitChord audio priority. Applies immediately while playing, or on the next play.",
                isOn: Binding(
                    get: { controller.mixWithOtherAudio },
                    set: { controller.setMixWithOtherAudio($0) }
                )
            )
        }
#endif
        rows.row("Show Stats for Nerds", "nerds", "stats", "codec", "bitrate", "sample rate") {
            SettingsToggleLine(
                glyph: .nerd,
                title: "Show Stats for Nerds",
                subtitle: "Codec, bitrate and sample rate on the player",
                isOn: $nerdStats
            )
        }
        rows.row("Stop Converting Video Songs to Audio", "video", "music video", "convert", "audio") {
            SettingsToggleLine(
                glyph: .video,
                title: "Stop Converting Video Songs to Audio",
                subtitle: "Plays a music-video upload as itself instead of swapping it for its catalogue audio release",
                isOn: Binding(
                    get: { !convertVideo },
                    set: { convertVideo = !$0 }
                )
            )
        }
        rows.row("Prefer Music Only", "music video", "video", "catalogue", "upload") {
            SettingsToggleLine(
                glyph: .musicOnly,
                title: "Prefer Music Only",
                subtitle: "Starts a music-video result on its catalogue audio release instead of the video's own upload",
                isOn: $preferMusicOnly
            )
        }
    }

    private var automixSubtitle: String {
        if let bypass = controller.settingsAudioReadout.processingBypass { return "Requested transition settings are inactive · " + bypass }
        guard automix else { return "Times and blends transitions automatically when enabled." }
        if AutomixModelStore.shared.beatAvailable { return "Blends transitions automatically from each track’s timing." }
        return "Uses tempo analysis while the beat model is missing. Install it under Advanced Options → Automix Models for beat-aligned transitions."
    }

    func buildAutomixAdvancedRows(_ rows: inout SettingsRows) {
        rows.row("Automix Performance", "cpu", "threads", "analysis", "budget", "efficient", "balanced", "performance", "battery") {
            PushLink {
                AutomixPerformancePage(selection: $automixPerf)
            } label: {
                SettingsLine(
                    glyph: .cpu,
                    title: "Automix Performance",
                    subtitle: "CPU inference budget — up to \(controller.automixInferenceThreads) worker\(controller.automixInferenceThreads == 1 ? "" : "s")"
                ) {
                    Text(Self.automixPerfLabel(automixPerf))
                        .foregroundStyle(.secondary)
                }
            }
        }
        rows.row("Automix Models", "models", "model", "onnx", "beat", "downbeat", "vocal", "install", "download models") {
            PushLink {
                AutomixModelsPage()
            } label: {
                SettingsLine(
                    glyph: .models,
                    title: "Automix Models",
                    subtitle: Self.automixModelsSubtitle
                ) {
                    EmptyView()
                }
            }
        }
    }

    private static func automixPerfLabel(_ mode: String) -> String {
        switch mode {
        case "EFFICIENT": return "Efficient"
        case "PERFORMANCE": return "Performance"
        default: return "Balanced"
        }
    }

    /// What the Automix Models row says without opening it.
    ///
    /// State rather than instruction: "Not installed" is the fact, and the row's
    /// destination is where the action is — a subtitle that also shouts "tap here"
    /// is a settings row pretending to be a button.
    private static var automixModelsSubtitle: String {
        let store = AutomixModelStore.shared
        // A verified previous graph is still a working model: say so, and say that
        // an update is waiting, rather than calling the pair "not installed".
        if store.isUsingPreviousGraph(.beat) || store.isUsingPreviousGraph(.beatCoreML) || store.isUsingPreviousGraph(.vocals) {
            return "Update available. Using the previous version — \(AutomixModelStore.bytes(store.totalBytesOnDisk)) on disk"
        }
        let beat = store.status(of: .beat).isInstalled
        let vocals = store.status(of: .vocals).isInstalled
        let accelerated = store.status(of: .beatCoreML).isInstalled
        switch (beat, vocals) {
        case (true, true):
            if accelerated {
                return "Beat, downbeat and vocal models installed, accelerated by Core ML — \(AutomixModelStore.bytes(store.totalBytesOnDisk)) on disk"
            }
            return "Beat, downbeat and vocal models installed — \(AutomixModelStore.bytes(store.totalBytesOnDisk)) on disk"
        case (true, false):
            if accelerated {
                return "Beat model installed with Core ML acceleration; vocal detection can be added for vocal-clash avoidance"
            }
            return "Beat model installed; vocal detection can be added for vocal-clash avoidance"
        case (false, true):
            return "Vocal model installed — without the beat model Automix falls back to tempo analysis"
        case (false, false):
            return "Not installed — Automix falls back to tempo analysis"
        }
    }

    // MARK: - Appearance
}
