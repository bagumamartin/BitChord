import SwiftUI
import Observation
import BitChordShared

@main
struct BitChordApp: App {
    // The player, the navigation model and the session come from `AppServices`
    // rather than being built here: App Intents (Siri, Shortcuts, Spotlight) run
    // in this process with no scene to read an environment from, and they have to
    // reach these same instances. A second controller would open a second output
    // stream and fight this one for the system's media slot (see the `partySync`
    // note below), so the holder is the only place they are made.
    @State private var controller = AppServices.shared.controller
    @State private var appModel = AppServices.shared.appModel
    @State private var auth = AppServices.shared.auth
    @State private var toast = ToastCenter()
    @State private var party = PartyStore.shared
    /// The one binding between a party and this device's player.
    ///
    /// Built in the launch task with *this* session's `PlaybackController`,
    /// not constructed inline: a `@State` initialiser cannot reference its
    /// sibling `controller`, and the old placeholder `PlaybackController()`
    /// here booted a whole second engine every launch — a second output
    /// stream, a second set of remote-command handlers, and on iOS a second
    /// same-id MediaSession fighting the real one for the system slot.
    /// Kept at the app rather than in a view because a party's lifetime is
    /// the listener's and not a view's — most of listening together is the
    /// screen being somewhere else.
    @State private var partySync: PartySync?
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @AppStorage("menu_bar_player") private var menuBarPlayer = true
    #endif

    init() {
        // Music videos are a per-session choice: the owner wants every session
        // to start with the artwork, and the pill's toggle to turn the picture
        // on for this session only.
        UserDefaults.standard.set(false, forKey: "show_music_videos")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                #if os(macOS)
                // Inside the environment calls below: the toolbar's button and
                // sheet read the controller, auth and toast models.
                .background(SettingsDeepLinkOpener())
                .modifier(MacWindowAccountToolbar())
                .allowsWindowActivationEvents(true)
                #endif
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .environment(toast)
                .environment(party)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--verify-queue") {
                        await controller.verifyQueueBehavior()
                        return
                    }
                    #if os(iOS)
                    if ProcessInfo.processInfo.arguments.contains("--verify-restored-resume") {
                        CipherUnlockWiring.install()
                        ApplePoTokenWiring.install()
                    PlaybackCodecCapabilities.shared.setAppleDolbyAvailable(value: AppleDolbyRenderer.available)
                        let mixing = ProcessInfo.processInfo.arguments.contains("--mixing-on")
                        await controller.verifyRestoredResumeBehavior(mixing: mixing)
                        return
                    }
                    if ProcessInfo.processInfo.arguments.contains("--verify-navigation") {
                        CipherUnlockWiring.install()
                        ApplePoTokenWiring.install()
                    PlaybackCodecCapabilities.shared.setAppleDolbyAvailable(value: AppleDolbyRenderer.available)
                        await controller.verifyRapidNavigation()
                        return
                    }
                    if ProcessInfo.processInfo.arguments.contains("--verify-dolby") {
                        PlaybackCodecCapabilities.shared.setAppleDolbyAvailable(value: AppleDolbyRenderer.available)
                        await controller.verifyDolbyQueue()
                        return
                    }
                    if ProcessInfo.processInfo.arguments.contains("--verify-natural-end") {
                        await controller.verifyNaturalEndFallback()
                        return
                    }
                    if ProcessInfo.processInfo.arguments.contains("--verify-native-resume") {
                        await controller.verifyNativeResumeBehavior()
                        return
                    }
                    #endif
                    if ProcessInfo.processInfo.arguments.contains("--verify-sleep") {
                        await controller.verifySleepBehavior()
                        return
                    }
                    #endif
                    #if os(macOS)
                    MacAppDelegate.controller = controller
                    #endif
                    CipherUnlockWiring.install()
                    ApplePoTokenWiring.install()
                    PlaybackCodecCapabilities.shared.setAppleDolbyAvailable(value: AppleDolbyRenderer.available)
                    SecretStoreWiring.install()
                    ModuleEngineWiring.install()
                    PartySocket.register()
                    // Update checks are launch-level behavior rather than an About
                    // screen side effect. On iPhone and iPad this raises the update
                    // alert wherever the listener starts; on Mac the About row and
                    // the update sheet remain available.
                    #if os(iOS)
                    Task { await UpdateChecker.shared.pollOnce() }
                    #else
                    _ = MacUpdateManager.shared
                    #endif
                    // Before anything can reach the coordinator: it needs the platform
                    // clock and somewhere to publish, and a coordinator that has
                    // neither measures against a clock of zero and believes the answer.
                    PartyStore.install()
                    let binding = PartySync(controller: controller)
                    partySync = binding
                    party.attach(player: binding)
                    // The player tells the party when the *listener* presses something,
                    // so a press is not undone by the next frame still describing the
                    // old transport. Wired here, once, because the controller outlives
                    // every view and the party binding is replaced on each launch.
                    controller.onLocalIntent = { [weak binding] in
                        binding?.onLocalIntent()
                    }
                    // Offer what is playing to the listener's other devices. The
                    // offer is (re)published when the answer can change — a new
                    // track, a play/pause, leaving the app; the playhead itself is
                    // written by the activity's own save hook, immediately before
                    // the system sends it to the other device.
                    PlaybackHandoff.shared.refresh(controller: controller)
                    AppShortcutRefresh.schedule()
                    // Reconcile installed models after content appears. Graphs
                    // are loaded off-main when playback starts, so browsing a
                    // library does not keep unused inference models resident.
                    Task {
                        await LaunchReadiness.shared.waitForContent()
                        Task { await PageRequestCoordinator.shared.removeLegacyCache() }
                        await AutomixModelStore.shared.refresh()
                        AutomixModelStore.shared.onChanged = {
                            Task {
                                await reloadAutomixModels(playbackStarted: controller.started)
                                if controller.automixEnabled { controller.syncEngineQueueNext() }
                            }
                        }
                        // Engine is started on-demand when the user actually begins
                        // playback (via playQueue, togglePlayPause, or remote commands)
                        // so opening the app never interrupts other audio playing on the device.
                        // After the shell is up and the first frame has been drawn: an
                        // offer as the window appears reads as chrome, and one that
                        // arrives a moment later reads as a question.
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            appModel.offerAutomixModelsIfNeeded()
                        }
                        LocalLibrary.shared.restore()
                        DownloadStore.shared.refresh()
                        Task.detached(priority: .utility) {
                            let cache = StreamFileCache.shared
                            await cache.trim()
                            let pending = await cache.entries().filter { $0.entry == nil || $0.artworkReference == nil }
                            guard !pending.isEmpty else { return }
                            let names = pending.contains(where: { $0.entry == nil }) ? ListeningStore.savedTrackMetadata() : [:]
                            for item in pending {
                                guard !Task.isCancelled else { return }
                                let entry: QueueEntry?
                                if let saved = item.entry { entry = saved }
                                else if let track = names[item.videoId] {
                                    let source = item.videoId.hasPrefix("src:") || item.videoId.hasPrefix("saavn:") ? item.videoId : "yt:" + item.videoId
                                    entry = QueueEntry(id: item.videoId, title: track.title, artist: track.artist,
                                        source: source, thumbnailUrl: track.art, albumName: track.album, isLocal: false)
                                } else { entry = nil }
                                if let entry { await cache.remember(entry, allowNetwork: false) }
                            }
                        }
                        let token = PlatformSettings.shared.getSecret(key: "discord_token") ?? ""
                        if !token.isEmpty { DiscordGateway.shared.connect(token: token) }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    appModel.scenePhase = phase
                    LoadingMonitor.shared.setActive(phase == .active)
                    if phase == .background {
                        // No GPU work back here: a Music Understanding inference
                        // caught mid-flight aborts with
                        // BackgroundExecutionNotPermitted and sprays Metal/E5RT
                        // errors. The analyzer suspends the rest of the stretch
                        // and serves Automix from its disk cache instead.
                        MusicUnderstandingAnalyzer.noteBackground()
                        controller.persistSession()
                        // Keep the offer current as the app goes away. The
                        // playhead is written at save time, so this is about the
                        // track and the paused/running state.
                        PlaybackHandoff.shared.refresh(controller: controller)
                        if PlatformSettings.shared.getBoolean(key: "stop_when_backgrounded", default: false) {
                            #if os(macOS)
                            // macOS can report the last-window close as a scene
                            // background transition while the app is kept resident.
                            // Let the separate Stop Music on Close setting own that
                            // action; this setting remains for app deactivation/hide.
                            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible }
                            guard NSApp.isHidden || (!NSApp.isActive && hasVisibleWindow) else { return }
                            #endif
                            controller.pauseForBackground()
                        }
                    } else if phase == .active {
                        MusicUnderstandingAnalyzer.noteForeground()
                        controller.reactivateAudioSessionAfterForeground()
                    }
                }
                #if os(macOS)
                // Bare Space / ← / → live here rather than in the menu: see
                // `MacTransportKeys`.
                .modifier(MacTransportKeys(controller: controller))
                #endif
                .onOpenURL { url in
                    if SettingsDeepLink.handle(url) {
                        #if os(iOS)
                        appModel.settingsPresented = true
                        #endif
                        return
                    }
                    // Handling lives here, on the scene, rather than on `RootView`.
                    // It was installed in both places, so whichever ran second
                    // consumed the link and the other was dead — a `bitchord://`
                    // link reached the player only by accident of ordering. On the
                    // scene it runs before the view hierarchy exists, which is what
                    // a cold launch from a link actually needs.
                    if url.absoluteString.contains("open-player") {
                        let requestedScreen = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "screen" })?.value
                        if requestedScreen?.caseInsensitiveCompare("lyrics") == .orderedSame {
                            PlatformSettings.shared.putString(key: "last_player_screen", value: "LYRICS")
                        }
                        appModel.nowPlayingPresented = true
                    }
                    // An invite is not joined on the spot: it is carried to the
                    // Listen Together screen, which shows who is in the party before
                    // a slot is committed. Same as upstream, where a link is consent
                    // to *look*, not to join. The screen carries its own server editor,
                    // so a link pointing at somebody else's server needs no trip
                    // through Settings to get there.
                    if JamInviteLink.shared.looksLikeInvite(value: url.absoluteString) {
                        appModel.pendingPartyInvite = url.absoluteString
                        appModel.listenTogetherPresented = true
                    }
                    _ = MusicLink.shared.submitUrl(url: url.absoluteString)
                    consumeMusicLink(appModel: appModel, controller: controller)
                }
                // Handoff: the receiving half, plus the two changes that keep the
                // offer current. At the scene for the same reason the URL intake
                // is — a track can start, or an activity can arrive, before the
                // view hierarchy is complete.
                .onChange(of: controller.current?.id) { _, _ in
                    PlaybackHandoff.shared.refresh(controller: controller)
                    // What Siri may match a song title against has changed with
                    // the queue. Throttled inside.
                    AppShortcutRefresh.schedule()
                }
                .onChange(of: controller.isPlaying) { _, _ in
                    PlaybackHandoff.shared.refresh(controller: controller)
                }
                .onContinueUserActivity(PlaybackHandoffPayload.activityType) { activity in
                    guard let payload = PlaybackHandoffPayload(userInfo: activity.userInfo) else { return }
                    PlaybackHandoff.shared.continuePlayback(payload: payload, controller: controller)
                }
        }
#if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.automatic)
        .commands {
            SidebarCommands()
            PlaybackCommands(controller: controller, appModel: appModel, auth: auth, toast: toast)
            MiniPlayerCommands()
        }
#endif
#if os(macOS)
        WindowGroup(id: MacBrowseWindow.sceneID, for: MacBrowseWindowRoute.self) { $route in
            MacBrowseWindowView(route: route)
                .allowsWindowActivationEvents(true)
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .environment(toast)
                .environment(party)
                .preferredColorScheme(appModel.preferredScheme)
        }
        .defaultSize(width: 1000, height: 760)
        Window("Mini Player", id: MiniPlayerWindow.id) {
            MiniPlayerView()
                .allowsWindowActivationEvents(true)
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .environment(toast)
                .environment(party)
                .preferredColorScheme(appModel.preferredScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        .windowLevel(.floating)

        MenuBarExtra(isInserted: $menuBarPlayer) {
            MiniPlayerView(compact: true)
                .allowsWindowActivationEvents(true)
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .environment(toast)
                .environment(party)
        } label: {
            Image(systemName: controller.isPlaying ? "waveform" : "music.note")
                // Static: a pulsing status item redraws the menu bar for as
                // long as music plays, which is CPU in the app and in the
                // WindowServer for an icon nobody is looking at.
        }
        .menuBarExtraStyle(.window)
#endif
#if os(macOS)
        Settings {
            SettingsView()
                .allowsWindowActivationEvents(true)
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .environment(toast)
                .environment(party)
                .preferredColorScheme(appModel.preferredScheme)
                .environment(\.locale, appModel.appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appModel.appLanguage))
        }
        // One unified titlebar row, as System Settings has: the traffic
        // lights, back and forward, the title and the search field together,
        // rather than a title strip over a second toolbar row.
        .windowToolbarStyle(.unified(showsTitle: true))
        #endif
    }
}

/// Hand the analyzer whatever Automix models this device has.
///
/// The paths are resolved on the main actor — the store's state lives there — and
/// the load itself runs detached. `configureAnalyzer` accepts empty paths and
/// treats them as "unload", which is what a model that was removed, or never
/// downloaded, must mean: Automix falls back to the tempo planner and stops
/// avoiding vocal clashes rather than refusing to transition at all.
///
/// Called at playback startup, preference changes, and model install/removal.
/// Disabling Automix unloads every graph including the Core ML accelerator;
/// Efficient mode unloads vocals and the accelerator.
@MainActor
func reloadAutomixModels(playbackStarted: Bool) async {
    let paths = AutomixModelStore.shared.analyzerPaths
    let accelerator = AutomixModelStore.shared.beatCoreML
    let enabled = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: true)
    let efficient = PlatformSettings.shared.getString(key: "automix_performance", default: "BALANCED") == "EFFICIENT"
    let selected = AutomixModelPolicy.paths(beat: paths.beat, vocal: paths.vocal,
        accelerator: accelerator, playbackStarted: playbackStarted, enabled: enabled, efficient: efficient)
    let ready = await AutomixModelLoader.shared.configure(
        beat: selected.beat,
        vocal: selected.vocal,
        accelerator: selected.accelerator
    )
    DebugLog.shared.d(
        message: "automix models: beat=\(selected.beat) vocal=\(selected.vocal) "
            + "accelerated=\(selected.accelerator != nil) loaded=\(ready)"
    )
}

/// App-level state that is not playback: navigation triggers, external-link
/// intake, tab persistence.
@Observable
final class AppModel {
    var scenePhase: ScenePhase = .active
    var nowPlayingPresented = false
    /// Presented by the account control in each iPhone tab's own toolbar.
    var settingsPresented = false
    /// Cross-tab navigation request — RootView observes and consumes it.
    var requestedTab: Tab?
    /// Bumped when the already-selected Search tab is tapped again, so the field
    /// can take focus. Upstream's `searchFocusTrigger`.
    ///
    /// A counter rather than a flag: a flag has to be cleared by whoever reads
    /// it, and two taps in quick succession would otherwise be one tap's worth of
    /// intent. Counting means the second tap is honoured even if the first is
    /// still being handled.
    var searchFocusTrigger = 0
    var pendingDetail: BrowseDestination?
    /// An artist page to push on the Mac window's browse stack, so it is part
    /// of back/forward history rather than a sheet over the window.
    var pendingArtistPage: BrowseDestination?
    var playlistPicker: PlaylistPickerRequest?
    var downloadManagerPresented = false
    var replayPresented = false
    /// The two import flows, reachable from the Mac's File menu from any page:
    /// the command switches to Playlists and asks the page to open its sheet.
    var spotifyImportPresented = false
    var playlistFileImportPresented = false
    /// Which Replay story to open when the sheet arrives. Set alongside
    /// `replayPresented` by library heroes — a tapped card opens Replay at
    /// its chart, the empty-state banner at the intro — and consumed by
    /// `ReplayView` on appear. Nil means the main Replay page.
    var replayInitialPage: ReplayStoryPage?
    /// Open Replay, optionally at one story page. Upstream's `onOpenReplay`.
    func openReplay(at page: ReplayStoryPage? = nil) {
        replayInitialPage = page
        replayPresented = true
    }
    /// The first-run Automix models offer. Set by ``offerAutomixModelsIfNeeded()``
    /// and consumed by `RootView`.
    var automixModelsPresented = false
    /// Listen Together, presented over whatever the listener was doing.
    ///
    /// Its own flag rather than a settings row, because a party invite is a request
    /// to *look* at a party, and the screen that answers it has to be the one that
    /// arrives — making somebody find Settings first would put a settings window
    /// between a link and the thing the link is about.
    var listenTogetherPresented = false
    /// Who is listening, from inside the player.
    ///
    /// Its own flag rather than a sheet hung off the playback pill, because the pill
    /// is built twice — once per platform — and two sheets on it means two sheets
    /// fighting over the same presentation.
    var partyMembersPresented = false
    /// An invite link that arrived from outside, waiting to be looked at.
    var pendingPartyInvite: String?
    var focusSearch = false
    var pendingSearchQuery: String?
    /// Whether the iPad's search button is open as a pill. The floating tab
    /// bar steps aside while it is, as the App Store's does, because the pill,
    /// the source switcher and the bar do not fit across one top bar.
    var iPadSearchExpanded = false
    /// Set by the macOS menu commands to ask the player to reveal a pane that is
    /// otherwise behind a toggle. One-shot: the player consumes it and clears it,
    /// so holding ⌘U does not keep re-toggling.
    var queueRevealRequested = false
    var lyricsRevealRequested = false
    var themeMode = PlatformSettings.shared.getString(key: "theme_mode", default: "dark")
    var appLanguage = PlatformSettings.shared.getString(key: "app_language", default: "")
    var pinLimitAlert = false
    var playlistRename: PlaylistRenameRequest?

    var preferredScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Whether the first-run offer has already been made this launch.
    ///
    /// Session-scoped rather than persisted: the persisted flag is the listener's
    /// "no", and it means "stop bringing this up on your own", not "never mention
    /// it again". Turning Automix on is a fresh question, and answering it with
    /// silence would leave the feature quietly half-working.
    @ObservationIgnored private var automixModelsAskedThisLaunch = false

    /// Offer the models, when there is something to offer and nobody has said no.
    ///
    /// The offer covers both graphs: an existing install that predates the vocals
    /// download has the beat graph but not the vocal one, and the app must ask once
    /// rather than silently dropping to the DSP mask. Vocals stay optional; the
    /// sheet's "Not Now" is the answer, and it is remembered. The key is new with
    /// the vocals download: a "not now" given to the beat-only offer said nothing
    /// about a model the app used to ship.
    @MainActor
    func offerAutomixModelsIfNeeded() {
        guard !AutomixModelStore.shared.allInstalled else { return }
        guard !automixModelsPresented else { return }
        guard !automixModelsAskedThisLaunch else { return }
        // The session flag is spent only when the offer is actually shown. A launch
        // that honours a previous "not now" has not asked the listener anything, so
        // switching Automix on later in that session is still free to.
        guard !PlatformSettings.shared.getBoolean(key: "automix_models_prompt_dismissed_v2", default: false) else { return }
        automixModelsAskedThisLaunch = true
        automixModelsPresented = true
    }

    /// Whether switching Automix on may put the offer up again, once per launch.
    ///
    /// Separate from ``offerAutomixModelsIfNeeded()`` because the two present from
    /// different places — the root sheet and the Settings window — and a decline is
    /// about the launch offer, not about the deliberate act of turning the feature
    /// on and being told nothing.
    @MainActor
    func mayAskForAutomixModels() -> Bool {
        guard !AutomixModelStore.shared.allInstalled else { return false }
        guard !automixModelsAskedThisLaunch else { return false }
        automixModelsAskedThisLaunch = true
        return true
    }

    /// Remember a "not now", so the launch offer does not return on its own.
    func declineAutomixModels() {
        PlatformSettings.shared.putBoolean(key: "automix_models_prompt_dismissed_v2", value: true)
    }

    /// Open one credited artist's page from a player credit line.
    ///
    /// A track carries only its first artist's browse id, so every other name
    /// is looked up among YouTube Music's artists and opened only on an exact
    /// name match; a near miss would open somebody else's page, so it falls
    /// back to a search for the name instead.
    @MainActor
    func openArtist(named name: String, knownId: String?) {
        nowPlayingPresented = false
        Task { @MainActor in
            var browseId = knownId
            if browseId == nil {
                let hits = (try? await InnertubeSearch.shared.search(name, scope: "artists")) ?? []
                browseId = Self.artistMatch(name, in: hits)?.browseId
            }
            guard let browseId else {
                pendingSearchQuery = name
                requestedTab = .search
                focusSearch = true
                return
            }
            await showPage(.detail(browseId: browseId, title: name))
        }
    }

    /// Open a browse page (an album from the player's title) over whatever
    /// the player covered.
    @MainActor
    func openPage(browseId: String, title: String) {
        nowPlayingPresented = false
        Task { @MainActor in await showPage(.detail(browseId: browseId, title: title)) }
    }

    @MainActor
    private func showPage(_ destination: BrowseDestination) async {
        #if os(macOS)
        pendingArtistPage = destination
        #else
        // The player is a full-screen cover; a sheet asked for while it is
        // still leaving is dropped, so wait out the dismissal.
        try? await Task.sleep(for: .milliseconds(450))
        pendingDetail = destination
        #endif
    }

    static func artistMatch(_ name: String, in hits: [SearchHitDTO]) -> SearchHitDTO? {
        let wanted = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        return hits.first { hit in
            guard hit.isBrowse, let id = hit.browseId, id.hasPrefix("UC") else { return false }
            return hit.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces) == wanted
        }
    }

    /// Canonical tabs (UI spec §2). macOS Library sub-destinations live as
    /// extra cases so they can group under a `TabSection` in the sidebar.
    enum Tab: Int, Hashable {
        case home, explore, library, search
        case libraryYouTube, librarySongs, libraryAlbums
        case libraryArtists, libraryDownloads, libraryHistory, libraryWebDav
        case libraryPlaylists, librarySubscriptions, libraryPodcasts, libraryOnDevice
        /// One of the listener's own playlists, opened from the iPad sidebar.
        /// Which one is the sidebar's state; the tab only gives it a page.
        case sidebarPlaylist
    }
}

@MainActor
func consumeMusicLink(appModel: AppModel, controller: PlaybackController) {
    guard let json = MusicLink.shared.takePendingJson(),
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let kind = obj["kind"] as? String else { return }
    switch kind {
    case "track":
        if let id = obj["id"] as? String {
            controller.play([
                QueueEntry.youtube(videoId: id, title: "Loading…", artist: "", thumbnailUrl: nil)
            ], at: 0)
        }
    case "page":
        if let id = obj["id"] as? String {
            appModel.pendingDetail = .detail(browseId: id, title: "")
        }
    case "search":
        if let query = obj["query"] as? String {
            appModel.pendingSearchQuery = query
            appModel.requestedTab = .search
            appModel.focusSearch = true
            if obj["play"] as? Bool == true {
                Task {
                    if let hit = try? await InnertubeSearch.shared.search(query, scope: "songs").first(where: { !$0.isBrowse }) {
                        controller.play([hit.asEntry()], at: 0)
                    }
                }
            }
        }
    case "resume":
        if !controller.isPlaying { controller.togglePlayPause() }
    default:
        break
    }
}
