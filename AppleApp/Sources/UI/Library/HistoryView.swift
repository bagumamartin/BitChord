import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// Listening history page — signed-in `FEmusic_history`, newest first.
struct HistoryView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @State private var songs: [YouTubeSong] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if !auth.signedIn {
                EmptyStateView(
                    icon: Image(.bchClock),
                    title: "Sign in to see history",
                    subtitle: "Plays on this account show up here, newest first.",
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else if loading {
                // The list as it is about to be, not a spinner standing where
                // the list will be — upstream never shows a bare full-screen
                // spinner for list content.
                List {
                    ForEach(0..<9, id: \.self) { _ in
                        SkeletonSongRow()
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .accessibilityLabel("Loading")
            } else if let error, songs.isEmpty {
                EmptyStateView(
                    icon: Image(.bchClock),
                    title: "History couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if songs.isEmpty {
                EmptyStateView(
                    icon: Image(.bchClock),
                    title: "No listening history yet",
                    subtitle: "Tracks you play will show up here.",
                    buttonTitle: nil, action: nil
                )
            } else {
                List {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(
                                entry: QueueEntry(
                                    id: song.videoId, title: song.title, artist: song.artist,
                                    source: "yt:\(song.videoId)", thumbnailUrl: song.thumbnailUrl,
                                    durationText: song.durationText, albumName: song.albumName,
                                    artworkData: nil, isLocal: false
                                ),
                                play: {
                                    controller.play(songs.map {
                                        QueueEntry(
                                            id: $0.videoId, title: $0.title, artist: $0.artist,
                                            source: "yt:\($0.videoId)", thumbnailUrl: $0.thumbnailUrl,
                                            durationText: $0.durationText, albumName: $0.albumName,
                                            artworkData: nil, isLocal: false
                                        )
                                    }, at: index)
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("History")
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
            songs = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { songs = []; dataGeneration = generation }
        loading = songs.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.history(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            songs = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            AuthController.reportIfSessionExpired(error)
            self.error = error.localizedDescription
        }
        loading = false
    }
}
