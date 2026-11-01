import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// The Artists row: saved artists from the signed-in library, then this
/// device's scanned artists. Same contract as Songs and Albums.
struct UnifiedArtistsView: View {
    var title = "Artists"
    var onPickFolder: (() -> Void)? = nil
    var hostsWindowControls: Bool = false
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var local = LocalLibrary.shared
    @State private var pickingFolder = false
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    private var saved: [ShelfCard] {
        libraryShelf(titled: "artists", in: shelves)?.items ?? []
    }

    private var hasCloud: Bool { !saved.isEmpty }
    private var hasDevice: Bool { local.scanned && !local.artistGroups.isEmpty }

    var body: some View {
        Group {
            if auth.signedIn && loading {
                ScrollView { FeedSkeleton() }
            } else if let error, !hasDevice {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Artists couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if !hasCloud && !hasDevice {
                combinedEmpty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if hasCloud {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Saved Artists")
                                    .font(.title3.weight(.bold))
                                    .padding(.horizontal, 24)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                                    ForEach(saved) { card in
                                        ShelfCardView(card: card)
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                        }
                        if local.scanned {
                            if hasDevice {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("On This Device")
                                        .font(.title3.weight(.bold))
                                        .padding(.horizontal, 24)
                                    LazyVStack(spacing: 2) {
                                        ForEach(local.artistGroups, id: \.name) { group in
                                            ArtistGroupRow(group: group)
                                                .padding(.horizontal, 24)
                                        }
                                    }
                                }
                            } else {
                                Text("No artists in the scanned folder.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)
                            }
                        } else if hasCloud {
                            scanPrompt(kind: "artists")
                        }
                    }
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
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func scanPrompt(kind: String) -> some View {
        Button {
            pickFolder()
        } label: {
            HStack(spacing: 12) {
                Image(.bchLibrary)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Device")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Scan a folder to see its \(kind) here too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var combinedEmpty: some View {
        if !auth.signedIn && !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Your artists live here",
                subtitle: "Follow artists on YouTube Music — or scan a folder on this device.",
                buttonTitle: "Sign In"
            ) { auth.loginPresented = true }
        } else if local.scanned {
            EmptyStateView(
                icon: Image(.bchMusicNote),
                title: "No audio files here",
                subtitle: "The folder you selected didn't contain any supported audio files.",
                buttonTitle: "Choose Another Folder"
            ) { pickFolder() }
        } else {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No saved artists yet",
                subtitle: "Artists you follow on YouTube Music show up here — or scan a folder on this device.",
                buttonTitle: "Choose Folder"
            ) { pickFolder() }
        }
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

/// One artist with an expandable track list (tap plays the artist's songs).
/// One local artist: circular artwork from their first track and a push to
/// the artist's own page — upstream's ArtistRow (LocalFolder.kt:466), where a
/// tap opens the group rather than folding a track list into the row.
struct ArtistGroupRow: View {
    let group: (name: String, tracks: [LocalTrack])

    var body: some View {
        PushLink {
            LocalGroupPage(
                title: group.name,
                subtitle: "\(group.tracks.count) song\(group.tracks.count == 1 ? "" : "s")",
                artwork: group.tracks.first?.artwork,
                tracks: group.tracks,
                contextID: "local-artist:\(group.name)",
                circularArtwork: true
            )
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: group.tracks.first?.artworkURL, data: group.tracks.first?.artwork, side: 56)
                    .clipShape(.circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(group.tracks.count) song\(group.tracks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A local album's or artist's own page — upstream's ca66070e model, where a
/// folder group IS a release: cover header, play and shuffle, the songs.
struct LocalGroupPage: View {
    let title: String
    let subtitle: String
    let artwork: Data?
    let tracks: [LocalTrack]
    let contextID: String
    var circularArtwork = false
    var showsTrackNumbers = false
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ArtworkView(url: tracks.first?.artworkURL, data: artwork, side: 220)
                    .clipShape(.rect(cornerRadius: circularArtwork ? 110 : 12, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
                    .padding(.top, 12)

                VStack(spacing: 5) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)

                HStack(spacing: 12) {
                    Button {
                        controller.togglePlaybackContext(
                            tracks.map(QueueEntry.from), title: title, contextID: contextID
                        )
                    } label: {
                        Label(
                            controller.isPlaybackContextPlaying(contextID) ? "Pause" : "Play",
                            systemImage: controller.isPlaybackContextPlaying(contextID) ? "pause.fill" : "play.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())

                    Button {
                        controller.play(
                            tracks.map(QueueEntry.from), context: title, contextID: contextID,
                            shuffleRequested: true, shuffleStart: true
                        )
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 24)

                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        if showsTrackNumbers && track.trackNumber > 0 {
                            HStack(spacing: 10) {
                                Text(String(track.trackNumber))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 24, alignment: .trailing)
                                    .accessibilityLabel("Track \(track.trackNumber)")
                                songRow(track, index: index)
                            }
                        } else {
                            songRow(track, index: index)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func songRow(_ track: LocalTrack, index: Int) -> some View {
        SongRow(
            entry: QueueEntry.from(track),
            play: {
                controller.play(tracks.map(QueueEntry.from), at: index, context: title, contextID: contextID)
            },
            playNext: { controller.playNext(QueueEntry.from(track)) },
            addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
        )
    }
}
