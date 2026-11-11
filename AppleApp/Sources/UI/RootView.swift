import SwiftUI
import BitChordShared
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Root navigation shell — one `TabView` with `.sidebarAdaptable` (UI spec §2):
/// bottom tab bar on iOS, Apple Music's leading sidebar on macOS, from a
/// single declaration. Exactly four canonical tabs, upstream icons, search
/// role pinned trailing. `@SceneStorage` keeps the last tab across launches.
struct RootView: View {
    @SceneStorage("bitchord.selectedTab") private var selection: Int = AppModel.Tab.home.rawValue
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(AuthController.self) private var auth
    @Environment(ToastCenter.self) private var toast
    @State private var updateChecker = UpdateChecker.shared
    @State private var whatsNew = WhatsNewCenter.shared
    #if os(macOS)
    /// Which side panel is open beside the library, if any (M4).
    @State private var macInspector: MacInspectorKind?
    /// What the sidebar has selected.
    /// The window's history: the sidebar row and the pages pushed on it.
    @State private var navigator = MacNavigator()
    @State private var macColumns: NavigationSplitViewVisibility = .all
    @State private var columnsBeforePlayer: NavigationSplitViewVisibility = .all
    private var macSide: MacSide {
        get { navigator.side }
        nonmutating set { navigator.side = newValue }
    }
    /// Home's scroll position, owned here rather than by HomeView: the detail
    /// column rebuilds on every sidebar row switch, and the reader's place in
    /// the feed should not be one of the things that resets.
    @State private var homeScroll = ScrollPosition()
    /// The listener's own playlists, listed in the sidebar as Music lists them.
    @State private var macPlaylists: [UserPlaylistDTO] = []
    #endif
    @State private var homeFeed = FeedLoader(.home)
    #if os(iOS)
    @Namespace private var nowPlayingZoom
    /// Regular width is the iPad layout — on any device. A Max phone turned
    /// sideways is a regular-width window too, and it has the room.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The listener's own playlists, listed in the iPad's sidebar as Music
    /// lists them.
    @State private var sidebarPlaylists: [UserPlaylistDTO] = []
    /// The sidebar playlist row being passed through to Library > Playlists.
    @State private var passingPlaylist: String?
    /// Each iPad tab's page history; a playlist chosen in the sidebar is pushed
    /// on Library > Playlists, so the tab bar shows Library rather than a tab
    /// of its own.
    @State private var pageHistories = PageHistories()
    /// The adaptable sidebar only honours a section's default visibility with
    /// customisation on, and it keeps the Playlists section out of the tab bar.
    @State private var tabCustomization = TabViewCustomization()
    /// The playlists' artwork for their sidebar rows, by playlist id. A sidebar
    /// row takes an image, not a view, so it is fetched ahead.
    @State private var sidebarArtwork: [String: UIImage] = [:]
    /// The library section last chosen on the iPad, where a deep link to the
    /// Library lands.
    @SceneStorage("bitchord.iPadLibrary") private var iPadLibraryTab: Int = AppModel.Tab.libraryYouTube.rawValue
    #endif
    @AppStorage(OnboardingView.doneKey) private var onboardingDone = false
    @State private var onboardingPresented = false
    /// The one selected row in the window, shared by every list.
    @State private var rowSelection = RowSelection()

    @State private var updateDetails: AppReleaseUpdate?

    var body: some View {
        shell
        .environment(\.rowSelection, rowSelection)
        .task {
            // First run only. Someone upgrading — signed in, or with a queue
            // to come back to — has already onboarded themselves.
            guard !onboardingDone else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if auth.signedIn || !controller.queue.isEmpty {
                onboardingDone = true
            } else {
                onboardingPresented = true
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $onboardingPresented) { OnboardingView() }
        #else
        .sheet(isPresented: $onboardingPresented) { OnboardingView() }
        #endif
        .onChange(of: appModel.requestedTab) { _, requested in
            guard let requested else { return }
            selection = resolvedTab(requested).rawValue
            #if os(macOS)
            macSide = MacSide(tab: requested)
            #endif
            appModel.requestedTab = nil
        }
        .sheet(isPresented: Binding(
            get: { auth.loginPresented },
            set: { auth.loginPresented = $0 }
        )) {
            NavigationStack {
                YtMusicLoginView(
                    onCaptured: { session, done in
                        auth.accept(session) { accepted in
                            if accepted { auth.loginPresented = false }
                            done(accepted)
                        }
                    },
                    onDismiss: { auth.loginPresented = false }
                )
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 640)
            #endif
        }
        .sheet(item: Binding(
            get: { appModel.playlistPicker },
            set: { appModel.playlistPicker = $0 }
        )) { req in
            PlaylistPickerView(request: req)
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { appModel.downloadManagerPresented },
            set: { appModel.downloadManagerPresented = $0 }
        )) {
            DownloadManagerView()
        }
        #endif
        .sheet(isPresented: Binding(
            get: { appModel.replayPresented },
            set: { appModel.replayPresented = $0 }
        )) {
            ReplayView()
        }
        // Listen Together, presented over whatever the listener was doing. A party
        // invite is a request to look at a party, and the screen that answers it has
        // to be the one that arrives.
        .sheet(isPresented: Binding(
            get: { appModel.listenTogetherPresented },
            set: { appModel.listenTogetherPresented = $0 }
        )) {
            NavigationStack { ListenTogetherView() }
        }
        .sheet(isPresented: Binding(
            get: { appModel.partyMembersPresented },
            set: { appModel.partyMembersPresented = $0 }
        )) {
            PartyMembersSheet()
                .environment(PartyStore.shared)
        }
        // The first-run model offer. Its own sheet at the root, because it is the
        // one question the app asks before it has been used at all and it must not
        // be attached to a screen the listener might never open.
        .sheet(isPresented: Binding(
            get: { appModel.automixModelsPresented },
            set: { appModel.automixModelsPresented = $0 }
        )) {
            AutomixModelsSheet(onDecline: { appModel.declineAutomixModels() })
        }
        .sheet(item: Binding(
            get: { appModel.pendingDetail },
            set: { appModel.pendingDetail = $0 }
        )) { dest in
            NavigationStack {
                if case .detail(let id, let title) = dest {
                    DetailView(browseId: id, initialTitle: title)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { appModel.pendingDetail = nil }
                            }
                        }
                }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 640)
            #endif
        }
        .alert("Only 5 playlists can be pinned", isPresented: Binding(
            get: { appModel.pinLimitAlert },
            set: { appModel.pinLimitAlert = $0 }
        )) {
            Button("OK", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { appModel.playlistRename != nil },
            set: { if !$0 { appModel.playlistRename = nil } }
        )) {
            RenamePlaylistAlert()
        }
        #if os(iOS)
        .alert("A BitChord update is available", isPresented: Binding(
            get: { updateChecker.available != nil },
            set: { if !$0 { updateChecker.dismiss() } }
        )) {
            Button("View Update") {
                updateDetails = updateChecker.available
                updateChecker.dismiss()
            }
            Button("Later", role: .cancel) { updateChecker.dismiss() }
        } message: {
            Text("BitChord \(updateChecker.available?.identity.label ?? "") is available. Update using the same method you used to install BitChord. View Update shows what changed since your version.")
        }
        .sheet(item: $updateDetails) { release in UpdateSheet(release: release) }
        #endif
        .sheet(isPresented: Binding(
            get: { !whatsNew.entries.isEmpty },
            set: { if !$0 { whatsNew.entries = [] } }
        )) {
            WhatsNewSheet(entries: whatsNew.entries)
        }
        .onChange(of: tabBinding.wrappedValue) { old, new in
            #if os(iOS)
            // A regular-width iPad's field is a button that opens into a pill
            // and moves the tab bar aside; arriving at the page must not do
            // that by itself. Re-tapping the tab, ⌘F and the intents still do.
            if new == .tab(.search), sizeClass != .regular { appModel.focusSearch = true }
            #else
            if new == .search { appModel.focusSearch = true }
            #endif
            _ = old
        }
        #if os(macOS)
        .frame(minWidth: 860, minHeight: 600)
        // A menu item that asks for the queue or the lyrics opens the inspector
        // — unless the full player is up, in which case it owns both panes and
        // answers the request itself.
        .onChange(of: appModel.queueRevealRequested) { _, requested in
            guard requested, !appModel.nowPlayingPresented else { return }
            macInspector = .queue
            appModel.queueRevealRequested = false
        }
        .onChange(of: appModel.lyricsRevealRequested) { _, requested in
            guard requested, !appModel.nowPlayingPresented else { return }
            macInspector = .lyrics
            appModel.lyricsRevealRequested = false
        }
        // An artist opened from the player's credit line is pushed on the
        // window's browse stack, so back returns to the page it covered.
        .onChange(of: appModel.pendingArtistPage) { _, destination in
            guard case .detail(let browseId, let title) = destination else { return }
            appModel.pendingArtistPage = nil
            navigator.path.append(PushRoute(id: UUID()) {
                AnyView(DetailView(browseId: browseId, initialTitle: title))
            })
        }
        #endif
        .preferredColorScheme(appModel.preferredScheme)
        .environment(\.locale, appModel.appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appModel.appLanguage))
        .overlay {
            // One host, at the top of the tree, so a notice raised from a sheet or
            // a context menu is never clipped by the view that raised it. Same
            // reason upstream puts `QueueActionNoticeHost` above everything else.
            ToastHost()
        }
        // Playback failures are reported here rather than as a banner inside each
        // feed. `lastError` is a *playback* error — "Audio engine failed to start"
        // has nothing to do with a feed that happened to be on screen — and it
        // used to be rendered as a hard-coded red bar at the top of Home,
        // Explore and Search results, which is both the wrong place and the wrong
        // severity for a transient failure.
        .onChange(of: controller.lastError) { _, message in
            guard let message, !message.isEmpty else { return }
            toast.show(message, kind: .failure)
        }
    }

    @ViewBuilder
    private var shell: some View {
        #if os(macOS)
        macShell
        #else
        contentStack
        .task(id: "\(auth.sessionEpoch)-\(sizeClass == .regular)") { await loadSidebarPlaylists() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryPlaylistsChanged)) { _ in
            Task { await loadSidebarPlaylists() }
        }
        .onChange(of: selection) { _, raw in
            if let tab = AppModel.Tab(rawValue: raw), Self.isLibrarySection(tab) {
                iPadLibraryTab = raw
            }
        }
        .environment(\.nowPlayingZoomNamespace, nowPlayingZoom)
        .modifier(NowPlayingTakeover(
            isPresented: Binding(
                get: { appModel.nowPlayingPresented },
                set: { appModel.nowPlayingPresented = $0 }
            ),
            zoomNamespace: nowPlayingZoom
        ))
        #endif
    }

    #if os(iOS)
    private var contentStack: some View {
        // Keep every tab and its navigation/scroll state mounted while Settings
        // covers it. Replacing tabShell recreates the feeds when returning.
        ZStack {
            tabShell
                .opacity(appModel.settingsPresented ? 0 : 1)
                .allowsHitTesting(!appModel.settingsPresented)
                .accessibilityHidden(appModel.settingsPresented)
            if appModel.settingsPresented {
                NavigationStack {
                    SettingsView(embedded: true)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { appModel.settingsPresented = false } label: {
                                    Label("Back", systemImage: "chevron.left")
                                }
                            }
                        }
                }
            }
        }
    }

    private func loadSidebarPlaylists() async {
        guard auth.signedIn, sizeClass == .regular else {
            sidebarPlaylists = []
            return
        }
        var seen = Set<String>()
        let owned = await LibraryActions.userPlaylists().filter { seen.insert($0.playlistId).inserted }
        // Liked Music heads the list, as it heads the Playlists page: YouTube's
        // own playlist of what was liked, which the account's list leaves out.
        sidebarPlaylists = (seen.contains(SidebarArtwork.likedMusicId) ? [] : [
            UserPlaylistDTO(playlistId: SidebarArtwork.likedMusicId, title: "Liked Music", subtitle: "", thumbnailUrl: nil)
        ]) + owned
        sidebarArtwork[SidebarArtwork.likedMusicId] = SidebarArtwork.likedMusic
        for playlist in sidebarPlaylists where sidebarArtwork[playlist.playlistId] == nil {
            guard let url = playlist.thumbnailUrl,
                  let art = await SidebarArtwork.load(url) else { continue }
            sidebarArtwork[playlist.playlistId] = art
        }
    }

    /// The tabs that are pages of the Library rather than tabs of their own.
    private static func isLibrarySection(_ tab: AppModel.Tab) -> Bool {
        tab.rawValue >= AppModel.Tab.libraryYouTube.rawValue
    }

    /// One of the library's sections, as the iPad's sidebar opens it.
    @ViewBuilder
    private func librarySection(_ section: AppModel.Tab) -> some View {
        Group {
            switch section {
            case .libraryPlaylists: LibraryView(lockedSection: .playlists)
            case .librarySongs: LibraryView(lockedSection: .songs)
            case .libraryAlbums: LibraryView(lockedSection: .albums)
            case .libraryArtists: LibraryView(lockedSection: .artists)
            case .librarySubscriptions: LibraryView(lockedSection: .subscriptions)
            case .libraryPodcasts: LibraryView(lockedSection: .podcasts)
            case .libraryOnDevice, .libraryDownloads: LibraryView(lockedSection: .ondevice)
            case .libraryHistory: LibraryView(lockedSection: .history)
            case .libraryWebDav: LibraryView(lockedSection: .webdav)
            default: LibraryView(lockedSection: .youtube)
            }
        }
        .historyStack(pageHistories.navigator(RootPage.tab(section)))
        .modifier(iPadPlaybackChrome())
    }

    /// The sidebar's Library rows: the sections of the phone's one Library page.
    private static let librarySections: [(tab: AppModel.Tab, title: LocalizedStringKey, symbol: String)] = [
        (.libraryYouTube, "Recent", "clock.arrow.circlepath"),
        (.librarySongs, "Songs", "music.note"),
        (.libraryAlbums, "Albums", "square.stack"),
        (.libraryArtists, "Artists", "music.mic"),
        (.libraryPlaylists, "Playlists", "music.note.list"),
        (.librarySubscriptions, "Subscriptions", "bell"),
        (.libraryPodcasts, "Podcasts", "radio"),
        (.libraryOnDevice, "On Device", "externaldrive"),
        (.libraryHistory, "History", "clock"),
    ]
    #endif

    #if os(macOS)
    /// The Mac window: a real sidebar, a detail column, and the full player over
    /// both.
    ///
    /// The sidebar is a `NavigationSplitView` rather than the adaptable
    /// `TabView` the iPad uses. That is not a style preference: a `TabView`'s
    /// sidebar is generated from its `Tab`s and cannot hold the listener's own
    /// playlists, which is exactly what Music puts there.
    private var macShell: some View {
        // Keep the split view mounted while the player covers the window:
        // removing it loses navigation paths, scroll offsets and local loaders.
        // The player is drawn in the split view's detail column with the
        // sidebar collapsed, not over the split view: over it, the window
        // toolbar kept the sidebar's column section and every player control
        // landed beside the traffic lights.
        macSplit
            .onChange(of: appModel.nowPlayingPresented) { _, presented in
                if presented {
                    columnsBeforePlayer = macColumns
                    macColumns = .detailOnly
                } else {
                    macColumns = columnsBeforePlayer
                }
            }
        .task(id: auth.sessionEpoch) { await loadMacPlaylists() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryPlaylistsChanged)) { _ in
            Task { await loadMacPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDeleted)) { note in
            // A deleted playlist's detail page cannot dismiss itself here — the
            // split view's detail column is not a stack — so the shell moves the
            // sidebar to Playlists, where the deletion is visible.
            guard let deleted = note.userInfo?["browseId"] as? String else { return }
            if case .playlist(let shown, _) = macSide, shown == deleted {
                navigator.replaceSide(.playlists)
                selection = MacSide.playlists.tab.rawValue
            }
        }
        .onAppear {
            // Reopen the row the window was left on.
            navigator.replaceSide(MacSide(tab: resolvedTab(AppModel.Tab(rawValue: selection) ?? .home)))
        }
    }

    private var macSplit: some View {
        NavigationSplitView(columnVisibility: $macColumns) {
            macSidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } detail: {
            ZStack {
            HStack(spacing: 0) {
                // One stack for every row, bound to the window's history, so
                // back and forward cover a page opened on any of them.
                // While the player is up the stack is shown its root alone: a
                // pushed page is hosted above the rest of the detail column,
                // so it stayed on screen over the player, with the sidebar and
                // titlebar already hidden and no way back. The window's history
                // is untouched; the pages return when the player closes.
                NavigationStack(path: Binding(
                    get: { appModel.nowPlayingPresented ? [] : navigator.path },
                    set: { if !appModel.nowPlayingPresented { navigator.path = $0 } }
                )) {
                    macDetail
                        .modifier(MacPillInset())
                        .navigationDestination(for: PushRoute.self) { route in
                            route.make()
                                .modifier(MacPillInset())
                                // The titlebar's own back button is the way back.
                                .navigationBarBackButtonHidden(true)
                        }
                }
                .environment(\.inBrowseStack, true)
                // Lyrics and the queue sit beside the library as a plain
                // column. The system inspector vends toolbar items of its own,
                // and the window's toolbar fix-up answering them looped until
                // AppKit killed the app.
                if let kind = macInspector {
                    Divider()
                    MacInspectorPane(kind: kind)
                        .frame(width: 340)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: macInspector)
            .environment(\.macInspectorSelection, $macInspector)
            // Kept mounted under the player: removing it loses navigation
            // paths, scroll offsets and local loaders.
            .opacity(appModel.nowPlayingPresented ? 0 : 1)
            .allowsHitTesting(!appModel.nowPlayingPresented)
            .accessibilityHidden(appModel.nowPlayingPresented)
            if appModel.nowPlayingPresented {
                NowPlayingView()
            }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .topLeading) {
            MacWindowToolbar(isPlayerPresented: appModel.nowPlayingPresented)
                .frame(width: 0, height: 0)
        }
        .toolbar {
            if !appModel.nowPlayingPresented {
                ToolbarItem(placement: .navigation) {
                    MacHistoryButtons(navigator: navigator)
                }
                // Pages with their own trailing primaryAction items append
                // MacWindowControls after them so Profile and Downloads stay
                // at the right-most end of the titlebar.
                if !macSide.hostsOwnToolbarControls || !navigator.path.isEmpty {
                    MacWindowControls()
                }
            }
        }
    }

    private var macSidebar: some View {
        List(selection: macSideBinding) {
            Section {
                sideRow(.home, "Home", "house")
                sideRow(.explore, "Explore", "square.grid.2x2")
                // Music keeps Search with the top-level destinations.
                sideRow(.search, "Search", "magnifyingglass")
            }
            Section("Library") {
                sideRow(.recent, "Recent", "clock.arrow.circlepath")
                sideRow(.songs, "Songs", "music.note")
                sideRow(.albums, "Albums", "square.stack")
                sideRow(.artists, "Artists", "music.mic")
                sideRow(.playlists, "Playlists", "music.note.list")
                sideRow(.subscriptions, "Subscriptions", "bell")
                sideRow(.podcasts, "Podcasts", "radio")
                sideRow(.onDevice, "On Device", "externaldrive")
                sideRow(.history, "History", "clock")
                if WebDavStore.shared.isConfigured {
                    sideRow(.webdav, "WebDAV", "cloud")
                }
            }
            // Music's own section. It is the reason this sidebar is a split view:
            // the adaptable TabView could not draw it.
            if !macPlaylists.isEmpty {
                Section("Playlists") {
                    ForEach(macPlaylists) { playlist in
                        // Each playlist by its own artwork, as the iPad's
                        // sidebar shows them, rather than one shared glyph.
                        Label {
                            Text(playlist.title)
                        } icon: {
                            ArtworkView(url: playlist.thumbnailUrl, data: nil, side: 20)
                                .frame(width: 20, height: 20)
                                .clipShape(.rect(cornerRadius: 4, style: .continuous))
                        }
                        .tag(MacSide.playlist(id: playlist.browseId, title: playlist.title))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("BitChord")
    }

    private func sideRow(_ side: MacSide, _ title: LocalizedStringKey, _ icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            // The glyph takes the text's colour, as Music's sidebar draws it;
            // the system's sidebar tint is the accent blue.
            Image(systemName: icon)
                .foregroundStyle(macSide == side ? Color.white : Color.primary)
        }
        .tag(side)
    }

    @ViewBuilder
    private var macDetail: some View {
        switch macSide {
        case .home:
            HomeView(feed: homeFeed, scrollPosition: $homeScroll)
        case .explore:
            ExploreView()
        case .recent:
            LibraryView(lockedSection: .youtube)
        case .songs:
            LibraryView(lockedSection: .songs, hostsWindowControls: navigator.path.isEmpty)
        case .albums:
            LibraryView(lockedSection: .albums, hostsWindowControls: navigator.path.isEmpty)
        case .artists:
            LibraryView(lockedSection: .artists, hostsWindowControls: navigator.path.isEmpty)
        case .playlists:
            LibraryView(lockedSection: .playlists, hostsWindowControls: navigator.path.isEmpty)
        case .subscriptions:
            LibraryView(lockedSection: .subscriptions)
        case .podcasts:
            LibraryView(lockedSection: .podcasts)
        case .onDevice:
            LibraryView(lockedSection: .ondevice)
        case .history:
            LibraryView(lockedSection: .history)
        case .webdav:
            LibraryView(lockedSection: .webdav)
        case .search:
            SearchView(
                showsMacToolbar: navigator.path.isEmpty && !appModel.nowPlayingPresented,
                hostsWindowControls: navigator.path.isEmpty && !appModel.nowPlayingPresented
            )
        case .playlist(let id, let title):
            DetailView(browseId: id, initialTitle: title)
        }
    }

    private var macSideBinding: Binding<MacSide> {
        Binding(
            get: { macSide },
            set: { side in
                // Same rule as the iPhone tabs: arriving at Search puts the
                // cursor in its field.
                if side == .search { appModel.focusSearch = true }
                macSide = side
                selection = side.tab.rawValue
            }
        )
    }

    private func loadMacPlaylists() async {
        guard auth.signedIn else {
            macPlaylists = []
            return
        }
        // One row per playlist id: the list can repeat one (ForEach then draws
        // it more than once), while two playlists may share a title.
        var seen = Set<String>()
        macPlaylists = await LibraryActions.userPlaylists().filter { seen.insert($0.playlistId).inserted }
    }
    #endif

    #if os(iOS)
    /// What the iPad's tabs and sidebar rows select: one of the tabs, or one of
    /// the listener's playlists, which each have a sidebar row of their own.
    enum RootPage: Hashable {
        case tab(AppModel.Tab)
        case playlist(String)
    }

    private var tabShell: some View {
        TabView(selection: tabBinding) {
            if sizeClass == .regular {
                // The system's adaptable sidebar, as Music has it: the toggle at
                // the head of the top tab bar opens it, and the one in it closes
                // it. The bar shows Home, Explore, the Library section and Search;
                // the playlists are the sidebar's alone.
                Tab("Home", systemImage: "house.fill", value: RootPage.tab(.home)) {
                    HomeView(feed: homeFeed)
                        .historyStack(pageHistories.navigator(RootPage.tab(.home)))
                        .modifier(iPadPlaybackChrome())
                }
                Tab("Explore", systemImage: "square.grid.2x2.fill", value: RootPage.tab(.explore)) {
                    ExploreView()
                        .historyStack(pageHistories.navigator(RootPage.tab(.explore)))
                        .modifier(iPadPlaybackChrome())
                }
                TabSection("Library") {
                    ForEach(Self.librarySections, id: \.tab) { section in
                        Tab(section.title, systemImage: section.symbol, value: RootPage.tab(section.tab)) {
                            librarySection(section.tab)
                        }
                    }
                    if WebDavStore.shared.isConfigured {
                        Tab("WebDAV", systemImage: "cloud", value: RootPage.tab(.libraryWebDav)) {
                            librarySection(.libraryWebDav)
                        }
                    }
                }
                Tab("Search", systemImage: "magnifyingglass", value: RootPage.tab(.search), role: .search) {
                    SearchView()
                        .historyStack(pageHistories.navigator(RootPage.tab(.search)))
                        .modifier(iPadPlaybackChrome())
                }
                // The listener's own playlists, each by its own artwork, as the
                // Mac's sidebar has them. Sidebar rows only: each opens inside
                // Library > Playlists.
                TabSection("Playlists") {
                    ForEach(sidebarPlaylists) { playlist in
                        Tab(value: RootPage.playlist(playlist.playlistId)) {
                            // Passed through: choosing the row opens the
                            // playlist in Library > Playlists (`tabBinding`).
                            Color.clear
                        } label: {
                            Label {
                                Text(playlist.title)
                            } icon: {
                                if let art = sidebarArtwork[playlist.playlistId] {
                                    Image(uiImage: art).renderingMode(.original)
                                } else {
                                    Image(systemName: "music.note.list")
                                }
                            }
                        }
                        .customizationID("bitchord.sidebar.playlist.\(playlist.playlistId)")
                        .tabPlacement(.sidebarOnly)
                    }
                }
                .customizationID("bitchord.sidebar.playlists")
                .defaultVisibility(.hidden, for: .tabBar)
            } else {
                Tab("Home", systemImage: "house.fill", value: RootPage.tab(.home)) {
                    HomeView(feed: homeFeed)
                }
                Tab("Explore", systemImage: "square.grid.2x2.fill", value: RootPage.tab(.explore)) {
                    ExploreView()
                }
                Tab("Library", systemImage: "square.stack.fill", value: RootPage.tab(.library)) {
                    LibraryView()
                }
                Tab("Search", systemImage: "magnifyingglass", value: RootPage.tab(.search), role: .search) {
                    SearchView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .toolbar {
            if (AppModel.Tab(rawValue: selection) ?? .home) != .search {
                ToolbarItem(placement: .topBarTrailing) { TopBarSearchButton() }
            }
        }
        .tabViewCustomization($tabCustomization)
        .onAppear {
            SidebarSelectionGuard.shared.onPlaylist = { index in
                if sidebarPlaylists.indices.contains(index) { openSidebarPlaylist(sidebarPlaylists[index].playlistId) }
            }
        }
        .tabViewSidebarBottomBar { IPadSidebarFooter() }
        .modifier(PlaybackPillMount())
    }
    #endif

    #if os(iOS)
    private var tabBinding: Binding<RootPage> {
        Binding(
            get: {
                if let passing = passingPlaylist { return .playlist(passing) }
                return .tab(resolvedTab(AppModel.Tab(rawValue: selection) ?? .home))
            },
            set: { page in
                guard case .tab(let newTab) = page else {
                    // Normally refused before it gets here (SidebarSelectionGuard).
                    // If it does arrive, the selection rests on the row for one
                    // turn: handing the `TabView` back the value it already had
                    // would leave it on the row's empty page.
                    if case .playlist(let id) = page {
                        passingPlaylist = id
                        Task { @MainActor in
                            passingPlaylist = nil
                            openSidebarPlaylist(id)
                        }
                    }
                    return
                }
                if sizeClass == .regular, newTab == .library {
                    selection = iPadLibraryTab
                    return
                }
                Self.noteSearchRetap(newTab, current: resolvedTab(AppModel.Tab(rawValue: selection) ?? .home), appModel: appModel)
                selection = newTab.rawValue
            }
        )
    }

    /// Opens a sidebar playlist inside Library > Playlists, pushed on that tab's
    /// history so back returns to the list.
    private func openSidebarPlaylist(_ id: String) {
        guard let playlist = sidebarPlaylists.first(where: { $0.playlistId == id }) else { return }
        pageHistories.navigator(RootPage.tab(.libraryPlaylists)).path = [PushRoute(id: UUID()) {
            AnyView(DetailView(browseId: playlist.browseId, initialTitle: playlist.title))
        }]
        selection = AppModel.Tab.libraryPlaylists.rawValue
    }
    #else
    private var tabBinding: Binding<AppModel.Tab> {
        Binding(
            get: { resolvedTab(AppModel.Tab(rawValue: selection) ?? .home) },
            set: { newTab in
                Self.noteSearchRetap(newTab, current: resolvedTab(AppModel.Tab(rawValue: selection) ?? .home), appModel: appModel)
                selection = newTab.rawValue
            }
        )
    }
    #endif

    /// Upstream's `searchFocusTrigger`: re-tapping the tab that is already
    /// selected focuses its search field rather than doing nothing. A `TabView`
    /// cannot tell a re-tap from a no-op tap on its own — the binding's setter
    /// only sees the value it is being set to — so the "same tab again" case is
    /// recognised here.
    ///
    /// Only Search, because a field is the only thing on any of the other tabs
    /// that a re-tap could reasonably mean. A re-tap that scrolled Home to the
    /// top or popped the Library back would be inventing behaviour nobody asked
    /// for.
    private static func noteSearchRetap(_ tab: AppModel.Tab, current: AppModel.Tab, appModel: AppModel) {
        if tab == .search, tab == current { appModel.searchFocusTrigger &+= 1 }
    }

    private func resolvedTab(_ tab: AppModel.Tab) -> AppModel.Tab {
        #if os(macOS)
        if tab == .library { return .libraryYouTube }
        return tab
        #else
        if sizeClass == .regular {
            if tab == .library { return AppModel.Tab(rawValue: iPadLibraryTab) ?? .libraryYouTube }
            // A playlist chosen in an earlier launch is not remembered; its list is.
            if tab == .sidebarPlaylist { return .libraryPlaylists }
            return tab
        }
        // The phone has one Library page; a section chosen on the iPad (or by a
        // deep link) lands there.
        return Self.isLibrarySection(tab) ? .library : tab
        #endif
    }
}

#if os(macOS)
/// What the Mac sidebar can select: a destination, or one of the listener's own
/// playlists.
enum MacSide: Hashable {
    case home, explore, recent, songs, albums, artists, playlists
    case subscriptions, podcasts, onDevice, history, webdav, search
    case playlist(id: String, title: String)

    /// A deep link or a menu item names one of the canonical tabs; the sidebar
    /// has one row for each of them.
    init(tab: AppModel.Tab) {
        switch tab {
        case .home: self = .home
        case .explore: self = .explore
        case .library, .libraryYouTube: self = .recent
        case .librarySongs: self = .songs
        case .libraryAlbums: self = .albums
        case .libraryArtists: self = .artists
        case .libraryPlaylists, .sidebarPlaylist: self = .playlists
        case .librarySubscriptions: self = .subscriptions
        case .libraryPodcasts: self = .podcasts
        // Downloads are listed inside On Device, which is where a download
        // lands, so that tab is the row they belong to.
        case .libraryOnDevice, .libraryDownloads: self = .onDevice
        case .libraryHistory: self = .history
        case .libraryWebDav: self = .webdav
        case .search: self = .search
        }
    }

    /// The canonical tab to remember this row as, in the same scene storage the
    /// iOS tabs use, so the Mac reopens where it was left.
    var tab: AppModel.Tab {
        switch self {
        case .home: .home
        case .explore: .explore
        case .recent: .libraryYouTube
        case .songs: .librarySongs
        case .albums: .libraryAlbums
        case .artists: .libraryArtists
        case .playlists, .playlist: .libraryPlaylists
        case .subscriptions: .librarySubscriptions
        case .podcasts: .libraryPodcasts
        case .onDevice: .libraryOnDevice
        case .history: .libraryHistory
        case .webdav: .libraryWebDav
        case .search: .search
        }
    }

    var hostsOwnToolbarControls: Bool {
        switch self {
        case .search, .songs, .albums, .artists, .playlists:
            true
        default:
            false
        }
    }
}

/// Configure the system-generated toolbar items without creating another
/// sidebar button. TabView puts its toggle in the sidebar's toolbar section;
/// that section can have no room for it when the sidebar is collapsed.
private struct MacWindowToolbar: NSViewRepresentable {
    let isPlayerPresented: Bool

    func makeNSView(context: Context) -> MacWindowToolbarView { MacWindowToolbarView() }
    func updateNSView(_ nsView: MacWindowToolbarView, context: Context) {
        nsView.setPlayerPresented(isPlayerPresented)
    }
}

private final class MacWindowToolbarView: NSView {
    private var isPlayerPresented = false
    private var wasPlayerPresented = false
    private var normalItems: [NSToolbarItem.Identifier: Bool] = [:]
    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false
    private var isConfiguring = false

    func setPlayerPresented(_ presented: Bool) {
        guard isPlayerPresented != presented else { return }
        isPlayerPresented = presented
        scheduleUpdate()
        for delay in [0.05, 0.15, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.configureToolbar()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard let window else { return }
        for name in [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, !self.isConfiguring, (note.object as? NSToolbar) === self.window?.toolbar else { return }
                self.scheduleUpdate()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.scheduleUpdate()
        })
        scheduleUpdate()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func scheduleUpdate() {
        guard window != nil, !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.configureToolbar()
        }
    }

    private func configureToolbar() {
        guard let toolbar = window?.toolbar, !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }
        if isPlayerPresented {
            // Spacing and window-level controls stay visible; browse controls
            // and the sidebar toggle are hidden while the player owns the window.
            for item in toolbar.items where (normalItems[item.itemIdentifier] != nil || Self.isSidebarToggle(item))
                && !Self.isSpacing(item)
                && !Self.isWindowControl(item) {
                item.isHidden = true
            }
        } else {
            if wasPlayerPresented {
                for item in toolbar.items {
                    if let hidden = normalItems[item.itemIdentifier] { item.isHidden = hidden }
                }
            }
            // The sidebar toggle belongs in the sidebar's own titlebar, beside
            // the traffic lights, as in Music and Finder — not floating at the
            // head of the content column. Keep SwiftUI's own control and
            // action: reinserting its identifier asks the window's existing
            // toolbar delegate for the same item.
            if let toggleIndex = toolbar.items.firstIndex(where: Self.isSidebarToggle),
               let dividerIndex = toolbar.items.firstIndex(where: {
                   $0 is NSTrackingSeparatorToolbarItem
               }), toggleIndex > dividerIndex {
                let identifier = toolbar.items[toggleIndex].itemIdentifier
                toolbar.removeItem(at: toggleIndex)
                toolbar.insertItem(withItemIdentifier: identifier, at: dividerIndex)
            }
            if let toggle = toolbar.items.first(where: Self.isSidebarToggle) {
                toggle.visibilityPriority = .user
            }
            normalItems = Dictionary(toolbar.items.map { ($0.itemIdentifier, $0.isHidden) }, uniquingKeysWith: { first, _ in first })
        }
        wasPlayerPresented = isPlayerPresented
    }

    private static func isSpacing(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == .flexibleSpace || item.itemIdentifier == .space
            || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("spacer")
            || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("space")
    }

    private static func isWindowControl(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier.rawValue == MacToolbarItemID.account
            || item.itemIdentifier.rawValue == MacToolbarItemID.downloads
    }

    private static func isSidebarToggle(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == .toggleSidebar
            || item.itemIdentifier.rawValue.hasSuffix(".toggleSidebar")
    }
}
#endif

/// The shared playback pill (UI spec §3.1/§3.2): `.tabViewBottomAccessory` on
/// iOS 26 — Music's own bottom accessory — with a material `safeAreaInset`
/// fallback below that floor. Same view, mounted per platform.
///
/// The accessory is tab-level, so it is unaffected by iPad sidebar
/// collapse/expand; inset mounting broke that and overlapped the tab bar.
struct PlaybackPillMount: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The keyboard covers the tab bar, and the accessory with it, so while it
    /// is up the iPhone's pill rides on top of it instead (the iPad's per-tab
    /// inset does that on its own).
    @State private var keyboardUp = false
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if sizeClass == .regular {
            // An iPad mounts per tab (iPadPlaybackChrome), on every version.
            // Since the sidebar became IPadSidebar's push column, the TabView
            // is `.tabBarOnly`, and the system bottom accessory draws its own
            // glass bar across the whole content width — framing the pill
            // inside it only centred the controls in a full-width bar. The
            // per-tab inset sits in the content column, so it reflows with
            // the sidebar and keeps Music's 620 pt width.
            content
        } else if #available(iOS 26.0, *) {
            // iPhone from 26: Music's own bottom accessory, full width. A scroll
            // down minimizes the tab bar and the pill drops into it, between
            // the selected tab and Search.
            accessory(content.tabBarMinimizeBehavior(.onScrollDown))
                .overlay(alignment: .bottom) {
                    if keyboardUp {
                        PlaybackPill()
                            // The accessory's glass is the tab bar's; out here
                            // the pill would otherwise have none.
                            .chromeGlass(in: Capsule())
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    withAnimation(.smooth(duration: 0.25)) { keyboardUp = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    withAnimation(.smooth(duration: 0.25)) { keyboardUp = false }
                }
        } else {
            fallbackMount(content)
        }
        #else
        // macOS mounts the pill on the detail column (`macSplit`), so it
        // floats over the content rather than across the sidebar.
        content
        #endif
    }

    #if os(iOS)
    /// The bottom accessory, stood down from 26.1 while the pill rides the
    /// keyboard, so there is only ever one pill (and one zoom source for Now
    /// Playing). On 26.0 the covered one stays mounted.
    @available(iOS 26.0, *)
    @ViewBuilder
    private func accessory(_ content: some View) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: !keyboardUp) {
                PlaybackAccessory()
            }
        } else {
            content.tabViewBottomAccessory {
                PlaybackAccessory()
            }
        }
    }

    private func fallbackMount(_ content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            PlaybackPill()
                // Clamped to 720pt so it centers elegantly on iPad while taking
                // natural width on iPhone.
                .frame(maxWidth: 720)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
        }
    }
    #endif
}

#if os(iOS)
/// The pill in the iPhone's bottom accessory, told whether the minimized tab
/// bar has it inline.
@available(iOS 26.0, *)
private struct PlaybackAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        PlaybackPill(inline: placement == .inline)
    }
}

/// iPad per-tab pill mount. Lives inside the detail column so sidebar
/// collapse/expand reflows it and it stays centered on the main view. Content-sized at 620pt like Music's
/// compact pill instead of the full-width stretch of the tab-level
/// accessory container. No-op on iPhone, which mounts once at the TabView.
struct iPadPlaybackChrome: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        pill(content)
            .background { if sizeClass == .regular { SidebarSelectionGuardInstaller() } }
            // The search pill takes the tab bar's place while it is open.
            .toolbar(appModel.iPadSearchExpanded ? .hidden : .automatic, for: .tabBar)
    }

    @ViewBuilder
    private func pill(_ content: Content) -> some View {
        // Every iOS version: the system bottom accessory spans the whole
        // content width on iPad (see PlaybackPillMount).
        if sizeClass == .regular {
            content.safeAreaInset(edge: .bottom) {
                PlaybackPill()
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
            }
        } else {
            content
        }
    }
}
#endif

#if os(iOS)
/// iPhone: a large swipe-to-dismiss sheet that zooms out of the mini player
/// (WWDC 323 `MusicPlaybackView` pattern). iPad: a page-sized sheet.
struct NowPlayingTakeover: ViewModifier {
    @Binding var isPresented: Bool
    var zoomNamespace: Namespace.ID
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        Group {
            if sizeClass == .regular {
                // Full screen, unconditionally: `.page` sheet sizing renders
                // as a floating card on iPadOS 27, and only a cover is
                // guaranteed edge to edge.
                content.fullScreenCover(isPresented: $isPresented) {
                    NowPlayingView()
                        .navigationTransition(.zoom(sourceID: NowPlayingZoom.sourceID, in: zoomNamespace))
                }
            } else {
                content.sheet(isPresented: $isPresented) {
                    NowPlayingView()
                        .modifier(NowPlayingSheetSizing())
                        .navigationTransition(.zoom(sourceID: NowPlayingZoom.sourceID, in: zoomNamespace))
                }
            }
        }
    }
}

private struct NowPlayingSheetSizing: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                .presentationDetents([.large])
                .presentationSizing(.page)
                .presentationDragIndicator(.visible)
        } else {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }
}

enum NowPlayingZoom {
    static let sourceID = "now-playing"
}

private struct NowPlayingZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var nowPlayingZoomNamespace: Namespace.ID? {
        get { self[NowPlayingZoomNamespaceKey.self] }
        set { self[NowPlayingZoomNamespaceKey.self] = newValue }
    }
}
#endif
