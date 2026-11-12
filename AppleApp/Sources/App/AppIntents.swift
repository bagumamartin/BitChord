import AppIntents
import Foundation

// MARK: - The app's objects, for code that has no scene

/// The objects an App Intent needs and the app's scene also owns.
///
/// Siri, Shortcuts and Spotlight perform an intent in the app's process but
/// outside the SwiftUI environment: there is no `@Environment(PlaybackController.self)`
/// to read and no `AppModel` to navigate with. They are created here, once, and
/// the `App` scene takes its `@State` values from the same holder — so there is
/// still exactly one of each. That matters for the player in particular: a second
/// `PlaybackController` boots a second output stream and fights the first for the
/// system's media slot, which is why `partySync` is not constructed inline either.
///
/// A `static let` exists as soon as anything asks for it, which covers an intent
/// performed during launch, before the first window has been made.
@MainActor
final class AppServices {
    static let shared: AppServices = {
        // Before anything can create a JavaScript context. JavaScriptCore reads
        // its options once, when the process's first VM is made.
        tuneJavaScriptCore()
        return AppServices()
    }()

    /// One garbage-collector marker for the in-process JavaScript engine.
    ///
    /// The only JavaScript this process runs is the stream cipher (pages and
    /// sign-in run in WebKit's own processes). On a cold player that work
    /// allocates heavily, and JavaScriptCore marks its heap with one helper per
    /// core: five threads beside the script, past a whole core of CPU at a track
    /// change. Measured on an allocation-heavy script, one marker did the same
    /// work in 45% less CPU (2.8 s against 5.1 s), never above one core, for
    /// about a fifth more wall time; the peak heap was the same. The script's
    /// results are untouched: this only decides how many threads collect.
    /// An explicit setting in the environment still wins.
    nonisolated private static func tuneJavaScriptCore() {
        setenv("JSC_numberOfGCMarkers", "1", 0)
    }

    let controller = PlaybackController()
    let appModel = AppModel()
    let auth = AuthController()

    private init() {}

    /// Wait for the app to finish coming up before an intent touches the network
    /// or the engine.
    ///
    /// The launch task installs the cipher and PoToken wiring that a stream
    /// resolution depends on, and the app reports itself ready when the first
    /// content lands (or after its own two-second fallback). An app that is
    /// already running — the usual case for "play" and "like" — returns at once.
    func waitUntilReady() async {
        await LaunchReadiness.shared.waitForContent()
    }
}

// MARK: - What an intent may say

/// The ways a BitChord intent can fail, in words Siri can say.
///
/// `LocalizedError` rather than a bare error carrying a message: Shortcuts speaks
/// the error's `localizedDescription`, and an ordinary struct reads "The operation
/// couldn't be completed. (BitChordIntentError error 1.)" — the same trap the
/// session-expiry matcher hit in I10a-1.
enum BitChordIntentError: LocalizedError {
    case emptyQuery
    case nothingPlaying
    case signedOut
    case noResults(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            "What should BitChord look for?"
        case .nothingPlaying:
            "Nothing is playing in BitChord."
        case .signedOut:
            "Sign in to BitChord to like songs."
        case .noResults(let query):
            "BitChord couldn't find a song for “\(query)”."
        case .refused(let message):
            message
        }
    }
}

// MARK: - A song, for Siri and Shortcuts

/// A song as Siri and Shortcuts see it.
///
/// The identifier is the whole entity rather than the video id, because a resolved
/// entity has to survive being saved in a shortcut and resolved again in a later
/// process. The query keeps no cache to look a bare id up in, so a title known
/// when the shortcut was made would otherwise be lost — and a queue row showing an
/// opaque id is worse than no shortcut at all.
struct SongEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Song"
    static var defaultQuery = SongQuery()

    var videoId: String
    var title: String
    var artist: String

    var id: String {
        let parts = [videoId, title, artist]
        guard let data = try? JSONEncoder().encode(parts),
              let encoded = String(data: data, encoding: .utf8) else { return videoId }
        return encoded
    }

    var displayRepresentation: DisplayRepresentation {
        artist.isEmpty
            ? DisplayRepresentation(title: "\(title)")
            : DisplayRepresentation(title: "\(title)", subtitle: "\(artist)")
    }

    init(videoId: String, title: String, artist: String) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
    }

    /// Rebuilds an entity from one of its identifiers. Nil for anything that is
    /// not one, so a shortcut saved against another app cannot be misread.
    init?(id: String) {
        guard let data = id.data(using: .utf8),
              let parts = try? JSONDecoder().decode([String].self, from: data),
              parts.count == 3, !parts[0].isEmpty else { return nil }
        self.init(videoId: parts[0], title: parts[1], artist: parts[2])
    }
}

/// How Siri and Shortcuts find a song: the app's own search, and nothing more.
///
/// Deliberately cheap — no stream resolution, no player access — because the
/// system may run this while somebody is still typing, to offer completions.
struct SongQuery: EntityStringQuery {
    func entities(for identifiers: [SongEntity.ID]) async throws -> [SongEntity] {
        identifiers.compactMap { SongEntity(id: $0) }
    }

    func entities(matching string: String) async throws -> [SongEntity] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let hits = try await InnertubeSearch.shared.search(term, scope: "songs")
        var seen = Set<String>()
        return hits
            .filter { $0.isTrack && !$0.id.isEmpty && seen.insert($0.id).inserted }
            .prefix(10)
            .map { SongEntity(videoId: $0.id, title: $0.title, artist: $0.resolvedArtist) }
    }

    /// What Siri matches a spoken title against.
    ///
    /// An App Shortcut's phrase parameter is matched against the values the app
    /// *suggests*, not against free text — an empty list leaves Siri asking
    /// "Which song?" no matter what was said. These are the rows already on disk
    /// (the last queue, i.e. the most recent plays), so the call stays free of
    /// network and is cheap enough for the system to run while somebody types.
    func suggestedEntities() async throws -> [SongEntity] {
        await CachedSongs.suggestions()
    }
}

/// The songs this device can name without asking the network.
///
/// The last queue is the only cached list that carries both a catalogue id and a
/// title: a downloaded track is a file with no id, and a liked id carries no
/// title. That makes it the honest half of "recent plays plus the library" —
/// the other half would be a network fetch, which this call must not do.
@MainActor
private enum CachedSongs {
    private static let limit = 50

    static func suggestions() -> [SongEntity] {
        var seen = Set<String>()
        var songs: [SongEntity] = []
        for entry in LastPlayed.load()?.tracks ?? [] {
            guard let videoId = entry.videoId,
                  !videoId.isEmpty,
                  !entry.title.isEmpty,
                  seen.insert(videoId).inserted else { continue }
            songs.append(SongEntity(videoId: videoId, title: entry.title, artist: entry.artist))
            if songs.count == limit { break }
        }
        return songs
    }
}

// MARK: - The verbs

/// What the intents do, on the main actor because the player and the navigation
/// model live there.
///
/// Kept apart from the intents themselves so an intent stays what Siri needs: a
/// title, a parameter and the sentence to say back.
@MainActor
enum AppIntentActions {
    /// Play or pause, and say which happened.
    static func togglePlayback() async throws -> String {
        let controller = AppServices.shared.controller
        guard let current = controller.current else { throw BitChordIntentError.nothingPlaying }
        // The state is read *before* the toggle: `togglePlayPause` starts (or
        // keeps) an asynchronous load, so what it leaves behind is not always the
        // outcome this call asked for, and reading it after named the wrong one.
        let wasPlaying = controller.isPlaying || controller.isBuffering
        controller.togglePlayPause()
        return wasPlaying ? "Paused \(current.title)" : "Playing \(current.title)"
    }

    /// Play the song Siri resolved, with the search page it came from as the
    /// queue.
    ///
    /// The entity is one row and a queue is a whole answer, so the page is asked
    /// for again here rather than carried through the query. The page is only
    /// used when it still contains the picked track — a remix title or an artist
    /// spelled differently must play the track the listener picked, not the first
    /// row that came back instead.
    static func play(song: SongEntity) async throws -> String {
        await AppServices.shared.waitUntilReady()
        let controller = AppServices.shared.controller
        let entries = (try? await tracks(matching: "\(song.title) \(song.artist)")) ?? []
        if let start = entries.firstIndex(where: { $0.id == song.videoId }) {
            controller.play(entries, at: start, context: "Siri")
        } else {
            let entry = QueueEntry.youtube(
                videoId: song.videoId,
                title: song.title,
                artist: song.artist
            )
            controller.play([entry], at: 0, context: "Siri")
        }
        return song.title
    }

    /// Open Search with the term already in the field — the same request shape a
    /// `bitchord://search` link makes, so both roads end in the same place.
    static func search(query: String) throws -> String {
        let term = try cleaned(query)
        let appModel = AppServices.shared.appModel
        appModel.pendingSearchQuery = term
        appModel.requestedTab = .search
        appModel.focusSearch = true
        return term
    }

    /// Like or unlike what is playing.
    static func likeCurrent() async throws -> String {
        let services = AppServices.shared
        guard services.auth.signedIn else { throw BitChordIntentError.signedOut }
        guard let current = services.controller.current, let videoId = current.videoId else {
            throw BitChordIntentError.nothingPlaying
        }
        if let failure = await services.controller.toggleLikeAndWait(videoId: videoId) {
            throw BitChordIntentError.refused(failure)
        }
        return services.controller.isLiked
            ? "Liked \(current.title)"
            : "Removed \(current.title) from Liked Music"
    }

    /// Add the resolved song to the end of the queue without disturbing what is
    /// playing. With an idle player this also starts it, which is what an empty
    /// queue under "add to queue" has to mean.
    static func addToQueue(song: SongEntity) async throws -> String {
        await AppServices.shared.waitUntilReady()
        let entry = QueueEntry.youtube(
            videoId: song.videoId,
            title: song.title,
            artist: song.artist
        )
        AppServices.shared.controller.addToQueue(entry)
        return song.title
    }

    /// The playable rows for a term, deduped and capped at a queue's worth.
    ///
    /// A search page lists the same recording twice often enough — the promoted
    /// top result and the row below it — and a queue holding one song twice is a
    /// Next that appears to do nothing.
    private static func tracks(matching term: String) async throws -> [QueueEntry] {
        let hits = try await InnertubeSearch.shared.search(term, scope: "songs")
        var seen = Set<String>()
        return hits
            .filter { $0.isTrack && !$0.id.isEmpty && seen.insert($0.id).inserted }
            .prefix(10)
            .map { $0.asEntry() }
    }

    private static func cleaned(_ query: String) throws -> String {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw BitChordIntentError.emptyQuery }
        return term
    }
}

// MARK: - The intents

/// Play or pause what is already loaded. Background-capable: a listener who says
/// "pause" is not asking for a window.
struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Play or pause what BitChord is playing.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = try await AppIntentActions.togglePlayback()
        return .result(dialog: "\(line)")
    }
}

/// Play a song by name. The app opens because the match is a guess — the player
/// and the queue are where a listener checks it — and because a cold launch's
/// stream wiring settles behind the first window.
struct PlaySongIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Song"
    static var description = IntentDescription("Search BitChord for a song and start playing it.")
    static var openAppWhenRun = true

    @Parameter(title: "Song", requestValueDialog: "Which song?")
    var song: SongEntity

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = try await AppIntentActions.play(song: song)
        return .result(dialog: "Playing \(title) in BitChord")
    }
}

/// Open Search with a term. The one intent that must open the app: its whole
/// result is the screen.
struct SearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Search"
    static var description = IntentDescription("Open BitChord's search with a query.")
    static var openAppWhenRun = true

    @Parameter(title: "Search For", requestValueDialog: "What should BitChord search for?")
    var query: String

    init() {}

    init(query: String) {
        self.query = query
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let term = try await AppIntentActions.search(query: query)
        return .result(dialog: "Searching BitChord for \(term)")
    }
}

/// Like or unlike the current track. Background-capable for the same reason as
/// pause — and because liking needs something playing, which means this app is
/// already alive in the audio session.
struct LikeCurrentSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Like the Current Song"
    static var description = IntentDescription("Like or unlike what is playing in BitChord.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = try await AppIntentActions.likeCurrent()
        return .result(dialog: "\(line)")
    }
}

/// Add a song by name to the end of the queue.
struct AddToQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to the Queue"
    static var description = IntentDescription("Find a song and add it to the end of BitChord's queue.")
    static var openAppWhenRun = true

    @Parameter(title: "Song", requestValueDialog: "Which song?")
    var song: SongEntity

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$song) to the queue")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = try await AppIntentActions.addToQueue(song: song)
        return .result(dialog: "Added \(title) to the queue")
    }
}

// MARK: - Siri and Spotlight phrases

/// The phrases Siri answers to, and the entry points Spotlight lists.
///
/// Shortcuts does not need this: every intent above is already a Shortcuts action
/// by existing. These phrases are what make them reachable by voice and from a
/// Spotlight search for the app.
struct BitChordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Play \(\.$song) in \(.applicationName)",
                "Play \(\.$song) on \(.applicationName)"
            ],
            shortTitle: "Play a Song",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Play or pause \(.applicationName)"
            ],
            shortTitle: "Play or Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: SearchIntent(),
            phrases: ["Search in \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: LikeCurrentSongIntent(),
            phrases: ["Like this song in \(.applicationName)"],
            shortTitle: "Like This Song",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: AddToQueueIntent(),
            phrases: ["Add \(\.$song) to the queue in \(.applicationName)"],
            shortTitle: "Add to Queue",
            systemImageName: "text.badge.plus"
        )
    }
}

/// Ask the system to re-read what Siri may match against.
///
/// The suggestion list is resolved when a shortcut runs, and the system caches it
/// until the app says otherwise. Throttled: a track change is not worth a
/// parameter update each time, and what the list says changes only as the queue
/// does.
@MainActor
enum AppShortcutRefresh {
    private static var lastUpdate = Date.distantPast
    private static let interval: TimeInterval = 300

    static func schedule() {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= interval else { return }
        lastUpdate = now
        BitChordShortcuts.updateAppShortcutParameters()
    }
}
