import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// The Songs row: liked tracks from the signed-in library on top, this
/// device's scanned songs below. Either half alone is a complete page, so
/// the row is never the empty "choose a folder" wall it used to be.
struct UnifiedSongsView: View {
    var title = "Songs"
    var onPickFolder: (() -> Void)? = nil
    var hostsWindowControls: Bool = false
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var local = LocalLibrary.shared
    @State private var pickingFolder = false
    @State private var songs: [YouTubeSong] = []
    @State private var dataGeneration: Int64?
    @State private var songsLoading = true
    @State private var songsError: String?

    private var cloudEntries: [QueueEntry] { songs.map(songEntry) }

    private func songEntry(_ song: YouTubeSong) -> QueueEntry {
        QueueEntry(
            id: song.videoId, title: song.title, artist: song.artist,
            source: "yt:\(song.videoId)", thumbnailUrl: song.thumbnailUrl,
            durationText: song.durationText, albumName: song.albumName,
            artworkData: nil, isLocal: false
        )
    }

    var body: some View {
        Group {
            if !auth.signedIn && !local.scanned {
                EmptyStateView(
                    icon: Image(.bchMusicNote),
                    title: "Your songs live here",
                    subtitle: "Songs you add to your YouTube Music library — or a folder you scan on this device.",
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else {
                List {
                    if auth.signedIn {
                        Section("Your Songs") {
                            if songsLoading {
                                SkeletonRows(count: 6)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            } else if let songsError, songs.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(songsError)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Button("Try again") {
                                        Task { await loadSongs() }
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.tint)
                                }
                            } else if songs.isEmpty {
                                Text("Songs you add to your library show up here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                    SongRow(
                                        entry: songEntry(song),
                                        play: { controller.play(cloudEntries, at: index, context: title, contextID: "library:songs") },
                                        playNext: { controller.playNext(songEntry(song)) },
                                        addToQueue: { controller.addToQueue(songEntry(song)) }
                                    )
                                }
                            }
                        }
                    }
                    Section("On This Device") {
                        if !local.scanned {
                            Button {
                                pickFolder()
                            } label: {
                                HStack {
                                    Text("Scan a folder to see its songs here too.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            SongFilterControls(local: local)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                            if local.visibleTracks.isEmpty {
                                Text(local.tracks.isEmpty ? "No audio files in the scanned folder." : "Nothing matches the current filter.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(local.visibleTracks.enumerated()), id: \.element.id) { index, track in
                                    SongRow(
                                        entry: QueueEntry.from(track),
                                        play: {
                                            controller.play(local.visibleTracks.map(QueueEntry.from), at: index, context: "On Device", contextID: "local:songs")
                                        },
                                        playNext: { controller.playNext(QueueEntry.from(track)) },
                                        addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                // ↑/↓ walk the page's songs, cloud section first, exactly as it
                // is drawn: the keyboard focus follows the selection and Return
                // plays what the arrows landed on.
                .rowKeyboardNavigation(ids: cloudEntries.map(\.id) + local.visibleTracks.map { QueueEntry.from($0).id })
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            TopBarLeadingItems()
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    pickFolder()
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .toolbarChrome(in: Circle())
                }
                .buttonStyle(ProfileCircleButtonStyle())
                .accessibilityLabel("Scan a folder")

                TopBarAccountButton()
            }
        }
        #else
        .toolbar {
            if !appModel.nowPlayingPresented {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pickFolder()
                    } label: {
                        Image(.bchPlus)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15)
                    }
                    .help("Scan a folder")
                    .accessibilityLabel("Scan a Folder")
                }
                if hostsWindowControls {
                    MacWindowControls()
                }
            }
        }
        #endif
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                local.scanPicked(url)
            }
        }
        .task(id: auth.sessionEpoch) { await loadSongs() }
    }

    private func loadSongs(force: Bool = false) async {
        guard auth.signedIn else {
            songsLoading = false
            songs = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { songs = []; dataGeneration = generation }
        songsLoading = songs.isEmpty
        songsError = nil
        do {
            let result = try await InnertubeFeed.shared.librarySongs(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            songs = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            self.songsError = error.localizedDescription
        }
        songsLoading = false
    }

    private func pickFolder() {
        if let onPickFolder {
            onPickFolder()
        } else {
            #if os(macOS)
            local.chooseFolder()
            #else
            pickingFolder = true
            #endif
        }
    }
}
