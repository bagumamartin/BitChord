import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// The scanned-folder library with its in-page Songs/Albums/Artists picker.
///
/// This is the iPhone drill-down behind the On Device card. The sidebar's
/// Songs/Albums/Artists rows are NOT this screen: they are unified pages
/// (saved cloud collections + this device's files) built from the same
/// section pieces below.
struct LocalMusicView: View {
    var initialTab: Tab = .songs
    /// Navigation title. The sidebar row's name when opened from it
    /// ("Songs"/"Albums"/"Artists"); "Local Music" on the iPhone drill-down.
    var title: String = "Local Music"
    var onPickFolder: (() -> Void)? = nil
    @State private var local = LocalLibrary.shared
    @State private var selectedTab: Tab = .songs
    @State private var pickingFolder = false

    enum Tab: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        var id: String { rawValue }
    }

    init(initialTab: Tab = .songs, title: String = "Local Music", onPickFolder: (() -> Void)? = nil) {
        self.initialTab = initialTab
        self.title = title
        self.onPickFolder = onPickFolder
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        content
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
            }
            #endif
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    local.scanPicked(url)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if local.scanned {
                    tabPicker
                        .chromeGlass(in: Rectangle())
                }
            }
    }

    private var tabPicker: some View {
        Picker("Category", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: 380)
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

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .songs:
            LocalSongsBrowser(onPickFolder: pickFolder)
        case .albums:
            LocalAlbumGrid(onPickFolder: pickFolder)
        case .artists:
            LocalArtistList(onPickFolder: pickFolder)
        }
    }
}

/// The Songs half of the scanned-folder library: filter, sort, Play/Shuffle,
/// list/grid. Shared by the Local Music page and the unified Songs row.
struct LocalSongsBrowser: View {
    var onPickFolder: () -> Void
    @Environment(PlaybackController.self) private var controller
    @State private var local = LocalLibrary.shared

    @ViewBuilder
    var body: some View {
        if !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Scan your music",
                subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else if local.tracks.isEmpty {
            EmptyStateView(
                icon: Image(.bchMusicNote),
                title: "No audio files here",
                subtitle: "The folder you selected didn't contain any supported audio files.",
                buttonTitle: "Choose Another Folder"
            ) { onPickFolder() }
        } else {
            VStack(spacing: 0) {
                songsToolbar
                if local.visibleTracks.isEmpty {
                    EmptyStateView(
                        icon: Image(.bchSearch),
                        title: "Nothing matches",
                        subtitle: "No track in this library matches \u{201C}\(local.query)\u{201D}.",
                        buttonTitle: nil, action: nil
                    )
                } else {
                    songsContent
                }
            }
        }
    }

    private var songsToolbar: some View {
        HStack(spacing: 10) {
            SongFilterControls(local: local)

            Picker("View", selection: Bindable(local).viewType) {
                ForEach(LocalViewType.allCases) { type in
                    Image(systemName: type.symbol).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
            .help("List or grid")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var songsContent: some View {
        VStack(spacing: 0) {
            playShuffleBar
            switch local.viewType {
            case .list:
                List {
                    ForEach(Array(local.visibleTracks.enumerated()), id: \.element.id) { index, track in
                        SongRow(
                            entry: QueueEntry.from(track),
                            play: {
                                let shown = local.visibleTracks
                                controller.play(shown.map(QueueEntry.from), at: index, context: "On Device", contextID: "local:songs")
                            },
                            playNext: { controller.playNext(QueueEntry.from(track)) },
                            addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                    }
                }
                .listStyle(.plain)
            case .grid:
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)],
                        spacing: 20
                    ) {
                        ForEach(Array(local.visibleTracks.enumerated()), id: \.element.id) { index, track in
                            LocalTrackCard(track: track) {
                                let shown = local.visibleTracks
                                controller.play(shown.map(QueueEntry.from), at: index, context: "On Device", contextID: "local:songs")
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var playShuffleBar: some View {
        HStack(spacing: 12) {
            Button {
                controller.togglePlaybackContext(local.visibleTracks.map(QueueEntry.from), title: "On Device", contextID: "local:songs")
            } label: {
                Label(controller.isPlaybackContextPlaying("local:songs") ? "Pause" : "Play",
                      systemImage: controller.isPlaybackContextPlaying("local:songs") ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Button {
                controller.play(local.visibleTracks.map(QueueEntry.from), context: "On Device", contextID: "local:songs", shuffleRequested: true, shuffleStart: true)
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
        .padding(.vertical, 6)
    }
}

/// Filter capsule + sort menu for song lists, without the list/grid toggle.
/// Shared by the full browser and the unified Songs row's device section.
struct SongFilterControls: View {
    @Bindable var local: LocalLibrary

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter this library", text: $local.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter this library")
                if !local.query.isEmpty {
                    Button {
                        local.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())

            Spacer(minLength: 8)

            Menu {
                Picker("Sort By", selection: $local.sort) {
                    ForEach(local.sortOptions) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(local.sort.label, systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort this library")
        }
    }
}

/// The Albums half of the scanned-folder library. Shared by the Local Music
/// page and the unified Albums row's On This Device section.
struct LocalAlbumGrid: View {
    var onPickFolder: () -> Void
    @State private var local = LocalLibrary.shared

    @ViewBuilder
    var body: some View {
        if !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Scan your music",
                subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else if local.albumGroups.isEmpty {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No albums yet",
                subtitle: "Albums group themselves once a folder with tagged music is scanned.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                    ForEach(local.albumGroups, id: \.name) { group in
                        LocalAlbumCell(group: group)
                    }
                }
                .padding(20)
            }
        }
    }
}

/// One scanned-folder album: sleeve, name, artist. Tapping plays the album.
struct LocalAlbumCell: View {
    let group: (name: String, artist: String, tracks: [LocalTrack])
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        Button {
            controller.play(group.tracks.map(QueueEntry.from), context: group.name, contextID: "local-album:\(group.artist):\(group.name)")
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: group.tracks.first?.artworkURL, data: group.tracks.first?.artwork, side: 170)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                Text(group.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(group.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .modifier(MacCardHoverLift())
    }
}

/// The Artists half of the scanned-folder library. Shared by the Local Music
/// page and the unified Artists row's On This Device section.
struct LocalArtistList: View {
    var onPickFolder: () -> Void
    @State private var local = LocalLibrary.shared

    @ViewBuilder
    var body: some View {
        if !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Scan your music",
                subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else if local.artistGroups.isEmpty {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No artists yet",
                subtitle: "Artists group themselves once a folder with tagged music is scanned.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else {
            List {
                ForEach(local.artistGroups, id: \.name) { group in
                    ArtistGroupRow(group: group)
                        .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                }
            }
            .listStyle(.plain)
        }
    }
}
