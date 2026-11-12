#if os(macOS)
import AppKit
#endif
import Observation
import BitChordShared

/// One scanned local audio file.
struct LocalTrack: Identifiable, Hashable {
    let path: String
    var title: String
    var artist: String
    var album: String
    var durationSeconds: Double
    var artwork: Data?
    var trackNumber: UInt32 = 0
    /// The file's creation and modification dates, from the file system.
    ///
    /// There is no better source. A tag does not record when *you* added a file to
    /// this machine, and inventing a date from the scan would make the order a
    /// function of when the last scan ran — so "Date Added" would silently change
    /// every time the library was rescanned.
    let dateAdded: Date?
    let dateModified: Date?
    var artworkURL: String? = nil

    var id: String { path }
}

/// Scans a user-selected folder for audio files (spec §5 LocalMusicView:
/// macOS scans via `NSOpenPanel` + security-scoped bookmarks; MPMediaLibrary
/// is iOS-only and permission-gated). Metadata comes from native-core's
/// lofty reader so tags decode identically to the playback engine.
@MainActor
@Observable
final class LocalLibrary {
    static let shared = LocalLibrary()

    private(set) var tracks: [LocalTrack] = [] {
        didSet { viewRowsJSON = nil; visibleTracksCache = nil; tracksByPath = nil }
    }
    @ObservationIgnored private var viewRowsJSON: String?
    @ObservationIgnored private var tracksByPath: [String: LocalTrack]?
    @ObservationIgnored private var visibleTracksCache: (sort: LocalMusicSort, query: String, tracks: [LocalTrack])?
    private(set) var scanned = false
    var onChange: (() -> Void)?

    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private var folderAccess: SecurityScopedResourceLease?

    /// Restores the persisted bookmark and rescans. BITCHORD_LIBRARY_PATH is
    /// a dev-only override so automated UI tests can seed the library without
    /// driving the modal open panel.
    func restore() {
        if let override = ProcessInfo.processInfo.environment["BITCHORD_LIBRARY_PATH"],
           !override.isEmpty {
            scan(folder: URL(fileURLWithPath: override))
            return
        }
        let stored = PlatformSettings.shared.getString(key: "local_library_path", default: "")
        guard !stored.isEmpty, let data = Data(base64Encoded: stored) else { return }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data,
                                options: options,
                                relativeTo: nil,
                                bookmarkDataIsStale: &stale) else { return }
        adoptAccess(to: url)
        if stale { persistBookmark(for: url) }
        scan(folder: url)
    }

    /// Prompts for a folder, persists a bookmark, scans.
    func chooseFolder() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder holding your music library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptAccess(to: url)
        persistBookmark(for: url)
        scan(folder: url)
#else
        pickingPlaceholder()
#endif
    }

    func scanPicked(_ url: URL) {
        adoptAccess(to: url)
        persistBookmark(for: url)
        scan(folder: url)
    }

    #if os(iOS)
    private func pickingPlaceholder() {}
    #endif

    private func adoptAccess(to url: URL) {
        guard folderAccess?.url != url.standardizedFileURL else { return }
        folderAccess = SecurityScopedResourceLease(url: url)
    }

    private func persistBookmark(for url: URL) {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        if let bookmark = try? url.bookmarkData(options: options) {
            AppSettings.shared.setLocalLibraryPath(value: bookmark.base64EncodedString())
        }
    }

    func accessLease(for source: String?) -> SecurityScopedResourceLease? {
        folderAccess?.covers(source) == true ? folderAccess : nil
    }

    func forgetFolder() {
        scanTask?.cancel()
        scanID = UUID()
        scanTask = nil
        folderAccess = nil
        tracks = []
        scanned = false
        AppSettings.shared.setLocalLibraryPath(value: "")
        onChange?()
    }

    private func scan(folder: URL) {
        scanTask?.cancel()
        let id = UUID(); scanID = id
        let access = folderAccess
        let work = Task.detached(priority: .utility) {
            withExtendedLifetime(access) { Self.readTracks(folder: folder) }
        }
        scanTask = Task {
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard scanID == id, !Task.isCancelled else { return }
            tracks = result; scanned = true; onChange?()
        }
    }

    func waitForScan() async { await scanTask?.value }

    nonisolated private static func readTracks(folder: URL) -> [LocalTrack] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        let audioPaths = enumerator
            .compactMap { $0 as? URL }
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ["mp3", "flac", "m4a", "mp4", "aac", "ogg", "opus", "wav", "aiff", "aif", "webm"]
                    .contains(ext)
            }
            .map(\.path)

        var found: [LocalTrack] = []
        for path in audioPaths {
            if Task.isCancelled { return [] }
            let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let dates = fileDates(at: path)
            if let meta = readTrackMetadataSummary(path: path) {
                // Untagged files parse fine but carry empty strings; give them
                // the same fallbacks as the unreadable path so rows never
                // render invisible zero-height text.
                found.append(LocalTrack(
                    path: path,
                    title: meta.title.isEmpty ? fileName : meta.title,
                    artist: meta.artist.isEmpty ? "Unknown artist" : meta.artist,
                    album: meta.album,
                    durationSeconds: meta.durationSeconds,
                    artwork: nil,
                    trackNumber: meta.trackNumber,
                    dateAdded: dates.added,
                    dateModified: dates.modified,
                    artworkURL: LocalArtwork.reference(path: path)
                ))
            } else {
                found.append(LocalTrack(
                    path: path,
                    title: fileName,
                    artist: "Unknown artist",
                    album: "",
                    durationSeconds: 0,
                    artwork: nil,
                    dateAdded: dates.added,
                    dateModified: dates.modified
                ))
            }
        }
        // No ordering here. The scan's job is to find the files; the order they are
        // shown in is the sort menu's, and sorting twice meant two different
        // answers to "what order is this" depending on which one you had looked at.
        // Alphabetical by path keeps the list stable between scans, which is what
        // the ordering's tie-breakers assume.
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The file's own dates, read once per file during the scan.
    ///
    /// Not on a background queue of its own: the scan is already off the main
    /// thread's critical path and a stat per file is cheap next to the tag read
    /// that follows it.
    nonisolated private static func fileDates(at path: String) -> (added: Date?, modified: Date?) {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (nil, nil) }
        return (values.creationDate, values.contentModificationDate)
    }
    // ---- Ordering and filtering, delegated -------------------------------

    /// What the listener has the list sorted by.
    var sort: LocalMusicSort = .titleAscending
    /// List or grid.
    var viewType: LocalViewType = .list
    /// The live search box's contents.
    var query: String = ""

    /// [tracks] narrowed and ordered, by the shared policy.
    ///
    /// Delegated rather than reimplemented: the host sorting with its own
    /// comparators is how the order on screen ends up subtly different from the
    /// one the sort menu names.
    var visibleTracks: [LocalTrack] {
        // Register the scan as an Observation dependency even on a cache hit.
        _ = tracks.count
        if let cached = visibleTracksCache, cached.sort == sort, cached.query == query { return cached.tracks }
        if viewRowsJSON == nil { viewRowsJSON = makeViewRowsJSON() }
        guard let json = viewRowsJSON else { return tracks }
        let document = LocalLibraryBridge.shared.view(tracksJson: json, order: sort.rawValue, query: query)
        guard let answer = document.data(using: .utf8),
              let ordered = try? JSONSerialization.jsonObject(with: answer) as? [[String: Any]]
        else { return tracks }
        if tracksByPath == nil {
            tracksByPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let result = ordered.compactMap { row -> LocalTrack? in
            guard let path = row["path"] as? String else { return nil }
            return tracksByPath?[path]
        }
        visibleTracksCache = (sort, query, result)
        return result
    }

    private func makeViewRowsJSON() -> String? {
        let rows = tracks.map { track -> [String: Any] in
            var row: [String: Any] = [
                "path": track.path,
                "title": track.title,
                "artist": track.artist,
                "album": track.album,
                "durationSeconds": track.durationSeconds,
            ]
            // Null rather than omitted: "this file has no creation date" is a real
            // answer, and the ordering sorts it last because of it. An omitted
            // field would read as absent from the document entirely.
            if let added = track.dateAdded { row["dateAddedSeconds"] = added.timeIntervalSince1970 }
            if let modified = track.dateModified {
                row["dateModifiedSeconds"] = modified.timeIntervalSince1970
            }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Every sort order with its name, from the shared module.
    var sortOptions: [LocalMusicSort] { LocalMusicSort.allCases }

    func setSort(_ next: LocalMusicSort) {
        sort = next
        LocalLibraryBridge.shared.setSort(order: next.rawValue, callback: SortAck { _ in })
    }

    func setViewType(_ next: LocalViewType) {
        viewType = next
        LocalLibraryBridge.shared.setViewType(viewType: next.rawValue, callback: SortAck { _ in })
    }

    /// Load the saved sort and view type, once, when the library first appears.
    func restoreViewPreferences() {
        guard !restoredViewPreferences else { return }
        restoredViewPreferences = true
        LocalLibraryBridge.shared.currentSort(callback: CurrentSort { order, view in
            Task { @MainActor in
                self.sort = LocalMusicSort(rawValue: order) ?? .titleAscending
                self.viewType = LocalViewType(rawValue: view) ?? .list
            }
        })
    }

    private var restoredViewPreferences = false

    var albumGroups: [(name: String, artist: String, tracks: [LocalTrack])] {
        Dictionary(grouping: tracks) { "\($0.artist)|\($0.album.isEmpty ? "—" : $0.album)" }
            .values
            .map { group in
                let ordered = group.sorted { lhs, rhs in
                    localTrackComesBefore(
                        trackNumber: lhs.trackNumber, path: lhs.path,
                        trackNumber: rhs.trackNumber, path: rhs.path
                    )
                }
                return (name: ordered.first?.album ?? "", artist: ordered.first?.artist ?? "", tracks: ordered)
            }
            .sorted { ($0.artist, $0.name) < ($1.artist, $1.name) }
    }

    var artistGroups: [(name: String, tracks: [LocalTrack])] {
        Dictionary(grouping: tracks, by: \.artist)
            .map { (name: $0.key, tracks: $0.value) }
            .sorted { $0.name < $1.name }
    }
}

/// The shared sort orders, by name.
///
/// A mirror of the shared enum, and deliberately one that can be wrong: an order
/// this build does not have simply does not appear in the menu, and one it has
/// but the shared module does not resolves to nil and is ignored. Neither is worth
/// a crash on a preference.
enum LocalMusicSort: String, CaseIterable, Identifiable {
    case titleAscending = "TITLE_ASC"
    case titleDescending = "TITLE_DESC"
    case dateAdded = "DATE_ADDED"
    case dateModified = "DATE_MODIFIED"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .titleAscending: return "Title"
        case .titleDescending: return "Title (Reverse)"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        }
    }
}

/// List or grid.
///
/// Both are offered: a list for browsing and its row affordances, a grid for the
/// case where the point is to *see* the collection. Offering only one makes the
/// other somebody's habit rather than their choice.
enum LocalViewType: String, CaseIterable, Identifiable {
    case list = "LIST"
    case grid = "GRID"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }

    var label: String {
        switch self {
        case .list: return "List"
        case .grid: return "Grid"
        }
    }
}

private final class SortAck: LocalLibraryBridgeSetSortCallback {
    private let handler: (Bool) -> Void
    init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    func onResult(ok: Bool) { handler(ok) }
}

private final class CurrentSort: LocalLibraryBridgeSortCallback {
    private let handler: (String, String) -> Void
    init(_ handler: @escaping (String, String) -> Void) { self.handler = handler }
    func onResult(order: String, viewType: String) { handler(order, viewType) }
}
