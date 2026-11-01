import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared

/// One recent search, stored as an entity rather than a raw query string:
/// the exact identity (id, artwork, type) of what was tapped, so recents
/// render with real cover art and tapping one navigates straight to it
/// instead of re-running a text search. Port of upstream `SearchHistoryEntity`.
struct RecentSearchEntity: Codable, Identifiable, Hashable {
    /// videoId for tracks, browseId for collections, `q:<query>` for raw text.
    var id: String
    var title: String
    var subtitle: String
    var artworkUrl: String?
    /// TRACK, ALBUM, ARTIST, PLAYLIST or QUERY.
    var entityType: String
    var timestamp: Int64

    init(id: String, title: String, subtitle: String = "", artworkUrl: String? = nil, entityType: String = "QUERY") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkUrl = artworkUrl
        self.entityType = entityType
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    }

    var typeLabel: String {
        switch entityType.uppercased() {
        case "TRACK": return "Song"
        case "ALBUM": return "Album"
        case "ARTIST": return "Artist"
        case "PLAYLIST": return "Playlist"
        default: return subtitle.isEmpty ? "Search" : subtitle
        }
    }
}

/// Device-only recent searches, kept under the existing `search_history` key.
/// Reads the legacy `[String]` list and migrates each query to a QUERY entity
/// on first write, so an update never drops what was searched before.
enum RecentSearchStore {
    private static let key = "search_history"
    private static let maxEntries = 20

    static func load() -> [RecentSearchEntity] {
        let raw = PlatformSettings.shared.getString(key: key, default: "[]")
        guard let data = raw.data(using: .utf8) else { return [] }
        if let entities = try? JSONDecoder().decode([RecentSearchEntity].self, from: data) {
            // A legacy `["query"]` list fails this decode and falls through;
            // `[]` decodes either way and is empty either way.
            return entities
        }
        let legacy = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return legacy.map { RecentSearchEntity(id: "q:\($0.lowercased())", title: $0) }
    }

    static func record(_ entity: RecentSearchEntity) {
        var list = load().filter { !$0.id.equalsIgnoringCase(entity.id) }
        var fresh = entity
        fresh.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        list.insert(fresh, at: 0)
        save(Array(list.prefix(maxEntries)))
    }

    static func remove(id: String) {
        save(load().filter { !$0.id.equalsIgnoringCase(id) })
    }

    static func clear() { save([]) }

    private static func save(_ list: [RecentSearchEntity]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        PlatformSettings.shared.putString(key: key, value: json)
    }
}

private extension String {
    func equalsIgnoringCase(_ other: String) -> Bool {
        compare(other, options: .caseInsensitive) == .orderedSame
    }
}

/// The words the Addons tab has searched, newest first. Kept apart from the
/// entity-based recents because there is no song behind them — upstream keeps
/// them in their own list for the same reason.
enum AddonSearchHistory {
    private static let key = "addon_search_history"
    private static let maxEntries = 20

    static func load() -> [String] {
        guard let data = PlatformSettings.shared.getString(key: key, default: "[]").data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func record(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        var list = load().filter { $0.compare(term, options: .caseInsensitive) != .orderedSame }
        list.insert(term, at: 0)
        save(Array(list.prefix(maxEntries)))
    }

    static func remove(_ query: String) {
        save(load().filter { $0.compare(query, options: .caseInsensitive) != .orderedSame })
    }

    static func clear() { save([]) }

    private static func save(_ list: [String]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        PlatformSettings.shared.putString(key: key, value: json)
    }
}

/// The titlebar's YouTube / Library / Addons switcher, on the Mac and a regular-width
/// iPad.
///
/// The system's own segmented control rather than a hand-drawn capsule: in a
/// toolbar from macOS / iPadOS 26 it is drawn as one Liquid Glass pill with
/// the chosen segment inset inside it, the way Music's own titlebar switchers
/// are. A custom capsule sat inside the toolbar's glass platter and read as a
/// pill within a pill. `fixedSize` keeps the toolbar from stretching it.
struct ToolbarSearchSourceSwitcher: View {
    @Binding var selection: SearchView.SearchSource

    var body: some View {
        Picker("Search source", selection: $selection) {
            ForEach(SearchView.SearchSource.allCases) { source in
                Text(source.label).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        #if os(macOS)
        .help("Search YouTube Music, your library or your addons")
        #endif
    }
}

#if os(macOS)
/// The Mac titlebar's search field, placed as a first-class `ToolbarItem` so
/// SwiftUI owns the exact trailing order: search pill, YouTube/Addons switcher,
/// account and Downloads.
///
/// Relying on `.searchable(placement: .toolbar)` puts the field in a separate
/// `com.apple.SwiftUI.search` toolbar slot at the far right after every
/// `primaryAction` item, and mutating `NSToolbar` behind SwiftUI's back to
/// reorder it caused SwiftUI to reconcile the toolbar on every view update and
/// flicker the controls.
private struct MacToolbarSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 28)
        .contentShape(.rect)
        .onTapGesture {
            focused.wrappedValue = true
        }
    }
}
#else
/// The iPad top bar's search control, placed as a first-class `ToolbarItem`
/// just ahead of the YouTube / Library / Addons switcher.
///
/// Collapsed it is a round search button: a full pill does not fit at a
/// readable width between the switcher and the floating tab bar. Tapped, the
/// tab bar steps aside first (the App Store's search does the same) and the
/// button then grows leftwards into the pill; closing runs the other way.
///
/// The item draws its own glass. The toolbar's platter snaps to an item's new
/// size instead of animating it, so the slot is widened to the pill's width
/// first (`roomy`, invisible: the glass is still the button's circle, pinned
/// trailing) and only then is the glass itself animated open. The field is
/// built with the slot, before the glass moves, and focused only once it has
/// stopped: raising the keyboard mid-animation stalled the pill in its tracks.
///
/// `side` is the source switcher's measured height, so the button, the pill
/// and the switcher stand the same height in the bar.
private struct IPadToolbarSearchPill: View {
    static let openWidth: CGFloat = 300

    @Binding var text: String
    let side: CGFloat
    let roomy: Bool
    let open: Bool
    var focused: FocusState<Bool>.Binding
    var onExpand: () -> Void
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: open ? 8 : 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(open ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                // Collapsed, the glass is the button; open, the field speaks
                // for itself.
                .accessibilityLabel("Search")
                .accessibilityAddTraits(.isButton)
                .accessibilityHidden(open)
            if roomy {
                TextField("Artists, Songs, Lyrics, and More", text: $text)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused(focused)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .frame(maxWidth: open ? .infinity : 0)
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
            if open {
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, open ? 14 : 0)
        .frame(width: open ? Self.openWidth : side, height: side)
        .chromeGlass(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            if open {
                focused.wrappedValue = true
            } else {
                onExpand()
            }
        }
        .frame(width: roomy ? Self.openWidth : side, alignment: .trailing)
    }
}

/// A row pinned under the top bar, over the page's own scrolling content: a
/// bar of its own from iOS 26, so content passing under it gets the bar's edge
/// effect rather than running into the row.
private struct TopRow<Row: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder var row: Row

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .top, spacing: 0) { row }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { row.background(.bar) }
        }
    }
}

private struct CompactPhoneSearchDrawer: ViewModifier {
    let isCompact: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCompact {
            content
                .searchable(
                    text: $query,
                    isPresented: $isPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Artists, Songs, Lyrics, and More"
                )
                .searchFocused(focused)
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}
#endif

struct SearchView: View {
    /// Upstream `TYPEAHEAD_MAX_RESULTS` in MainViewModel.kt.
    private static let typeaheadMaxResults = 15
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(AuthController.self) private var auth
    #if os(macOS)
    /// Settings is a scene on the Mac, not an in-app cover.
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var query = ""
    private let initialQuery: String?
    @State private var categories = MoodGenreLoader()
    @State private var historyRevision = 0
    /// Starts on the mixed page, which is what YouTube Music opens on and the only
    /// one that promotes a card. A first search should answer the question rather
    /// than hand back a list.
    @State private var scope: Scope = .all
    @State private var searching = false
    @State private var hits: [SearchHitDTO] = []
    @State private var suggestions: [String] = []
    @State private var searchError: String?
    @State private var attempted = false
    @State private var isSearchPresented = false
    /// Focus for the native search field, including tab reselect and deep links.
    @FocusState private var searchFieldFocused: Bool
    @State private var suggestTask: Task<Void, Never>?
    /// Live media rows for the typeahead dropdown, fetched in parallel with the
    /// text suggestions on its own, longer debounce (upstream's
    /// `TYPEAHEAD_MEDIA_DEBOUNCE_MS`).
    @State private var typeaheadHits: [SearchHitDTO] = []
    @State private var typeaheadTask: Task<Void, Never>?
    /// The in-flight search, so leaving the screen or starting a new one can
    /// abandon it. Without a handle the late answer from an abandoned search
    /// writes its results into whatever the screen is showing by then.
    @State private var searchTask: Task<Void, Never>?
    /// Bumped per request to give the results list a new identity, which is what
    /// puts a new result set at the top instead of at the old one's offset.
    @State private var requestToken = 0
    /// The term the results on screen are actually for.
    ///
    /// Not the same as `query`, and the difference is load-bearing: `query` is
    /// what the field says, and the moment it differs from this the results below
    /// are for a search nobody asked for any more. Judging "is the user still
    /// editing" off the suggestions alone got this wrong in two directions — a
    /// one-character edit left the old results up under a shorter query, and
    /// editing after a search never offered completions again.
    @State private var searchedTerm = ""
    /// The token for the next page of the committed search, null once the
    /// result set is exhausted or no search has run.
    @State private var searchContinuationToken: String?
    /// True while a continuation page is in flight, so the end-of-list sentinel
    /// doesn't fire a second request for the same token.
    @State private var loadingMore = false
    /// Which catalogue the field answers: YouTube Music, or the addons the
    /// listener enabled. Upstream's YouTube / Addons switcher.
    @State private var searchSource: SearchSource = .youtube
    @State private var addonHits: [SearchHitDTO] = []
    @State private var addonError: String?
    @State private var searchingAddons = false
    @State private var addonHistory: [String] = AddonSearchHistory.load()
    /// How many addons are enabled, so the Addons tab can say "no addons yet"
    /// before a query has to fail to prove it.
    @State private var addonCount = 0
    /// The Library source's catalogue: the signed-in library's songs and its
    /// albums / artists / playlists shelves, loaded once the source is picked.
    /// The device's scanned songs come straight from `LocalLibrary`.
    @State private var librarySongs: [YouTubeSong] = []
    @State private var libraryShelves: [FeedShelf] = []
    @State private var libraryLoading = false
    @State private var libraryError: String?
    @State private var local = LocalLibrary.shared
    /// The iPad pill's two steps; see `setIPadSearchExpanded`.
    @State private var pillRoomy = false
    @State private var pillOpen = false
    @State private var pillGeneration = 0
    /// The iPad source switcher's height in the bar, which the pill matches.
    @State private var switcherHeight: CGFloat = 47
    /// The page's width. Narrow (an iPad in portrait), the top bar has no room
    /// for the switcher beside the tab bar and iPadOS folds it into a "⋯" menu,
    /// so it moves to the title's row instead, opposite the title.
    @State private var pageWidth: CGFloat = 0
    private var switcherInBar: Bool { pageWidth == 0 || pageWidth >= 1040 }
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    private let showsMacToolbar: Bool
    private let hostsWindowControls: Bool

    init(
        initialQuery: String? = nil,
        initialScope: Scope = .all,
        initialSource: SearchSource = .youtube,
        showsMacToolbar: Bool = true,
        hostsWindowControls: Bool = false
    ) {
        self.initialQuery = initialQuery
        self.showsMacToolbar = showsMacToolbar
        self.hostsWindowControls = hostsWindowControls
        _query = State(initialValue: initialQuery ?? "")
        _scope = State(initialValue: initialScope)
        _searchSource = State(initialValue: initialSource)
    }

    /// Which catalogue the field answers: YouTube Music, the listener's own
    /// library, or their addons, as upstream's three-way switcher does.
    /// Upstream's Library is the Local Music folder alone; ours also holds the
    /// signed-in library, so this one searches both.
    enum SearchSource: String, CaseIterable, Identifiable, Codable {
        case youtube, library, addons
        var id: String { rawValue }
        var label: String {
            switch self {
            case .youtube: return "YouTube"
            case .library: return "Library"
            case .addons: return "Addons"
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable, Codable {
        /// YouTube Music's mixed page — the only one with a promoted card, and so
        /// the only one a top result is shown for.
        case all, songs, videos, albums, artists, playlists

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .videos: return "Videos"
            default: return rawValue.capitalized
            }
        }

        /// Whether a promoted card is worth looking for on this tab.
        ///
        /// A "Songs" search is already entirely songs, and a heading above a list
        /// of the same rows adds nothing.
        var showsTopResult: Bool { self == .all }
    }

    var body: some View {
        PageStack {
            resultsColumn
                .navigationTitle("Search")
                .toolbar {
                    #if os(iOS)
                    TopBarLeadingItems()
                    if horizontalSizeClass == .regular {
                        // iPad: the top bar carries the search button (the
                        // pill, once open) and then the YouTube / Library /
                        // Addons switcher, separated into two distinct glass
                        // pills with a fixed toolbar spacer so iPadOS does not
                        // merge adjacent trailing items into a single platter.
                        if #available(iOS 26.0, *) {
                            ToolbarItem(placement: .topBarTrailing) { iPadSearchPill }
                                .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .topBarTrailing) { iPadSearchPill }
                        }
                        if switcherInBar {
                            if #available(iOS 26.0, *) {
                                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                                ToolbarItem(placement: .topBarTrailing) { measuredSwitcher }
                                    .sharedBackgroundVisibility(.hidden)
                            } else {
                                ToolbarItem(placement: .topBarTrailing) { measuredSwitcher }
                            }
                        }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) { TopBarAccountButton() }
                    }
                    #elseif os(macOS)
                    macToolbar
                    #endif
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(titleRow ? .inline : .automatic)
                .modifier(TopRow(enabled: titleRow) {
                    HStack(spacing: 16) {
                        Text("Search")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        measuredSwitcher
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
                .modifier(CompactPhoneSearchDrawer(
                    isCompact: horizontalSizeClass != .regular,
                    query: $query,
                    isPresented: $isSearchPresented,
                    focused: $searchFieldFocused,
                    onSubmit: {
                        Task {
                            await performSearch()
                            searchFieldFocused = false
                        }
                    }
                ))
                #endif
                .task(id: initialQuery) {
                    guard let initialQuery,
                          !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    await performSearch()
                }
                // Upstream's `searchFocusTrigger`: re-tapping the tab that is
                // already selected focuses the field instead of doing nothing.
                // Bound to the counter rather than a flag so a second tap while
                // the first is still being handled is still a tap.
                .onChange(of: appModel.searchFocusTrigger) { _, _ in
                    focusTheField()
                }
                .onChange(of: scope) { _, _ in
                    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    Task { await performSearch() }
                }
                .onChange(of: query) { _, value in
                    scheduleSuggestions(value)
                    // Clearing or cancelling must not leave old hits visible
                    // below an empty field.
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        resetToHistory()
                        if !searchFieldFocused { setIPadSearchExpanded(false) }
                    }
                }
                #if os(iOS)
                // The iPad pill folds back into its button, and the tab bar
                // returns, once it is left with nothing in it. While it holds a
                // query it stays open: its results are what the page shows.
                .onChange(of: searchFieldFocused) { _, focused in
                    if !focused && term.isEmpty { setIPadSearchExpanded(false) }
                }
                .onAppear {
                    // Back on a page that still holds results: the pill shows
                    // what they are for, without raising the keyboard.
                    if !term.isEmpty { setIPadSearchExpanded(true, focus: false) }
                }
                #endif
                .onChange(of: isSearchPresented) { _, presented in
                    if !presented && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        resetToHistory()
                    }
                }
                .onChange(of: appModel.focusSearch) { _, focus in
                    guard focus else { return }
                    focusTheField()
                    appModel.focusSearch = false
                }
                .onChange(of: appModel.pendingSearchQuery) { _, pending in
                    guard let pending, !pending.isEmpty else { return }
                    query = pending
                    appModel.pendingSearchQuery = nil
                    Task { await performSearch() }
                }
                .onDisappear {
                    cancelSuggestions()
                    // Another tab must not inherit a hidden tab bar.
                    setIPadSearchExpanded(false, animated: false)
                }
        }
    }

    /// Back to the idle screen: no results, no error, no skeletons, and the
    /// recent searches showing again. Not just clearing `hits` — an in-flight
    /// search has to be abandoned too, or it would write its results into a
    /// screen that has already decided it is showing history.
    private func resetToHistory() {
        searchTask?.cancel()
        searchTask = nil
        searching = false
        searchingAddons = false
        attempted = false
        hits = []
        addonHits = []
        addonError = nil
        searchError = nil
        suggestions = []
        typeaheadHits = []
        searchContinuationToken = nil
        loadingMore = false
        // Nothing on screen is for any term now, which is what stops the
        // old results reappearing under a field that has been emptied.
        searchedTerm = ""
        // A fresh list identity, so the next search starts at the top rather than
        // inheriting wherever the history view was scrolled to.
        requestToken &+= 1
    }

    /// Focus the field.
    ///
    /// One hop through a `Task` on both platforms: the field is part of the
    /// navigation bar, and at the moment a re-tap arrives the view is being
    /// re-selected — the modifier that addresses the field lands on the following
    /// update, so setting focus in the same turn asks a view that is not there
    /// yet.
    private func focusTheField() {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            // The pill's field only exists once it is open; opening focuses it.
            setIPadSearchExpanded(true)
            return
        }
        #endif
        Task { @MainActor in
            #if os(iOS)
            isSearchPresented = true
            #endif
            searchFieldFocused = true
        }
    }

    #if os(iOS)
    /// An iPad too narrow for the switcher in the top bar: the title and the
    /// switcher share a row under it, one on each margin.
    private var titleRow: Bool { horizontalSizeClass == .regular && !switcherInBar }

    /// The source switcher, measured in the top bar so the search button
    /// stands its height. Under the bar it is a plain segmented control, a
    /// size smaller, and the button keeps the bar's height instead.
    private var measuredSwitcher: some View {
        ToolbarSearchSourceSwitcher(selection: $searchSource)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if height > 0, switcherInBar { switcherHeight = height }
            }
    }

    private var iPadSearchPill: some View {
        IPadToolbarSearchPill(
            text: $query,
            side: switcherHeight,
            roomy: pillRoomy,
            open: pillOpen,
            focused: $searchFieldFocused,
            onExpand: { focusTheField() },
            onSubmit: {
                Task {
                    await performSearch()
                    searchFieldFocused = false
                }
            }
        )
    }
    #endif

    /// Opens or folds the iPad's search pill, in steps so nothing is ever
    /// short of room in the top bar. Opening: the tab bar leaves (see
    /// `iPadPlaybackChrome`), the item's slot widens, then the glass grows
    /// leftwards and the field takes focus. Folding runs the same steps
    /// backwards, so the bar only returns once the pill is a button again.
    /// Without the order the pill grew while the bar was still there, and
    /// iPadOS pushed the source switcher into a "⋯" overflow menu meanwhile.
    /// A no-op anywhere but a regular-width iPad.
    private func setIPadSearchExpanded(_ expanded: Bool, animated: Bool = true, focus: Bool = true) {
        #if os(iOS)
        let wanted = expanded && horizontalSizeClass == .regular
        guard wanted != appModel.iPadSearchExpanded || wanted != pillOpen else { return }
        pillGeneration &+= 1
        let generation = pillGeneration
        guard animated else {
            pillOpen = wanted
            pillRoomy = wanted
            appModel.iPadSearchExpanded = wanted
            return
        }
        Task { @MainActor in
            func current() -> Bool { generation == pillGeneration }
            if wanted {
                withAnimation(.smooth(duration: 0.3)) { appModel.iPadSearchExpanded = true }
                try? await Task.sleep(for: .milliseconds(300))
                guard current() else { return }
                pillRoomy = true
                // A few frames for the bar to lay out the wider slot and for
                // the field to be built, so neither lands inside the animation.
                try? await Task.sleep(for: .milliseconds(60))
                guard current() else { return }
                withAnimation(.smooth(duration: 0.35)) { pillOpen = true }
                guard focus else { return }
                // After the glass has settled: the keyboard's arrival relays
                // out the whole page, and mid-animation that froze the pill.
                try? await Task.sleep(for: .milliseconds(360))
                guard current() else { return }
                searchFieldFocused = true
            } else {
                withAnimation(.smooth(duration: 0.3)) { pillOpen = false }
                try? await Task.sleep(for: .milliseconds(300))
                guard current() else { return }
                pillRoomy = false
                withAnimation(.smooth(duration: 0.3)) { appModel.iPadSearchExpanded = false }
            }
        }
        #endif
    }

    /// Cancels an in-flight typeahead request.
    ///
    /// The task used to be cancelled only on the *next* keystroke, so leaving the
    /// screen mid-request left it running and able to write results into a view
    /// that was gone.
    private func cancelSuggestions() {
        suggestTask?.cancel()
        suggestTask = nil
        typeaheadTask?.cancel()
        typeaheadTask = nil
    }

    #if os(macOS)
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        if showsMacToolbar && !appModel.nowPlayingPresented {
            if !searchedTerm.isEmpty {
                // Ahead of the field, so it does not split the search
                // field from its catalogue switcher.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(
                            id: MacBrowseWindow.sceneID,
                            value: MacBrowseWindowRoute.search(
                                query: searchedTerm, scope: scope, source: searchSource
                            )
                        )
                    } label: {
                        Label("Open in New Window", systemImage: "macwindow.badge.plus")
                    }
                    .help("Open these search results in a new window")
                }
            }
            // Music's titlebar order: search pill first, then the YouTube/Addons
            // tab switcher, and lastly the window's Profile and Downloads buttons.
            ToolbarItem(id: MacToolbarItemID.searchField, placement: .primaryAction) {
                MacToolbarSearchField(text: $query, focused: $searchFieldFocused) {
                    Task {
                        await performSearch()
                        searchFieldFocused = false
                    }
                }
            }
            ToolbarItem(id: MacToolbarItemID.searchSource, placement: .primaryAction) {
                ToolbarSearchSourceSwitcher(selection: $searchSource)
            }
            if hostsWindowControls {
                MacWindowControls()
            }
        }
    }
    #endif

    private var resultsColumn: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // The phone keeps upstream's picker above the results, up only
            // while the field is empty: once something is typed the page is
            // about the results, and the picker would only push them down. On a
            // regular-width iPad and on the Mac it lives in the titlebar,
            // beside the search field, where it pushes nothing and stays
            // reachable.
            if horizontalSizeClass != .regular, term.isEmpty {
                sourceSwitcher
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            #endif
            switch searchSource {
            case .youtube: youtubeResultsColumn
            case .library: libraryResultsColumn
            case .addons: addonResultsColumn
            }
        }
        .task(id: searchSource == .library ? auth.sessionEpoch : -1) {
            await loadLibrary()
        }
        .onChange(of: scenePhase) { _, _ in refreshAddonCount() }
        .onChange(of: searchSource) { _, _ in
            refreshAddonCount()
            guard !term.isEmpty else { return }
            Task { await performSearch() }
        }
        #if os(macOS)
        // Settings is its own window here, so the tab is not told when the
        // sources screen closes; the window coming back is the next best signal.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshAddonCount()
        }
        #endif
    }

    /// The field's catalogue picker, YouTube Music or the addons the listener
    /// enabled. Flipping answers whatever is already in the field again with the
    /// source just picked, rather than clearing it.
    private var sourceSwitcher: some View {
        Picker("Search source", selection: $searchSource) {
            ForEach(SearchSource.allCases) { source in
                Text(source.label).tag(source)
            }
        }
        .pickerStyle(.segmented)
        // The picker's own label is redundant beside the segments; VoiceOver
        // still reads it, so it is hidden rather than removed.
        .labelsHidden()
    }

    /// Re-reads how many addons are enabled. Cheap (an in-memory registry walk),
    /// and refreshed from every place the registry can have changed while this
    /// screen stayed up — Settings is a separate window on the Mac, so a tab
    /// left open would otherwise keep saying "No addons yet" after one was added.
    private func refreshAddonCount() {
        addonCount = Int(SourceResolverBridge.shared.addonCount())
    }

    private var youtubeResultsColumn: some View {
        VStack(spacing: 0) {
            // Upstream's rule for the filter tabs, and the reason it is a rule
            // rather than a detail: they only mean something once a search has
            // been committed, and they stay hidden while suggestions are up
            // because everything below them is for whatever was searched before
            // this edit began. They stay up for an empty or failed search too —
            // "pick a filter that finds nothing" is exactly when the chips are
            // the only way out, so hiding them would trap the reader.
            if showsFilters {
                filterChips
                    .padding(.bottom, 6)
            }

            if searching {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(0..<8, id: \.self) { _ in SkeletonBlock(height: 52) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                }
            } else if attempted && !searching && hits.isEmpty && searchError == nil {
                EmptyStateView(icon: Image(.bchSearch), title: "No results", subtitle: "Nothing found for “\(query)”.", buttonTitle: nil, action: nil)
            } else if let searchError {
                EmptyStateView(icon: Image(.bchSearch), title: "Search unavailable", subtitle: searchError, buttonTitle: nil, action: nil)
            } else if isEditing {
                suggestionList
            } else if !query.isEmpty {
                List {
                    if let top = topResult {
                        // Its own section, with the row chrome taken off, so the
                        // card scrolls away with the results rather than sitting
                        // above a second scroll view — two independent scrollers on
                        // one screen is a thing people fight with.
                        Section {
                            TopResultSection(hit: top, scope: scope) { term in
                                query = term
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    ForEach(sections) { sec in
                        if let title = sec.title {
                            Section {
                                ForEach(sec.hits) { hit in
                                    searchHitRow(hit)
                                }
                            } header: {
                                Text(title)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .textCase(nil)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                            }
                        } else {
                            ForEach(sec.hits) { hit in
                                searchHitRow(hit)
                            }
                        }
                    }
                    // End-of-list sentinel: a continuation page is fetched only
                    // when the reader reaches the last row, so the first page
                    // stays instant and later pages ride in as needed.
                    if searchContinuationToken != nil {
                        Section {
                            HStack {
                                Spacer()
                                if loadingMore { ProgressView().controlSize(.small) }
                                Spacer()
                            }
                            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .onAppear { loadMore() }
                        }
                    }
                }
                .listStyle(.plain)
                .listSectionSeparator(.hidden)
                .scrollContentBackground(.hidden)
                // Upstream's `scrollResetTrigger`: one list whose contents change,
                // reset for each new request, so choosing a recent search cannot
                // inherit the history's previous scroll position — or a previous
                // result set's. A new identity per request is what puts it at the
                // top; without it the same `List` keeps its offset and the new
                // results open halfway down.
                .id(requestToken)
            } else {
                history
            }
        }
    }

    // MARK: - Library source

    /// What the Library source found for the field's text, section by section.
    private struct LibraryMatches {
        var songs: [YouTubeSong] = []
        var device: [LocalTrack] = []
        var artists: [SearchHitDTO] = []
        var albums: [SearchHitDTO] = []
        var playlists: [SearchHitDTO] = []

        var isEmpty: Bool {
            songs.isEmpty && device.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
        }
    }

    /// Every word typed has to appear somewhere in the row, in any order, so
    /// "titanium sia" finds Titanium by Sia.
    private static func libraryMatch(_ words: [String], _ fields: String?...) -> Bool {
        let haystack = fields.compactMap { $0 }.joined(separator: " ")
        return words.allSatisfy { haystack.localizedStandardContains($0) }
    }

    private var libraryMatches: LibraryMatches {
        let words = term.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return LibraryMatches() }
        func cards(_ shelf: String, type: String) -> [SearchHitDTO] {
            (libraryShelf(titled: shelf, in: libraryShelves)?.items ?? [])
                .filter { $0.browseId != nil && Self.libraryMatch(words, $0.title, $0.subtitle) }
                .map {
                    SearchHitDTO(
                        kind: "browse", videoId: nil, title: $0.title, subtitle: $0.subtitle,
                        thumbnailUrl: $0.thumbnailUrl, durationText: nil, albumName: nil,
                        browseId: $0.browseId, browseType: type, artistId: nil, albumId: nil,
                        isVideo: nil, setVideoId: nil
                    )
                }
        }
        return LibraryMatches(
            songs: librarySongs.filter { Self.libraryMatch(words, $0.title, $0.artist, $0.albumName) },
            device: local.tracks.filter { Self.libraryMatch(words, $0.title, $0.artist, $0.album) },
            artists: cards("artists", type: "ARTIST"),
            albums: cards("albums", type: "ALBUM"),
            playlists: cards("playlists", type: "PLAYLIST")
        )
    }

    /// Loads the signed-in library for the Library source. Both requests go
    /// through the page cache the Library screens use, so a library already
    /// opened there answers at once.
    private func loadLibrary() async {
        guard searchSource == .library else { return }
        guard auth.signedIn else {
            librarySongs = []
            libraryShelves = []
            libraryLoading = false
            return
        }
        libraryLoading = librarySongs.isEmpty && libraryShelves.isEmpty
        libraryError = nil
        async let songs = InnertubeFeed.shared.librarySongs()
        async let shelves = InnertubeFeed.shared.library()
        var failure: String?
        do { librarySongs = try await songs } catch { failure = error.localizedDescription }
        do { libraryShelves = try await shelves } catch { failure = failure ?? error.localizedDescription }
        guard !Task.isCancelled else { return }
        // One half arriving is enough to search; the error is for when there
        // is nothing to search at all.
        libraryError = librarySongs.isEmpty && libraryShelves.isEmpty ? failure : nil
        libraryLoading = false
    }

    /// The Library source's column. It filters as the field is typed into —
    /// everything it searches is already on the device — so there is no
    /// submitted term, no suggestions and no history of its own.
    @ViewBuilder
    private var libraryResultsColumn: some View {
        let matches = libraryMatches
        if !auth.signedIn && !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Search your library",
                subtitle: "Sign in, or scan a folder on this device, to search the songs, albums, artists and playlists you keep.",
                buttonTitle: "Sign In"
            ) { auth.loginPresented = true }
        } else if term.isEmpty {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Search your library",
                subtitle: "Songs, albums, artists and playlists you saved, and the music on this device.",
                buttonTitle: nil,
                action: nil
            )
        } else if matches.isEmpty && libraryLoading {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(0..<8, id: \.self) { _ in SkeletonBlock(height: 52) }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
            }
        } else if matches.isEmpty, let libraryError, !local.scanned {
            EmptyStateView(icon: Image(.bchLibrary), title: "Library unavailable", subtitle: libraryError, buttonTitle: "Retry") {
                Task { await loadLibrary() }
            }
        } else if matches.isEmpty {
            EmptyStateView(icon: Image(.bchSearch), title: "No results", subtitle: "Nothing in your library for “\(term)”.", buttonTitle: nil, action: nil)
        } else {
            List {
                if !matches.songs.isEmpty {
                    librarySection("Songs") {
                        let entries = matches.songs.map(Self.libraryEntry)
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            librarySongRow(entry) {
                                controller.play(entries, at: index, context: "Library", contextID: "library:songs")
                            }
                        }
                    }
                }
                if !matches.device.isEmpty {
                    librarySection("On This Device") {
                        let entries = matches.device.map(QueueEntry.from)
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            librarySongRow(entry) {
                                controller.play(entries, at: index, context: "On Device", contextID: "local:songs")
                            }
                        }
                    }
                }
                if !matches.artists.isEmpty {
                    librarySection("Artists") { ForEach(matches.artists) { searchHitRow($0) } }
                }
                if !matches.albums.isEmpty {
                    librarySection("Albums") { ForEach(matches.albums) { searchHitRow($0) } }
                }
                if !matches.playlists.isEmpty {
                    librarySection("Playlists") { ForEach(matches.playlists) { searchHitRow($0) } }
                }
            }
            .listStyle(.plain)
            .listSectionSeparator(.hidden)
            .scrollContentBackground(.hidden)
        }
    }

    private func librarySection<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        Section {
            rows()
        } header: {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .textCase(nil)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
    }

    private func librarySongRow(_ entry: QueueEntry, play: @escaping () -> Void) -> some View {
        SongRow(
            entry: entry,
            isCurrent: controller.current?.id == entry.id,
            play: play,
            playNext: { controller.playNext(entry) },
            addToQueue: { controller.addToQueue(entry) }
        )
        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
        .searchRowChrome()
    }

    private static func libraryEntry(_ song: YouTubeSong) -> QueueEntry {
        QueueEntry(
            id: song.videoId, title: song.title, artist: song.artist,
            source: "yt:\(song.videoId)", thumbnailUrl: song.thumbnailUrl,
            durationText: song.durationText, albumName: song.albumName,
            artworkData: nil, isLocal: false
        )
    }

    /// The Addons source's column: the words searched there before while the
    /// field is empty, otherwise the sources' answers.
    @ViewBuilder
    private var addonResultsColumn: some View {
        if searchingAddons {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(0..<8, id: \.self) { _ in SkeletonBlock(height: 52) }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
            }
        } else if isEditing {
            addonHistoryView
        } else if let addonError {
            EmptyStateView(icon: Image(.bchSearch), title: "Sources unavailable", subtitle: addonError, buttonTitle: nil, action: nil)
        } else if !addonHits.isEmpty {
            List {
                ForEach(Array(addonHits.enumerated()), id: \.element.id) { index, hit in
                    addonRow(hit, index: index)
                }
            }
            .listStyle(.plain)
            .listSectionSeparator(.hidden)
            .scrollContentBackground(.hidden)
            .id(requestToken)
        } else if attempted && !query.isEmpty {
            EmptyStateView(icon: Image(.bchSearch), title: "No results", subtitle: "Nothing in your sources for “\(query)”.", buttonTitle: nil, action: nil)
        } else {
            addonHistoryView
        }
    }

    private var addonHistoryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if addonCount == 0 {
                    // Said before a query can fail rather than after: with no
                    // addon configured there is nothing to search, and the fix
                    // is one screen away.
                    EmptyStateView(
                        icon: Image(.bchSearch),
                        title: "No addons yet",
                        subtitle: "Add an addon in Settings ▸ Sources to search it here.",
                        buttonTitle: "Open Sources"
                    ) {
                        #if os(macOS)
                        openSettings()
                        #else
                        appModel.settingsPresented = true
                        #endif
                    }
                } else if addonHistory.isEmpty {
                    Text("Search your addons. Their addresses and order live in Settings ▸ Sources.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    HStack {
                        Text("Recently Searched")
                            .font(.title3.weight(.bold))
                        Spacer()
                        Button("Clear") {
                            AddonSearchHistory.clear()
                            addonHistory = []
                        }
                        .font(.callout)
                    }
                    ForEach(addonHistory, id: \.self) { term in
                        HStack(spacing: 12) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text(term)
                                .lineLimit(1)
                                .contentShape(.rect)
                                .onTapGesture {
                                    query = term
                                    Task { await performSearch() }
                                }
                            Spacer(minLength: 8)
                            Button {
                                AddonSearchHistory.remove(term)
                                addonHistory = AddonSearchHistory.load()
                            } label: {
                                Image(systemName: "xmark")
                                    .scaledFont(size: 11, weight: .semibold)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(term) from addon searches")
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            refreshAddonCount()
        }
    }

    /// One addon search row: sleeve, title, the tier the source offered, and the
    /// artist. Tapping plays it; the engine resolves its `src:` key.
    private func addonRow(_ hit: SearchHitDTO, index: Int) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: hit.thumbnailUrl, data: nil, side: 44)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let badge = qualityBadge(hit.sourceQuality) {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    if let artist = hit.subtitle, !artist.isEmpty {
                        Text(artist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if let text = hit.durationText, !text.isEmpty {
                Text(text)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(.rect)
        .onTapGesture {
            // Play the whole answer list, not one row, so Next has somewhere to
            // go — the same context the YouTube song rows use.
            controller.play(addonHits.map { $0.asEntry() }, at: index, context: "Search")
        }
        .accessibilityAddTraits(.isButton)
        .searchRowChrome()
    }

    /// The search badge for the tier a source offered. LOW and unlabelled rows
    /// get none, as upstream's `sourceQualityBadge` does.
    private func qualityBadge(_ raw: String?) -> String? {
        switch raw?.uppercased() {
        case "DOLBY": return "Dolby Atmos"
        case "HI-RES", "HIRES": return "Hi-Res"
        case "LOSSLESS", "FLAC", "ALAC", "WAV": return "Lossless"
        case "HIGH", "320": return "High"
        default: return nil
        }
    }

    /// Search hits may identify the playing item by its catalogue id or by the
    /// source id retained after a quality upgrade/addon resolution.
    private func isCurrentlyPlaying(_ hit: SearchHitDTO) -> Bool {
        guard let current = controller.current else { return false }
        let entry = hit.asEntry()
        return current.id == entry.id
            || (hit.videoId != nil && current.videoId == hit.videoId)
    }


    private struct SearchSectionModel: Identifiable {
        var id: String { title ?? "all" }
        let title: String?
        let hits: [SearchHitDTO]
    }

    /// Upstream's `searchSections`: when filtering by All, group into Songs, Artists,
    /// Albums, Playlists, and More sections so mixed results are readable at a glance.
    private var sections: [SearchSectionModel] {
        if scope != .all {
            return [SearchSectionModel(title: nil, hits: listHits)]
        }
        let songs = listHits.filter(\.isTrack)
        let artists = listHits.filter { $0.isBrowse && ($0.browseType?.uppercased() == "ARTIST") }
        let albums = listHits.filter { $0.isBrowse && ($0.browseType?.uppercased() == "ALBUM") }
        let playlists = listHits.filter { $0.isBrowse && ($0.browseType?.uppercased() == "PLAYLIST") }
        let more = listHits.filter { $0.isBrowse && !["ARTIST", "ALBUM", "PLAYLIST"].contains($0.browseType?.uppercased() ?? "") }

        var list: [SearchSectionModel] = []
        if !songs.isEmpty { list.append(SearchSectionModel(title: "Songs", hits: songs)) }
        if !artists.isEmpty { list.append(SearchSectionModel(title: "Artists", hits: artists)) }
        if !albums.isEmpty { list.append(SearchSectionModel(title: "Albums", hits: albums)) }
        if !playlists.isEmpty { list.append(SearchSectionModel(title: "Playlists", hits: playlists)) }
        if !more.isEmpty { list.append(SearchSectionModel(title: "More", hits: more)) }
        return list
    }

    @ViewBuilder
    private func searchHitRow(_ hit: SearchHitDTO) -> some View {
        Group {
            if hit.isBrowse, let browseId = hit.browseId {
                PushLink(destination: DetailView(browseId: browseId, initialTitle: hit.title)) {
                    browseRow(hit)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    // Tapping a result records the rich entity —
                    // real artwork and type — for the recents list.
                    RecentSearchStore.record(RecentSearchEntity(
                        id: browseId, title: hit.title,
                        subtitle: hit.subtitle ?? "",
                        artworkUrl: hit.thumbnailUrl,
                        entityType: browseEntityType(hit)
                    ))
                })
                .shelfCardContextMenu(
                    ShelfCard(
                        title: hit.title, subtitle: hit.subtitle,
                        thumbnailUrl: hit.thumbnailUrl, browseId: browseId
                    ),
                    // An artist's sleeve is round wherever it appears.
                    roundArtwork: hit.browseType?.uppercased() == "ARTIST"
                )
            } else {
                SongRow(
                    entry: hit.asEntry(),
                    isCurrent: isCurrentlyPlaying(hit),
                    play: {
                        recordTrackEntity(hit)
                        let tracks = listHits.filter(\.isTrack).map { $0.asEntry() }
                        let at = tracks.firstIndex(where: { $0.id == hit.videoId }) ?? 0
                        if scope == .songs {
                            controller.playRadio(hit.asEntry())
                        } else {
                            controller.play(tracks, at: at)
                        }
                    },
                    playNext: { controller.playNext(hit.asEntry()) },
                    addToQueue: { controller.addToQueue(hit.asEntry()) }
                )
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
        .searchRowChrome()
    }

    /// One live media row in the typeahead dropdown. A track starts a radio from
    /// itself (upstream's `onTopResultPlay` — the dropdown is a set of answers,
    /// not a running order); a browse hit opens its page. Shares the result-row
    /// chrome so the dropdown reads as one column with the committed results.
    @ViewBuilder
    private func typeaheadRow(_ hit: SearchHitDTO) -> some View {
        Group {
            if hit.isBrowse, let browseId = hit.browseId {
                PushLink(destination: DetailView(browseId: browseId, initialTitle: hit.title)) {
                    browseRow(hit)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    RecentSearchStore.record(RecentSearchEntity(
                        id: browseId, title: hit.title,
                        subtitle: hit.subtitle ?? "",
                        artworkUrl: hit.thumbnailUrl,
                        entityType: browseEntityType(hit)
                    ))
                })
                .shelfCardContextMenu(
                    ShelfCard(
                        title: hit.title, subtitle: hit.subtitle,
                        thumbnailUrl: hit.thumbnailUrl, browseId: browseId
                    ),
                    roundArtwork: hit.browseType?.uppercased() == "ARTIST"
                )
            } else {
                SongRow(
                    entry: hit.asEntry(),
                    isCurrent: isCurrentlyPlaying(hit),
                    play: {
                        recordTrackEntity(hit)
                        controller.playRadio(hit.asEntry())
                    },
                    playNext: { controller.playNext(hit.asEntry()) },
                    addToQueue: { controller.addToQueue(hit.asEntry()) }
                )
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
        .searchRowChrome()
    }

    /// The trimmed query, in one place. Everywhere below asks the same question
    /// about the field's text and must get the same answer.
    private var term: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the field is mid-edit, so the results below are not the ones for
    /// what it now says.
    ///
    /// Only the text decides this. A suggestion list that arrives after the
    /// search was committed used to count as "still editing", so the first tap
    /// on a term replaced the results with another suggestion list and a second
    /// tap was needed to see them.
    private var isEditing: Bool {
        !term.isEmpty && term != searchedTerm
    }

    /// See [resultsColumn]. Hidden only while a search is in flight or the field
    /// is being edited — upstream keeps them up for an empty or failed search
    /// too, since the chips are the only way out of an empty result set.
    private var showsFilters: Bool {
        attempted && !searching && !isEditing
    }

    private var suggestionList: some View {
        List {
            if !suggestions.isEmpty {
                Section("Suggestions") {
                    ForEach(suggestions, id: \.self) { term in
                        suggestionRow(term)
                    }
                }
            }
            // Upstream's `searchTypeaheadDropdown`: live media rows while the
            // field is still being edited, so a half-typed query already answers
            // the question. They sit above the recents — the recents list is long
            // and used to push the answers below the fold, where nobody saw them.
            // Capped at 15 because a dropdown is not a results page.
            let media = Array(typeaheadHits.prefix(Self.typeaheadMaxResults))
            if !media.isEmpty {
                Section {
                    ForEach(media) { hit in
                        typeaheadRow(hit)
                    }
                }
            }
            // Upstream keeps recent searches in the same column as the
            // suggestions, so a query too short to produce any — or one the
            // service has nothing for — leaves something to tap rather than an
            // empty "Suggestions" header and no way onward.
            let recent = recentSuggestions
            if !suggestions.isEmpty || !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { entity in
                        suggestionRow(entity.title)
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden)
        .scrollContentBackground(.hidden)
    }

    /// The recents under the dropdown. While a term is typed they narrow to the
    /// three that match it (or the three most recent when none do), because the
    /// full twenty-row list was competing with the answers for the same space.
    private var recentSuggestions: [RecentSearchEntity] {
        let all = RecentSearchStore.load()
        let term = self.term
        guard !term.isEmpty else { return all }
        let matching = all.filter { $0.title.localizedCaseInsensitiveContains(term) }
        return Array((matching.isEmpty ? all : matching).prefix(3))
    }

    /// One typeahead row: tapping the text searches it, tapping the arrow
    /// fills the field and carries on typing — the pair YouTube, Google and
    /// every mobile keyboard's suggestion strip use.
    private func suggestionRow(_ term: String) -> some View {
        HStack(spacing: 0) {
            Button {
                query = term
                Task { await performSearch() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text(term)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button {
                // Fill without searching: the completions update for the
                // longer text and the results stay for what was searched.
                query = term
            } label: {
                Image(systemName: "arrow.up.left")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fill search with \(term)")
        }
        .padding(.vertical, 4)
        .searchRowChrome()
    }

    private func browseRow(_ hit: SearchHitDTO) -> some View {
        let isArtist = hit.browseType?.uppercased() == "ARTIST"
        return HStack(spacing: 14) {
            if isArtist {
                ArtworkView(url: hit.thumbnailUrl, data: nil, side: 48)
                    .clipShape(Circle())
            } else {
                ArtworkView(url: hit.thumbnailUrl, data: nil, side: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(hit.subtitle ?? hit.browseType ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    #if os(iOS)
    private var pillSelectedTextColor: Color { Color(uiColor: .systemBackground) }
    #else
    private var pillSelectedTextColor: Color { Color(nsColor: .windowBackgroundColor) }
    #endif

    /// Upstream's `SearchFilterTabs`: horizontal scrolling filter pills (All, Songs,
    /// Videos, Albums, Artists, Playlists) with tactile feedback and inverted contrast.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Scope.allCases) { entry in
                    let selected = entry == scope
                    Button {
                        if !selected {
                            #if os(iOS)
                            let generator = UISelectionFeedbackGenerator()
                            generator.prepare()
                            generator.selectionChanged()
                            #endif
                            withAnimation(.snappy(duration: 0.25)) {
                                scope = entry
                            }
                        }
                    } label: {
                        Text(entry.label)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selected ? Color.primary : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? pillSelectedTextColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var history: some View {
        let _ = historyRevision
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                let recent = RecentSearchStore.load()
                if !recent.isEmpty {
                    recentSearches(recent)
                }

                browseCategories
            }
            .frame(maxWidth: 1_520, alignment: .leading)
            .padding(.horizontal, landingHorizontalInset)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .refreshable { await categories.load(force: true) }
        .task { await categories.load(force: false) }
    }

    /// Recent items stay in a short, horizontal strip so they are easy to revisit
    /// without taking the space that belongs to browsing categories.
    private func recentSearches(_ recent: [RecentSearchEntity]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recently Searched")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("Clear") {
                    RecentSearchStore.clear()
                    historyRevision &+= 1
                }
                .font(.callout)
                .foregroundStyle(.tint)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(recent) { entity in
                        recentSearchCard(entity)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func recentSearchCard(_ entity: RecentSearchEntity) -> some View {
        let isArtist = entity.entityType.uppercased() == "ARTIST"
        let isQuery = entity.entityType.uppercased() == "QUERY" || entity.id.hasPrefix("q:")
        return HStack(spacing: 12) {
            Button { openHistoryEntity(entity) } label: {
                HStack(spacing: 12) {
                    Group {
                        if isQuery {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.quaternary)
                                .overlay {
                                    Image(systemName: "magnifyingglass")
                                        .scaledFont(size: 18, weight: .medium)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 52, height: 52)
                        } else {
                            if isArtist {
                                ArtworkView(url: entity.artworkUrl, data: nil, side: 52)
                                    .clipShape(Circle())
                            } else {
                                ArtworkView(url: entity.artworkUrl, data: nil, side: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entity.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(isQuery ? "Search" : (entity.subtitle.isEmpty ? entity.typeLabel : "\(entity.subtitle) · \(entity.typeLabel)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                RecentSearchStore.remove(id: entity.id)
                historyRevision &+= 1
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entity.title) from recent searches")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: recentCardWidth, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var browseCategories: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Browse Categories")
                .font(.title3.weight(.bold))

            switch categories.phase {
            case .loading:
                LazyVGrid(columns: categoryColumns, spacing: 12) {
                    ForEach(0..<10, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.quaternary)
                            .aspectRatio(1.75, contentMode: .fit)
                            .redacted(reason: .placeholder)
                    }
                }
            case .failed(let message):
                HStack(spacing: 12) {
                    Text("Categories could not load. \(message)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await categories.load(force: true) } }
                        .buttonStyle(.bordered)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            case .loaded(let sections):
                let items = sections.flatMap(\.items)
                if items.isEmpty {
                    Text("No categories are available right now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    LazyVGrid(columns: categoryColumns, spacing: 12) {
                        ForEach(items) { category in
                            PushLink {
                                MoodGenrePlaylistsView(category: category)
                            } label: {
                                SearchCategoryTile(category: category)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var categoryColumns: [GridItem] {
        #if os(macOS)
        let minimum: CGFloat = 210
        #else
        let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 145
        #endif
        return [GridItem(.adaptive(minimum: minimum, maximum: 280), spacing: 12)]
    }

    private var landingHorizontalInset: CGFloat {
        #if os(macOS)
        28
        #else
        horizontalSizeClass == .regular ? 28 : 16
        #endif
    }

    private var recentCardWidth: CGFloat {
        #if os(macOS)
        292
        #else
        horizontalSizeClass == .regular ? 280 : 252
        #endif
    }

    /// Tapping a history entity navigates or plays without re-logging it —
    /// it is already the most recent record of itself.
    private func openHistoryEntity(_ entity: RecentSearchEntity) {
        switch entity.entityType.uppercased() {
        case "TRACK":
            if entity.id.hasPrefix("q:") {
                query = entity.title
                Task { await performSearch() }
            } else {
                controller.playRadio(QueueEntry.youtube(
                    videoId: entity.id, title: entity.title,
                    artist: entity.subtitle, thumbnailUrl: entity.artworkUrl
                ))
            }
        case "ALBUM", "ARTIST", "PLAYLIST":
            appModel.pendingDetail = .detail(browseId: entity.id, title: entity.title)
        default:
            query = entity.title
            Task { await performSearch() }
        }
    }

    private func scheduleSuggestions(_ value: String) {
        suggestTask?.cancel()
        typeaheadTask?.cancel()
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // The Addons source has no completion service of its own, and YouTube's
        // completions under an addon query would be answers from the wrong
        // catalogue. Its own history stands in while the field is being edited.
        guard searchSource == .youtube else {
            suggestions = []
            typeaheadHits = []
            return
        }
        // A committed search sets the field to the term it just ran. Fetching
        // completions for that same string puts the suggestion list back on
        // top of the results.
        guard term.count >= 2, term != searchedTerm else {
            suggestions = []
            typeaheadHits = []
            return
        }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let list = await InnertubeSearch.shared.suggestions(term)
            await MainActor.run {
                guard !Task.isCancelled, self.term == term, term != self.searchedTerm else { return }
                suggestions = list
            }
        }
        // The media dropdown debounces a little longer than the text
        // completions so the pricier request doesn't fire per keystroke; a
        // late answer for a term the reader has moved past is dropped, not shown.
        typeaheadTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            // A failure here is not shown in the UI (a dropdown that explains
            // itself in a list of suggestions is noise), but it must not be
            // swallowed either: the rows simply not appearing is the symptom
            // this logged line exists to explain.
            let hits: [SearchHitDTO]
            do {
                hits = try await InnertubeSearch.shared.typeahead(term)
            } catch {
                DebugLog.shared.w(message: "search typeahead failed for \"\(term)\": \(error.localizedDescription)")
                hits = []
            }
            await MainActor.run {
                guard !Task.isCancelled, self.term == term, term != self.searchedTerm else { return }
                typeaheadHits = hits
            }
        }
    }

    /// The promoted row, when this tab has one and the search found it.
    ///
    /// Read from the response rather than chosen from the list: it is Google's own
    /// promotion, and a card's track is frequently absent from the results entirely.
    private var topResult: SearchHitDTO? {
        guard scope.showsTopResult else { return nil }
        return hits.first { $0.isTopResult }
    }

    /// Everything that is not the promoted row — the promoted one is not repeated
    /// in the list, so showing both would put the same track on screen twice.
    private var listHits: [SearchHitDTO] {
        guard scope.showsTopResult else { return hits }
        return hits.filter { !$0.isTopResult }
    }

    /// Records a tapped track with its real artwork and artist, so recents
    /// show the song rather than the words that found it.
    private func recordTrackEntity(_ hit: SearchHitDTO) {
        guard let videoId = hit.videoId else { return }
        RecentSearchStore.record(RecentSearchEntity(
            id: videoId, title: hit.title,
            subtitle: hit.subtitle ?? "",
            artworkUrl: hit.thumbnailUrl,
            entityType: "TRACK"
        ))
    }

    /// Maps a browse hit's type to the entity type the recents list files it
    /// under — album, artist, playlist, or a track carrying a browse id.
    private func browseEntityType(_ hit: SearchHitDTO) -> String {
        switch (hit.browseType ?? "").uppercased() {
        case "ALBUM": return "ALBUM"
        case "ARTIST": return "ARTIST"
        case "PLAYLIST": return "PLAYLIST"
        default: return "TRACK"
        }
    }

    private func performSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        switch searchSource {
        case .youtube: break
        // The library answers as the field is typed into, from what is
        // already loaded; there is nothing for a submit to fetch.
        case .library: return
        case .addons:
            await performAddonSearch(term)
            return
        }
        // A new request abandons the previous one. Two searches in flight meant
        // the slower one could land last and overwrite the newer results, which
        // is the bug a listener sees as "I searched for the right thing and got
        // the wrong thing".
        searchTask?.cancel()
        cancelSuggestions()
        searching = true
        attempted = true
        searchError = nil
        suggestions = []
        typeaheadHits = []
        searchContinuationToken = nil
        loadingMore = false
        // A new list identity per request, so the results open at the top rather
        // than at the previous set's offset.
        requestToken &+= 1
        searchedTerm = term
        let wanted = scope
        let task = Task { @MainActor in
            do {
                let page = try await InnertubeSearch.shared.searchPage(term, scope: wanted.rawValue)
                var found = page.hits
                if PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true), wanted == .songs {
                    let extra = await JioSaavn.search(term)
                    found.insert(contentsOf: extra, at: 0)
                }
                // Cancellation can arrive while the network call is in flight, so
                // the guard is checked again here rather than trusted to have been
                // checked before the request.
                guard !Task.isCancelled else { return }
                hits = found
                searchContinuationToken = page.continuation
            } catch {
                guard !Task.isCancelled else { return }
                AuthController.reportIfSessionExpired(error)
                searchError = "Couldn't reach the music service. Check your connection and try again."
                hits = []
                searchContinuationToken = nil
            }
            searching = false
            searchTask = nil
        }
        searchTask = task
        _ = await task.value
    }

    /// One query answered by every enabled addon. The bridge merges the rows
    /// round-robin and drops an addon slower than 12 s, so one dead catalogue
    /// costs only its own rows.
    private func performAddonSearch(_ term: String) async {
        searchTask?.cancel()
        cancelSuggestions()
        searchingAddons = true
        attempted = true
        addonError = nil
        suggestions = []
        typeaheadHits = []
        searchContinuationToken = nil
        loadingMore = false
        requestToken &+= 1
        searchedTerm = term
        AddonSearchHistory.record(term)
        addonHistory = AddonSearchHistory.load()
        let task = Task { @MainActor in
            do {
                let found = try await SourceSearch.shared.addons(term)
                guard !Task.isCancelled else { return }
                addonHits = found
            } catch {
                guard !Task.isCancelled else { return }
                addonError = "Couldn't reach your sources. \(error.localizedDescription)"
                addonHits = []
            }
            searchingAddons = false
            searchTask = nil
        }
        searchTask = task
        _ = await task.value
    }

    /// Appends the next page of the committed search when the list reaches its
    /// end. A continuation is a separate, deliberately cheap request — the
    /// first page stays instant and the later pages ride in only when asked.
    private func loadMore() {
        guard let token = searchContinuationToken, !loadingMore, !searching else { return }
        loadingMore = true
        let term = searchedTerm
        let wanted = scope
        Task { @MainActor in
            defer { loadingMore = false }
            do {
                let page = try await InnertubeSearch.shared.searchContinuation(token, scope: wanted.rawValue)
                // The reader may have moved on to a new term or filter while the
                // page was in flight; a stale page must not append to it.
                guard searchedTerm == term, scope == wanted, !Task.isCancelled else { return }
                let existing = Set(hits.map(\.id))
                let newRows = page.hits.filter { !existing.contains($0.id) }
                hits.append(contentsOf: newRows)
                // Keep the token only when there is a real next step. A page
                // that adds no new rows, or that echoes the token it was given
                // back, cannot lead anywhere further — and without this the
                // sentinel re-fires on every appear, fetching forever.
                searchContinuationToken = (page.continuation == token || newRows.isEmpty) ? nil : page.continuation
            } catch {
                // A failed page is silent: the rows already on screen stay, and
                // the sentinel can try again on the next pass.
            }
        }
    }
}

/// Wide, image-led tiles are easier to scan in a discovery grid than the compact
/// sleeve tiles used by Explore. Category identity and destination stay shared.
private struct SearchCategoryTile: View {
    let category: MoodGenre

    private var accent: Color {
        let palette: [Color] = [
            Color(red: 0.91, green: 0.18, blue: 0.35),
            Color(red: 0.98, green: 0.47, blue: 0.12),
            Color(red: 0.91, green: 0.67, blue: 0.04),
            Color(red: 0.17, green: 0.59, blue: 0.47),
            Color(red: 0.08, green: 0.55, blue: 0.74),
            Color(red: 0.38, green: 0.40, blue: 0.83),
            Color(red: 0.66, green: 0.31, blue: 0.68),
            Color(red: 0.78, green: 0.23, blue: 0.19),
        ]
        let hash = category.title.utf16.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
        return palette[Int((UInt32(bitPattern: hash) & 0x7fff_ffff) % UInt32(palette.count))]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if let url = category.thumbnailUrl, let imageURL = URL(string: url) {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(accent.gradient)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                } else {
                    Rectangle().fill(accent.gradient)
                }

                accent.opacity(0.24)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(category.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .aspectRatio(1.75, contentMode: .fit)
        .accessibilityLabel(category.title)
    }
}

private extension View {
    /// Search rows are spaced, not ruled. A plain `List` draws a hairline under
    /// every row (and macOS a second one under each section header), which is
    /// the "lines drawn across the page" look; artwork and spacing already
    /// separate the rows.
    func searchRowChrome() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
