import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// Signed-in YouTube Music library: playlists, albums, artists.
///
/// Upstream's `library()` feed — the same shelves `LibraryLandingView` shows
/// signed-in users on iPhone. The sidebar's Recent row is this feed as a
/// destination (it owns its title and toolbar like every other locked
/// section, since the hosting `LibraryView` adds no outer chrome).
struct YoutubeLibraryView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if !auth.signedIn {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Sign in for your library",
                    subtitle: "Liked playlists, albums and artists live here.",
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else if loading {
                ScrollView { FeedSkeleton() }
            } else if let error, shelves.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Library couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if shelves.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Nothing saved yet",
                    subtitle: "Playlists, albums and artists you save show up here.",
                    buttonTitle: nil, action: nil
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ReplayHeroSection { page in appModel.openReplay(at: page) }
                        ForEach(pinnedShelves(shelves)) { shelf in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(shelf.title).font(.title3.weight(.bold))
                                    Spacer()
                                    if shelf.items.count > 5 {
                                        PushLink("Show all") {
                                            LibraryGridView(title: shelf.title, items: shelf.items, isPlaylists: isPlaylistsShelf(shelf))
                                        }
                                        .font(.callout)
                                    }
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 14) {
                                        if isPlaylistsShelf(shelf) {
                                            NewPlaylistTile {
                                                appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                                            }
                                        }
                                        ForEach(displayItems(shelf)) { card in
                                            ShelfCardView(card: card)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle("Recent")
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

    private func pinnedShelves(_ shelves: [FeedShelf]) -> [FeedShelf] {
        let pinned = PlatformSettings.shared.getString(key: "pinned_playlists", default: "")
            .split(separator: ",").map(String.init)
        return shelves.map { shelf in
            let items = shelf.items.sorted { a, b in
                let ap = pinned.contains(a.browseId ?? "")
                let bp = pinned.contains(b.browseId ?? "")
                if ap == bp { return false }
                return ap && !bp
            }
            return FeedShelf(title: shelf.title, items: items, subtitle: shelf.subtitle)
        }
    }

    /// Upstream's `LIBRARY_ROW_MAX_ITEMS`: a Library row stops at five cards,
    /// with "Show all" opening the rest as a grid. The leading New Playlist
    /// tile counts against the cap.
    private func displayItems(_ shelf: FeedShelf) -> [ShelfCard] {
        let cap = isPlaylistsShelf(shelf) ? 4 : 5
        return Array(shelf.items.prefix(cap))
    }

    private func isPlaylistsShelf(_ shelf: FeedShelf) -> Bool {
        let t = shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "playlists"
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

/// Upstream's `NewShelfCard` on the Library's playlist row: a dashed tile that
/// creates a playlist, sized to sit in line with the covers beside it.
struct NewPlaylistTile: View {
    var onCreate: () -> Void

    var body: some View {
        Button(action: onCreate) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(.secondary)
                        .frame(width: 160, height: 160)
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                Text("New Playlist")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("Saved to YouTube Music")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New playlist")
        .accessibilityHint("Creates a playlist")
    }
}

/// One `.m3u`/`.m3u8` playlist from the scanned music folder.
struct LocalM3uPlaylist: Identifiable {
    let id: String
    let name: String
    let tracks: [LocalTrack]
}

/// The tracks of one local `.m3u` playlist.
struct LocalM3uDetailView: View {
    let playlist: LocalM3uPlaylist
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        List {
            ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                SongRow(
                    entry: QueueEntry.from(track),
                    play: {
                        controller.play(playlist.tracks.map(QueueEntry.from), at: index, context: playlist.name, contextID: "m3u:\(playlist.id)")
                    },
                    playNext: { controller.playNext(QueueEntry.from(track)) },
                    addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
    }
}
