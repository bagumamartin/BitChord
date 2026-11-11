import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Appearance and performance.
extension SettingsView {
    func buildAppearanceRows(_ rows: inout SettingsRows) {
        rows.row("Appearance", "theme", "dark mode", "light mode", "colour", "color", "system", "accent", "tint") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsLine(glyph: .theme, title: "Appearance") { EmptyView() }
                Picker("Appearance", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.leading, 41)
            }
            .padding(.vertical, 4)
        }
        rows.row("Reduce Animation", "reduce motion", "animation", "gradient", "drift") {
            SettingsToggleLine(
                glyph: .reduceMotion,
                title: "Reduce Animation",
                subtitle: "Freezes the main player's gradient instead of drifting",
                isOn: $reduceAnimation
            )
        }
        rows.row("Reduce Dynamic Blur", "reduce transparency", "dynamic blur", "blur", "glass", "frosted",
                 "transparency", "contrast") {
            SettingsToggleLine(
                glyph: .reduceBlur,
                title: "Reduce Dynamic Blur",
                subtitle: "Swaps frosted glass for solid fills across the app",
                isOn: $reduceBlur
            )
        }
        rows.row("Full-Screen Cover Art", "artwork", "full bleed", "cover", "sleeve", "art") {
            SettingsToggleLine(
                glyph: .fullBleed,
                title: "Full-Screen Cover Art",
                subtitle: "Runs the cover to the edges of the player instead of a square sleeve",
                isOn: $fullBleed
            )
        }
        rows.row("Legacy Mesh Gradient", "mesh", "gradient", "backdrop", "wash", "background") {
            SettingsToggleLine(
                glyph: .mesh,
                title: "Legacy Mesh Gradient",
                subtitle: "The single-wash backdrop instead of colours sampled from the artwork",
                isOn: $legacyMesh
            )
        }
        rows.row("Animated Cover Art", "canvas", "animated", "cover art", "video", "motion") {
            SettingsToggleLine(
                glyph: .canvas,
                title: "Animated Cover Art",
                subtitle: "Plays the looping video some releases ship instead of a still sleeve",
                isOn: $canvas
            )
        }
        if canvas {
            rows.row("Play Animated Cover over Cellular", "canvas", "cellular", "mobile data", "animated") {
                SettingsSubToggle(title: "Play Animated Cover over Cellular", isOn: $canvasCellular)
            }
        }
        rows.row("Artist Signatures", "artist", "signature", "wikimedia", "commons", "url", "logo") {
            VStack(alignment: .leading, spacing: 8) {
                SettingsToggleLine(
                    glyph: .theme,
                    title: "Artist Signatures",
                    subtitle: "Show Wikimedia artist signatures on artist pages",
                    isOn: Binding(
                        get: { artistSignatures },
                        set: { value in
                            artistSignatures = value
                            AppSettings.shared.setArtistSignaturesEnabled(value: value)
                        }
                    )
                )
                if artistSignatures {
                    TextField("Wikimedia URL (optional)", text: Binding(
                        get: { artistSignaturesWikimediaUrl },
                        set: { value in
                            artistSignaturesWikimediaUrl = value
                            AppSettings.shared.setArtistSignaturesWikimediaUrl(value: value)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    Text("Leave blank to use Wikimedia Commons by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 41)
                }
            }
        }
        rows.row("Synced Lyrics", "lyrics", "synced", "karaoke", "words") {
            SettingsToggleLine(
                glyph: .lyrics,
                title: "Synced Lyrics",
                subtitle: "Lights up the words on the player as they’re sung",
                isOn: $syncedLyrics
            )
        }
        rows.row("Lyrics on Player", "lyrics", "inline", "player", "line", "hide") {
            SettingsToggleLine(
                glyph: .lyrics,
                title: "Lyrics on Player",
                subtitle: "Shows the line being sung under the song title",
                isOn: $playerLyricLine
            )
        }
        if syncedLyrics {
            rows.row("Blur Unfocused Lyrics", "blur", "lyrics", "focus") {
                SettingsToggleLine(glyph: .reduceBlur, title: "Blur Unfocused Lyrics",
                                   subtitle: "Softens lines away from the words being sung", isOn: $lyricsBlur)
            }
            rows.row("Translation Language", "translation", "language", "romanize", "lyrics") {
                PushLink {
                    TranslationPreferenceView(selection: $translationLanguage, translator: controller.lyricsTranslator)
                } label: {
                    SettingsLine(glyph: .lyricsSources, title: "Translation Language",
                                 subtitle: translationLanguage.isEmpty ? "Follow the app language" : (Locale.current.localizedString(forIdentifier: translationLanguage) ?? translationLanguage)) { EmptyView() }
                }
            }
            rows.row("Prefer Word-Synced Lyrics", "syllable", "word", "synced", "lyrics", "timing") {
                SettingsToggleLine(
                    glyph: .lyrics,
                    title: "Prefer Word-Synced Lyrics",
                    subtitle: "Syllable timings win the lyrics race when a source has them",
                    isOn: $syllableSync
                )
            }
            rows.row("Lyrics Sources", "lyrics", "sources", "provider", "paxsenix", "api key", "lrc", "translation") {
                PushLink {
                    LyricsSourcesView(selection: $lyricsSources, order: $lyricsSourceOrder, syllableSync: $syllableSync)
                } label: {
                    SettingsLine(
                        glyph: .lyricsSources,
                        title: "Lyrics Sources",
                        subtitle: LyricsSourceOption.summary(lyricsSources)
                    ) {
                        EmptyView()
                    }
                }
            }
        }
        #if os(macOS)
        rows.row("Show Player in Menu Bar", "menu bar", "player", "status bar", "extra") {
            Toggle("Show Player in Menu Bar", isOn: $menuBarPlayer)
        }
        #endif
    }

    // MARK: - Performance

    func buildPerformanceRows(_ rows: inout SettingsRows) {
        rows.row("High Performance Mode", "performance", "refresh rate", "hz", "promotion", "battery", "smooth") {
            Toggle(isOn: Binding(
                get: { highPerf },
                set: { enabled in
                    // Turning it on is the consequential direction — a sustained
                    // high refresh rate costs real battery — so that way goes
                    // through the warning first. Turning it off just stops.
                    if enabled { showPerfWarning = true } else { highPerf = false }
                }
            )) {
                SettingsLine(
                    glyph: .performance,
                    title: "High Performance Mode",
                    subtitle: highPerf
                        ? "Holding \(refreshRate) Hz"
                        : "Requests a sustained high refresh rate"
                ) {
                    EmptyView()
                }
            }
            .padding(.vertical, 2)
        }
        if highPerf {
            rows.row("Refresh Rate", "frame rate", "hz", "display", "performance") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsLine(glyph: .refreshRate, title: "Refresh Rate") { EmptyView() }
                    Picker("Refresh Rate", selection: $refreshRate) {
                        ForEach(PerformanceTuner.supportedRates, id: \.self) { rate in
                            Text("\(rate) Hz").tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.leading, 41)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Local music
}
