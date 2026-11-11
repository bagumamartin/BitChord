import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Apple Settings-style grouped form. Structure and copy follow upstream;
/// settings appear directly in one grouped form, with drill-downs for dedicated screens.
struct SettingsView: View {
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) var controller
    @Environment(AuthController.self) var auth
    @Environment(AppModel.self) var appModel

    @State var crossfade = Int(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
    @AppStorage("dolby_atmos") var dolbyAtmos = true
    #if os(macOS)
    @AppStorage("menu_bar_player") var menuBarPlayer = true
    @AppStorage("mac_single_click_play") var singleClickToPlay = true
    #endif
    @State var spatial = PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false)
    @State var automix = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: true)
    @State var automixSequence = PlatformSettings.shared.getBoolean(key: "automix_smart_sequence", default: true)
    @State var trimEdges = PlatformSettings.shared.getBoolean(key: "trim_edge_silence", default: false)
    @State var skipNonMusic = PlatformSettings.shared.getBoolean(key: "skip_non_music", default: false)
    @State var skipSilence = PlatformSettings.shared.getBoolean(key: "skip_silence", default: false)
    @State var wifiQuality = PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "LOSSLESS")
    @State var cellQuality = PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "LOSSLESS")
    @State var downloadQuality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
    @State var wifiOnlyDownloads = PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true)
    @State var nerdStats = PlatformSettings.shared.getBoolean(key: "show_nerd_stats", default: false)
    @State var canvas = PlatformSettings.shared.getBoolean(key: "animated_canvas", default: true)
    @State var canvasCellular = PlatformSettings.shared.getBoolean(key: "canvas_over_cellular", default: false)
    @State var reduceBlur = PlatformSettings.shared.getBoolean(key: "reduce_dynamic_blur", default: false)
    @State var update = UpdateChecker.shared
    @State var reduceAnimation = PlatformSettings.shared.getBoolean(key: "reduce_animation", default: false)
    @State var fullBleed = PlatformSettings.shared.getBoolean(key: "full_bleed_artwork", default: true)
    @AppStorage("lyrics_blur") var lyricsBlur = true
    @AppStorage("player_lyric_line") var playerLyricLine = true
    @AppStorage("show_music_videos") var showMusicVideos = false
    @State var videoOverCellular = PlatformSettings.shared.getBoolean(key: "video_over_cellular", default: false)
    @AppStorage("translation_language") var translationLanguage = ""
    @State var syncedLyrics = PlatformSettings.shared.getBoolean(key: "synced_lyrics", default: true)
    @State var convertVideo = PlatformSettings.shared.getBoolean(key: "convert_video_to_audio", default: true)
    @State var swipeNext = PlatformSettings.shared.getBoolean(key: "swipe_to_play_next", default: false)
    @State var dontRepeat = PlatformSettings.shared.getBoolean(key: "dont_repeat_suggestions", default: false)
    @State var hideVolume = PlatformSettings.shared.getBoolean(key: "hide_volume_bar", default: false)
    @State var hideSongStatus = PlatformSettings.shared.getBoolean(key: "hide_song_status", default: false)
    @State var outputPcm = PlaybackController.migrateOutputPcmMode()
    @State var matchSourceRate = PlatformSettings.shared.getBoolean(key: "match_source_sample_rate", default: true)
    @State var bitPerfect = PlatformSettings.shared.getBoolean(key: "bit_perfect_output", default: false)
    @State var preferUsbDac = PlatformSettings.shared.getBoolean(key: "prefer_usb_dac", default: false)
    @State var loudness = PlaybackController.storedLoudnessMode() != .off
    @State var loudnessModeSelection = PlatformSettings.shared.getString(key: "loudness_mode", default: "TRACK") == "ALBUM" ? "ALBUM" : "TRACK"
    @State var loudnessOffOnSpeaker = PlatformSettings.shared.getBoolean(key: "loudness_off_on_speaker", default: true)
    @State var automixPerf = PlatformSettings.shared.getString(key: "automix_performance", default: "BALANCED")
    @State var highPerf = PlatformSettings.shared.getBoolean(key: "high_performance_mode", default: false)
    @State var refreshRate: Int = Int(PlatformSettings.shared.getInt(key: "performance_refresh_rate", default: 60))
    @State var showPerfWarning = false
    @State var localFolderName: String? = SettingsView.storedLocalFolderName()
    @State var pickingFolder = false
    @State var filterNonMusic = PlatformSettings.shared.getBoolean(key: "filter_non_music_audio", default: true)
    @State var exportDownloads = PlatformSettings.shared.getBoolean(key: "export_downloads", default: false)
    @State var smartAlign = PlatformSettings.shared.getBoolean(key: "smart_version_alignment", default: true)
    @State var legacyMesh = PlatformSettings.shared.getBoolean(key: "legacy_mesh_gradient", default: false)
    @State var preferMusicOnly = PlatformSettings.shared.getBoolean(key: "prefer_music_only", default: false)
    @State var confirmImport = false
    @State var theme = PlatformSettings.shared.getString(key: "theme_mode", default: "dark")
    @State var lyricsSources = LyricsSourceNames.normalizeList(
        PlatformSettings.shared.getString(key: "lyrics_sources", default: LyricsSourceNames.defaultEnabled)
    )
    @State var lyricsSourceOrder = LyricsSourceNames.normalizeList(
        PlatformSettings.shared.getString(key: "lyrics_source_order", default: LyricsSourceNames.defaultEnabled)
    )
    @State var playbackSpeed = Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
    @State var stopBackground = PlatformSettings.shared.getBoolean(key: "stop_when_backgrounded", default: false)
    @State var stopMusicOnClose = PlatformSettings.shared.getBoolean(key: "stop_music_on_close", default: false)
    @State var hidePlayerStatusBar = PlatformSettings.shared.getBoolean(key: "hide_status_bar_in_player", default: false)
    @State var showQueueHistory = PlatformSettings.shared.getBoolean(key: "show_queue_history", default: false)
    @State var artistSignatures = PlatformSettings.shared.getBoolean(key: "artist_signatures_enabled", default: true)
    @State var artistSignaturesWikimediaUrl = PlatformSettings.shared.getString(key: "artist_signatures_wikimedia_url", default: "")
    @State var syllableSync = PlatformSettings.shared.getBoolean(key: "prioritize_syllable_sync", default: true)
    @State var language = PlatformSettings.shared.getString(key: "app_language", default: "")
    @State var spotifyCookie = PlatformSettings.shared.getString(key: "spotify_spdc_token", default: "")
    @State var replayGenres = PlatformSettings.shared.getBoolean(key: "replay_genres", default: true)
    @State var exportPresented = false
    @State private var importPresented = false
    @State var backupNote: String?
    @State var cacheLimitMB = SettingsView.cacheLimitMegabytes()
    @State var cacheUnlimited = SettingsView.cacheIsUnlimited()
    @AppStorage(SettingsDeepLink.requestKey) var requestedSettingsPage = ""
    /// Whether the Library's folder list offers the cached-songs browser. Off by
    /// default, as upstream's storage switch is: the cache is a storage detail,
    /// not a music library, until somebody asks to browse it.
    @AppStorage("show_cached_songs_in_library") var showCachedSongs = false
    @State var loginPresented = false
    @State var discordPresented = false
    /// The Automix models offer, raised when Automix is switched on without the
    /// beat model that makes it worth having.
    @State private var offerModelsSheet = false
    @State var songCacheNote: String?
    @State var imageCacheNote: String?
    /// The settings search box. Empty means "no filter", not "nothing" — clearing
    /// it must bring the whole screen back.
    @State private var search = ""
    @State private var deepLinkedSettingsSection: SettingsSection?
    #if os(macOS)
    @State private var settingsHistory = PathNavigator()
    @State private var selectedMacSettingsSection: SettingsSection? = .sources
    #endif

    var metered: Bool { NetworkQuality.shared.metered }

    var body: some View {
        Group {
            if embedded {
                settingsForm
                    .navigationTitle("Settings")
                    .searchable(text: $search, prompt: "Search settings")
            } else {
                #if os(macOS)
                macSettingsSplitView
                    .navigationTitle("Settings")
                    // The titlebar's own search pill at the trailing edge.
                    .searchable(text: $search, placement: .toolbar, prompt: "Search")
                    .environment(\.inBrowseStack, true)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        MacHistoryButtons(navigator: settingsHistory)
                    }
                }
                .background(UnifiedTitlebar())
                #else
                NavigationStack {
                    settingsForm
                        .navigationTitle("Settings")
                        .searchable(text: $search, prompt: "Search settings")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 720)
        #endif
        .alert("Higher refresh rate?", isPresented: $showPerfWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { highPerf = true }
        } message: {
            Text("Holding a high refresh rate keeps the display working harder the whole time BitChord is open, and the battery drains faster for it. Turn it on anyway?")
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                LocalLibrary.shared.scanPicked(url)
                localFolderName = SettingsView.storedLocalFolderName()
                    ?? url.lastPathComponent
            }
        }
        .onAppear {
            // The tuner holds a display link while high performance is on, so it
            // has to be (re)applied every time this screen appears — and a value
            // written by another build that is not a rate offered here snaps to
            // 60 rather than requesting a mode the picker cannot name.
            if !PerformanceTuner.supportedRates.contains(refreshRate) { refreshRate = 60 }
            PerformanceTuner.shared.apply(highPerformance: highPerf, refreshRateHz: refreshRate)
            localFolderName = SettingsView.storedLocalFolderName()
        }
        .preferredColorScheme(appModel.preferredScheme)
        .onChange(of: dolbyAtmos) { _, value in AppSettings.shared.setDolbyAtmos(value: value) }
        .onChange(of: loudnessOffOnSpeaker) { _, value in
            AppSettings.shared.setLoudnessOffOnSpeaker(value: value)
            controller.updateLoudnessMode(controller.loudnessMode)
        }
        .onChange(of: hidePlayerStatusBar) { _, value in AppSettings.shared.setHideStatusBarInPlayer(value: value) }
        .onChange(of: showQueueHistory) { _, value in AppSettings.shared.setShowQueueHistory(value: value) }
        .onChange(of: stopMusicOnClose) { _, value in AppSettings.shared.setStopMusicOnClose(value: value) }
        .onChange(of: videoOverCellular) { _, value in
            PlatformSettings.shared.putBoolean(key: "video_over_cellular", value: value)
            VideoPlayback.shared.refreshNetworkPolicy()
        }
        .onChange(of: lyricsBlur) { _, value in AppSettings.shared.setLyricsBlur(value: value) }
        .onChange(of: translationLanguage) { _, value in AppSettings.shared.setTranslationLanguage(value: value) }
        .sheet(isPresented: $loginPresented) { loginSheet }
        .sheet(isPresented: $discordPresented) { DiscordLoginView() }
        // The offer again, from inside Settings, when Automix is switched on with
        // no beat model to time it. Presented here rather than through the root
        // binding because on macOS this screen is its own window and has no root
        // view above it.
        .sheet(isPresented: $offerModelsSheet) { AutomixModelsSheet() }
        .modifier(SettingsPlaybackPersist(
            controller: controller,
            crossfade: $crossfade,
            spatial: $spatial,
            automix: $automix,
            automixSequence: $automixSequence,
            automixPerf: $automixPerf,
            skipSilence: $skipSilence,
            playbackSpeed: $playbackSpeed,
            onAutomixEnabled: {
                if appModel.mayAskForAutomixModels() { offerModelsSheet = true }
            }
        ))
        .modifier(SettingsQualityPersist(
            controller: controller,
            wifiQuality: $wifiQuality,
            cellQuality: $cellQuality,
            downloadQuality: $downloadQuality,
            wifiOnlyDownloads: $wifiOnlyDownloads,
            cacheLimitMB: $cacheLimitMB,
            outputPcm: $outputPcm,
            matchSourceRate: $matchSourceRate,
            bitPerfect: $bitPerfect,
            preferUsbDac: $preferUsbDac,
            loudness: $loudness,
            loudnessModeSelection: $loudnessModeSelection
        ))
        .modifier(SettingsExperiencePersist(
            controller: controller,
            appModel: appModel,
            nerdStats: $nerdStats,
            canvas: $canvas,
            canvasCellular: $canvasCellular,
            reduceBlur: $reduceBlur,
            reduceAnimation: $reduceAnimation,
            fullBleed: $fullBleed,
            syncedLyrics: $syncedLyrics,
            convertVideo: $convertVideo,
            swipeNext: $swipeNext,
            dontRepeat: $dontRepeat,
            hideVolume: $hideVolume,
            legacyMesh: $legacyMesh,
            preferMusicOnly: $preferMusicOnly,
            theme: $theme
        ))
        .modifier(SettingsAdvancedPersist(
            controller: controller,
            smartAlign: $smartAlign,
            hideSongStatus: $hideSongStatus,
            exportDownloads: $exportDownloads,
            filterNonMusic: $filterNonMusic,
            highPerf: $highPerf,
            refreshRate: $refreshRate,
            reduceAnimation: $reduceAnimation,
            reduceBlur: $reduceBlur
        ))
        .modifier(SettingsExtrasPersist(
            lyricsSources: $lyricsSources,
            lyricsSourceOrder: $lyricsSourceOrder,
            stopBackground: $stopBackground,
            syllableSync: $syllableSync,
            language: $language,
            spotifyCookie: $spotifyCookie,
            replayGenres: $replayGenres,
            appModel: appModel
        ))
        // Asked before the picker opens rather than after a file is chosen: the
        // thing being confirmed is that this device's own data is about to be
        // replaced, and that is true whichever file gets picked.
        .alert("Replace this device's data?", isPresented: $confirmImport) {
            Button("Cancel", role: .cancel) {}
            Button("Choose File") { importPresented = true }
        } message: {
            Text("Importing a backup replaces the settings and listening history on this device. This cannot be undone.")
        }
        .fileExporter(
            isPresented: $exportPresented,
            document: SettingsBackupFile(text: BitChordBackup.exportText()),
            contentType: .json,
            defaultFilename: BitChordBackup.suggestedName()
        ) { result in
            if case .success = result { backupNote = "Settings exported" }
        }
        .fileImporter(isPresented: $importPresented, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                BitChordBackup.importText(text)
                backupNote = "Imported — reopen Settings to see them"
            }
        }
    }

    /// The sections of this screen, in order.
    ///
    /// Only the order and the titles live here now. What a section *contains* is a
    /// question its own rows answer (see `SettingsRows`): a keyword table kept
    /// beside the section could only describe the section as a whole, which is how
    /// typing "flac" came to mean "show every row in Audio Quality".
    enum SettingsSection: String, CaseIterable, Identifiable {
        case sources, audioQuality, playback, downloads, appearance, account, advanced, yourData, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sources: return "Sources"
            case .account: return "Account & Integrations"
            case .audioQuality: return "Sound & Quality"
            case .downloads: return "Downloads & Storage"
            case .playback: return "Playback"
            case .appearance: return "Appearance"
            case .yourData: return "Your Data & Backup"
            case .advanced: return "Advanced Options"
            case .about: return "About & Updates"
            }
        }

        var systemImage: String {
            switch self {
            case .sources: return "square.stack.3d.up"
            case .account: return "person.crop.circle"
            case .audioQuality: return "waveform"
            case .downloads: return "arrow.down.circle"
            case .playback: return "play.circle"
            case .appearance: return "paintbrush"
            case .yourData: return "externaldrive"
            case .advanced: return "gearshape.2"
            case .about: return "info.circle"
            }
        }
    }

    // MARK: - Rows

    /// One row that survived the search filter, with whatever it draws itself as.
    struct SettingsRowEntry: Identifiable {
        let id: Int
        let title: String
        let content: AnyView
    }

    /// A group's rows, filtered by the search field as they are added.
    ///
    /// Ported from upstream's `SettingsGroupScope.row` (`Ua/ui/screens/SettingsSheet.kt:2332`):
    /// each row declares the words somebody might type looking for it, and the
    /// group's own title counts for every row beneath it, so searching "playback"
    /// turns up the playback group entire rather than nothing at all. A group with
    /// no rows left draws nothing — header, footer and all — which is why there is
    /// no section-level filter any more: whether a group exists is a question only
    /// its rows can answer, and a keyword table kept beside the group answered it
    /// for the whole group at once ("flac" used to bring back all of Audio Quality).
    struct SettingsRows {
        let query: String
        let sectionTitle: String
        private(set) var entries: [SettingsRowEntry] = []

        /// Adds a row if the search field admits it.
        ///
        /// - Parameters:
        ///   - title: what the row is called; also its first search term.
        ///   - keywords: what the title does not say that the row's subtitle or its
        ///     synonyms do — the words somebody would actually type ("flac" for a
        ///     lossless quality row, "party" for Listen Together).
        mutating func row<V: View>(
            _ title: String,
            _ keywords: String...,
            @ViewBuilder content: () -> V
        ) {
            row(title, keywords: keywords, content: content)
        }

        /// The same, for a caller that already holds its keywords as a list.
        mutating func row<V: View>(
            _ title: String,
            keywords: [String],
            @ViewBuilder content: () -> V
        ) {
            let terms = ([sectionTitle, title] + keywords).joined(separator: Self.separator)
            // The matching policy stays in the shared layer (SettingsSearchBridge),
            // where the terms and the comparison cannot drift apart.
            guard SettingsSearchBridge.shared.matches(
                query: query,
                title: sectionTitle,
                termsCsv: terms
            ) else { return }
            entries.append(SettingsRowEntry(id: entries.count, title: title, content: AnyView(content())))
        }

        mutating func append(_ entry: SettingsRowEntry) {
            entries.append(SettingsRowEntry(id: entries.count, title: entry.title, content: entry.content))
        }

        /// ASCII unit separator, as the bridge expects: the terms are phrases, and
        /// a separator that can appear inside one is a separator that will split one.
        private static let separator = "\u{1F}"
    }

    /// A section and the rows the search field left in it.
    private struct BuiltSection: Identifiable {
        let section: SettingsSection
        let rows: [SettingsRowEntry]
        var id: String { section.id }
    }

    /// Every section, in order, with only the rows the search field admits.
    ///
    /// Built for the whole screen at once rather than section by section, because
    /// the "nothing matches" message is a question about the screen: a section that
    /// lost every row is not drawn, so the form has to know whether that happened
    /// to all of them.
    private func builtSections() -> [BuiltSection] {
        SettingsSection.allCases.compactMap { section in
            let rows = rows(for: section)
            return rows.isEmpty ? nil : BuiltSection(section: section, rows: rows)
        }
    }

    func rows(for section: SettingsSection) -> [SettingsRowEntry] {
        var rows = SettingsRows(query: search, sectionTitle: section.title)
        switch section {
        case .sources:
            rows.row("Sources", keywords: AudioSettingsItem.sources.keywords + ["addon", "source"]) {
                PushLink { SourcesView() } label: { Label("Manage Sources", systemImage: "square.stack.3d.up") }
            }
        case .account:
            buildAccountRows(&rows)
            appendMiscRows(&rows, titles: ["Listen together", "Spotify Canvas"])
        case .audioQuality: buildAudioQualityRows(&rows)
        case .downloads:
            buildDownloadRows(&rows)
            buildLocalMusicRows(&rows)
            buildStorageRows(&rows)
        case .playback:
            buildPlaybackRows(&rows)
            appendMiscRows(&rows, titles: ["Play Next on Swipe", "Don’t Repeat Songs in Current Session", "Show Queue History", "Stop When Backgrounded", "Stop Music on Close"])
        case .appearance:
            buildAppearanceRows(&rows)
            appendMiscRows(&rows, titles: ["Hide Volume Bar", "Hide Song Status", "Hide Status Bar in Player", "App Language"])
        case .advanced:
            buildAdvancedRows(&rows)
            buildAutomixAdvancedRows(&rows)
            buildPerformanceRows(&rows)
        case .yourData: buildYourDataRows(&rows)
        case .about: buildAboutRows(&rows)
        }
        return rows.entries
    }

    private func appendMiscRows(_ rows: inout SettingsRows, titles: Set<String>) {
        var legacy = SettingsRows(query: rows.query, sectionTitle: rows.sectionTitle)
        buildMiscellaneousRows(&legacy)
        for entry in legacy.entries where titles.contains(entry.title) { rows.append(entry) }
    }

    /// What a section says underneath itself, when it has anything to say.
    ///
    /// The footer travels with the group: one that lost every row takes its footer
    /// with it rather than leaving a paragraph about settings that are not there.
    @ViewBuilder
    private func footer(for section: SettingsSection) -> some View {
        switch section {
        case .audioQuality:
            Text("Source Quality is the request. Current Output shows the decoded audio, device format and processing actually in use. Technical Audio & DAC contains output-specific options.")
        case .downloads:
            Text("Exported downloads live in the shared Music folder. Private ones stay inside BitChord's own storage.")
        case .playback:
            Text("Gapless stays on at 0s. Automix picks timing per track; crossfade sets the manual blend length.")
        case .advanced:
            Text("Analysis and display performance options can increase CPU use and battery consumption. Version alignment controls how a source switch resumes the recording.")
        case .about:
            Text("BitChord \(update.currentVersion)")
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        case .sources, .account, .appearance, .yourData:
            EmptyView()
        }
    }

    #if os(macOS)
    private var macSettingsSplitView: some View {
        let visibleSections = search.isEmpty ? SettingsSection.allCases : builtSections().map(\.section)
        return SettingsMacSplitView(
            sections: visibleSections,
            selection: $selectedMacSettingsSection,
            sidebarLabel: { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            },
            detail: { section in
                NavigationStack(path: Bindable(settingsHistory).path) {
                    settingsSectionPage(section)
                        .navigationTitle("Settings")
                        .navigationDestination(for: PushRoute.self) { route in
                            route.make().navigationBarBackButtonHidden(true)
                        }
                        .onAppear { consumeMacSettingsDeepLinkIfNeeded() }
                        .onChange(of: requestedSettingsPage) { _, _ in
                            consumeMacSettingsDeepLinkIfNeeded()
                        }
                }
            }
        )
        .onChange(of: selectedMacSettingsSection) { _, _ in
            settingsHistory = PathNavigator()
        }
        .onChange(of: search) { _, _ in
            settingsHistory = PathNavigator()
            let visibleSections = search.isEmpty ? SettingsSection.allCases : builtSections().map(\.section)
            if let selectedMacSettingsSection,
               visibleSections.contains(selectedMacSettingsSection) {
                return
            }
            selectedMacSettingsSection = visibleSections.first
        }
    }

    private func consumeMacSettingsDeepLinkIfNeeded() {
        guard !requestedSettingsPage.isEmpty,
              let rawValue = SettingsSectionName.canonical(requestedSettingsPage),
              let section = SettingsSection(rawValue: rawValue)
        else { return }
        requestedSettingsPage = ""
        search = ""
        settingsHistory = PathNavigator()
        selectedMacSettingsSection = section
    }
    #endif

    private func settingsSectionForm(_ section: SettingsSection) -> some View {
        let entries = rows(for: section)
        let cleanupTitles: Set<String> = ["Clear Song Cache", "Clear Image Cache"]
        return Form {
            Section {
                ForEach(entries.filter { !cleanupTitles.contains($0.title) }) { row in row.content }
            } header: { Text(section.title) } footer: { if search.isEmpty { footer(for: section) } }
            if section == .downloads {
                Section {
                    ForEach(entries.filter { cleanupTitles.contains($0.title) }) { row in row.content }
                } header: { Text("Free Storage") } footer: {
                    Text("Cache actions remove temporary files. Data import and backup are on Your Data & Backup.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func settingsSectionPage(_ section: SettingsSection) -> some View {
        if section == .sources { SourcesView() }
        else { settingsSectionForm(section).navigationTitle(section.title) }
    }

    private func sectionSummary(_ section: SettingsSection) -> String {
        switch section {
        case .sources:
            let state = SourceListState.shared
            guard state.hasLoaded else { return "Addons, source order, renewal and your libraries" }
            let enabled = state.configs.filter { $0.enabled }.count
            let attention = state.loadError != nil || state.configs.contains { config in
                config.enabled && (state.health[config.id]?.name == "rejected" || state.health[config.id]?.name == "unreachable")
            }
            return "\(enabled) enabled" + (attention ? " · needs attention" : "")
        case .audioQuality: return "Requested quality, decoded format, effects and device output"
        case .playback: return "Queue, transitions, speed and background playback"
        case .downloads: return "Offline quality, local folders and temporary storage"
        case .appearance: return "Player, lyrics, language and visual preferences"
        case .account: return "Sign-in, sharing and connected services"
        case .advanced: return "Models, analysis, performance and version alignment"
        case .yourData: return "Listening history, export and importing a backup"
        case .about: return "Installed build, latest release and installation"
        }
    }

    private var settingsForm: some View {
        let sections = search.isEmpty ? [] : builtSections()
        return ScrollViewReader { proxy in
            Form {
                if search.isEmpty {
                    Section {
                        ForEach(SettingsSection.allCases) { section in
                            PushLink { settingsSectionPage(section) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(section.title, systemImage: section.systemImage)
                                    Text(sectionSummary(section)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 3)
                            }
                            .id(section.id)
                        }
                    } header: { Text("Settings") }
                } else {
                ForEach(sections) { built in
                    Section {
                        ForEach(built.rows) { row in
                            row.content
                        }
                    } header: {
                        Text(built.section.title)
                    } footer: {
                        // Not while searching. A footer explains the rows that sat above
                        // it, and the search has filtered those: the Audio Quality note
                        // talks about sample-rate matching and bit-perfect output whether
                        // or not either row survived the query. Upstream draws no
                        // footers in search results for the same reason.
                        if search.isEmpty {
                            footer(for: built.section)
                        }
                    }
                    .id(built.section.id)
                }
                if sections.isEmpty { ContentUnavailableView.search(text: search) }
                }
            }
            .formStyle(.grouped)
            // The sheets, the picker and the warning belong to the screen rather than
            // to one group: the group they used to hang off can be filtered away, and
            // what it raises must still be able to appear.
            .navigationDestination(item: $deepLinkedSettingsSection) { section in settingsSectionPage(section) }
            .onAppear { consumeSettingsDeepLinkIfNeeded(using: proxy) }
            .onChange(of: requestedSettingsPage) { _, _ in consumeSettingsDeepLinkIfNeeded(using: proxy) }
        }
    }

    private func consumeSettingsDeepLinkIfNeeded(using proxy: ScrollViewProxy) {
        guard !requestedSettingsPage.isEmpty,
              let section = SettingsSectionName.canonical(requestedSettingsPage)
        else { return }
        requestedSettingsPage = ""
        search = ""
        Task { @MainActor in
            await Task.yield()
            withAnimation { proxy.scrollTo(section, anchor: .top) }
            deepLinkedSettingsSection = SettingsSection(rawValue: section)
        }
    }

    // MARK: - Account

}

// MARK: - Account & integrations
