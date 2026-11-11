import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// A saved-collections grid straight from one signed-in library shelf
/// (Subscriptions, Podcasts). Cards navigate to their detail pages like
/// every other shelf grid.
struct SavedShelfView: View {
    var shelfName = "Subscriptions"
    var title = "Subscriptions"
    var emptySubtitle: LocalizedStringKey = "Channels you subscribe to show up here."
    @Environment(AuthController.self) private var auth
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    private var items: [ShelfCard] {
        libraryShelf(titled: shelfName, in: shelves)?.items ?? []
    }

    var body: some View {
        Group {
            if !auth.signedIn {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Sign in for your library",
                    subtitle: emptySubtitle,
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else if loading {
                ScrollView { SkeletonGrid() }
            } else if let error, items.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "\(title) couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if items.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Nothing here yet",
                    subtitle: emptySubtitle,
                    buttonTitle: nil, action: nil
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                        ForEach(items) { card in
                            ShelfCardView(card: card)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            TopBarLeadingItems()
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func load(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { shelves = []; dataGeneration = generation }
        loading = shelves.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.library(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            AuthController.reportIfSessionExpired(error)
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The Playlists row: the signed-in Playlists shelf with the New Playlist
/// tile leading, like the library landing's playlist row but full-page.
struct SavedPlaylistsView: View {
    var title = "Playlists"
    var hostsWindowControls: Bool = false
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?
    @State private var showSpotifyImport = false
    // The file import, moved here from the old LocalPlaylistsView: the same
    // CSV/TSV/M3U flow, next to the Spotify link import it complements.
    @State private var showImportPicker = false
    @State private var importDraft: PlaylistImportDraft?
    @State private var matchingImport = false
    @State private var showImportMessage = false
    @State private var importMessage = ""
    @State private var local = LocalLibrary.shared
    @State private var m3uPlaylists: [LocalM3uPlaylist] = []

    private var items: [ShelfCard] {
        libraryShelf(titled: "playlists", in: shelves)?.items ?? []
    }

    /// Playlists kept on this device — Spotify imports saved locally, file
    /// imports, and the scanned folder's .m3u files. They show signed out too:
    /// they are this device's, not the account's.
    private var devicePlaylists: [ImportedPlaylist] {
        ImportedPlaylistStore.shared.playlists
    }

    var body: some View {
        Group {
            if loading && auth.signedIn {
                ScrollView { SkeletonGrid() }
            } else if let error, items.isEmpty, devicePlaylists.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Playlists couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if auth.signedIn {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                                NewPlaylistTile {
                                    appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                                }
                                ForEach(items) { card in
                                    ShelfCardView(card: card)
                                }
                            }
                        } else {
                            signedOutPrompt
                        }
                        if !devicePlaylists.isEmpty || !m3uPlaylists.isEmpty {
                            deviceSection
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .refreshable {
                    await load(force: true)
                    rescanM3u()
                }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            TopBarLeadingItems()
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Actions first, the account last: the profile is the
                // trailing item on every page, so it stays put here too.
                if auth.signedIn { spotifyImportButton }
                importFileButton
                TopBarAccountButton()
            }
        }
        #else
        .toolbar {
            if !appModel.nowPlayingPresented {
                if auth.signedIn {
                    ToolbarItem(placement: .primaryAction) { spotifyImportButton }
                }
                ToolbarItem(placement: .primaryAction) { importFileButton }
                if hostsWindowControls {
                    MacWindowControls()
                }
            }
        }
        #endif
        .sheet(isPresented: $showSpotifyImport) {
            SpotifyImportSheet()
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            prepareImport(result)
        }
        .sheet(item: $importDraft) { draft in
            PlaylistImportReviewView(draft: draft) { importError in
                importMessage = importError ?? "Playlist saved to BitChord. Reimporting this file will update the same playlist."
                showImportMessage = true
            }
        }
        .overlay {
            if matchingImport {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("Matching playlist tracks…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("Playlist Import", isPresented: $showImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
        .task(id: auth.sessionEpoch) { await load() }
        .onAppear {
            local.restoreViewPreferences()
            rescanM3u()
            // The Mac's File menu switches to this page and asks for an import; the
            // request can already be pending when the page appears.
            openPendingImport()
        }
        .onChange(of: appModel.spotifyImportPresented) { _, _ in openPendingImport() }
        .onChange(of: appModel.playlistFileImportPresented) { _, _ in openPendingImport() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryPlaylistsChanged)) { _ in
            Task { await load(force: true) }
        }
    }

    /// Opens whichever import the shell asked for (File ▸ Import), consuming the
    /// request so it fires once.
    private func openPendingImport() {
        if appModel.spotifyImportPresented {
            appModel.spotifyImportPresented = false
            showSpotifyImport = true
        }
        if appModel.playlistFileImportPresented {
            appModel.playlistFileImportPresented = false
            showImportPicker = true
        }
    }

    /// What the signed-out page shows instead of the account grid: the same
    /// sign-in offer the library landing uses, over the device playlists that
    /// are here regardless.
    private var signedOutPrompt: some View {
        VStack(spacing: 10) {
            Text("Sign in for your playlists")
                .font(.headline)
            Text("Playlists you save on YouTube Music show up here. Imports stay on this device either way.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign In") { auth.loginPresented = true }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On This Device")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(devicePlaylists) { playlist in
                    PushLink {
                        ImportedPlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.title).lineLimit(1)
                                Text("\(playlist.matchedCount) of \(playlist.tracks.count) tracks · \(playlist.sourceName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                            ImportedPlaylistStore.shared.remove(playlist)
                            NotificationCenter.default.post(name: .libraryPlaylistsChanged, object: nil)
                        }
                    }
                }
                ForEach(m3uPlaylists) { playlist in
                    PushLink {
                        LocalM3uDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).lineLimit(1)
                                Text("\(playlist.tracks.count) \(playlist.tracks.count == 1 ? "song" : "songs")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var spotifyImportButton: some View {
        Button("Import from Spotify", systemImage: "square.and.arrow.down") {
            showSpotifyImport = true
        }
        .help("Import a Spotify playlist by link")
    }

    private var importFileButton: some View {
        Button("Import Playlist File", systemImage: "doc.badge.plus") {
            showImportPicker = true
        }
        .help("Import a CSV, TSV or M3U playlist file")
    }

    private func load(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { shelves = []; dataGeneration = generation }
        loading = shelves.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.library(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            AuthController.reportIfSessionExpired(error)
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Reads the picked CSV/TSV/M3U, matches its rows to YouTube Music and
    /// hands the draft to the review sheet — the old LocalPlaylistsView's
    /// flow, which nothing else reached.
    private func prepareImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let importError):
            importMessage = importError.localizedDescription
            showImportMessage = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let parsed = try PlaylistFileImport.parse(data: Data(contentsOf: url), filename: url.lastPathComponent)
                Task {
                    matchingImport = true
                    defer { matchingImport = false }
                    let matched = await PlaylistFileImport.match(parsed)
                    importDraft = matched
                }
            } catch {
                importMessage = error.localizedDescription
                showImportMessage = true
            }
        }
    }

    private func rescanM3u() {
        m3uPlaylists = Self.m3uPlaylists(tracks: local.tracks)
    }

    /// Reads `.m3u`/`.m3u8` files from the scanned folder and resolves their
    /// entries against the scanned tracks by absolute path, then by filename.
    private static func m3uPlaylists(tracks: [LocalTrack]) -> [LocalM3uPlaylist] {
        guard let folder = libraryFolder() else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let m3uURLs = enumerator.compactMap { $0 as? URL }.filter {
            ["m3u", "m3u8"].contains($0.pathExtension.lowercased())
        }
        let byPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(
            tracks.map { (URL(fileURLWithPath: $0.path).lastPathComponent.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return m3uURLs.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let base = url.deletingLastPathComponent()
            var resolved: [LocalTrack] = []
            for line in text.components(separatedBy: .newlines) {
                let entry = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
                let candidate: URL = entry.hasPrefix("/")
                    ? URL(fileURLWithPath: entry)
                    : base.appendingPathComponent(entry)
                let standardized = candidate.standardized.path
                if let track = byPath[standardized] ?? byPath[candidate.path] {
                    resolved.append(track)
                } else if let track = byName[candidate.lastPathComponent.lowercased()] {
                    resolved.append(track)
                }
            }
            guard !resolved.isEmpty else { return nil }
            return LocalM3uPlaylist(
                id: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                tracks: resolved
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The scanned folder, resolved from the persisted bookmark — the same
    /// bookmark `LocalLibrary` restores, read here because the store does not
    /// expose the folder itself.
    static func libraryFolder() -> URL? {
        let stored = PlatformSettings.shared.getString(key: "local_library_path", default: "")
        guard !stored.isEmpty, let data = Data(base64Encoded: stored) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [],
            relativeTo: nil, bookmarkDataIsStale: &stale
        ) else { return nil }
        return url
    }
}

/// The signed-in library shelf coined under this title by the shared bridge
/// (`LibraryBridge` fetches Playlists/Albums/Artists/Subscriptions in
/// parallel). Titles are matched case-insensitively like the Playlists shelf.
func libraryShelf(titled name: String, in shelves: [FeedShelf]) -> FeedShelf? {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return shelves.first {
        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
    }
}
