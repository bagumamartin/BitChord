import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// Dedicated Downloads destination with Songs, Albums, and Artists tabs,
/// matching upstream's unified LocalMusicScreen (isDownloads = true).
struct DownloadsView: View {
    @Environment(PlaybackController.self) private var controller
    @State private var store = DownloadStore.shared
    @State private var selectedTab: Tab = .songs
    @State private var searchQuery: String = ""
    @State private var sort: SortOption = .titleAsc
    /// Hold-to-select multi-delete (upstream's selection mode): a tap on a row
    /// while selecting toggles it instead of playing.
    @State private var selecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var confirmDelete = false
    @State private var webDavStore = WebDavStore.shared
    @State private var uploadingSelection = false
    @State private var showUploadSummary = false
    @State private var uploadSummary = ""
    @State private var showDownloadManager = false

    enum Tab: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        var id: String { rawValue }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case titleAsc = "Title (A–Z)"
        case titleDesc = "Title (Z–A)"
        case artist = "Artist"
        case album = "Album"
        var id: String { rawValue }
    }

    private var localTracks: [LocalTrack] {
        store.items.map { t in
            LocalTrack(
                path: t.path,
                title: t.title,
                artist: t.artist,
                album: t.album,
                durationSeconds: 0,
                artwork: t.artwork,
                trackNumber: 0,
                dateAdded: nil,
                dateModified: nil,
                artworkURL: t.artworkURL
            )
        }
    }

    private var filteredAndSortedTracks: [LocalTrack] {
        var result = localTracks
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(q) ||
                $0.artist.lowercased().contains(q) ||
                $0.album.lowercased().contains(q)
            }
        }
        switch sort {
        case .titleAsc:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .artist:
            result.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:
            result.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        }
        return result
    }

    private var albumGroups: [(name: String, artist: String, tracks: [LocalTrack])] {
        let grouped = Dictionary(grouping: filteredAndSortedTracks) { $0.album.isEmpty ? "Unknown Album" : $0.album }
        return grouped.map { name, tracks in
            (name: name, artist: tracks.first?.artist ?? "Unknown artist", tracks: tracks)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var artistGroups: [(name: String, tracks: [LocalTrack])] {
        let grouped = Dictionary(grouping: filteredAndSortedTracks) { $0.artist.isEmpty ? "Unknown Artist" : $0.artist }
        return grouped.map { name, tracks in
            (name: name, tracks: tracks)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                if !store.jobs.isEmpty {
                    ScrollView { LazyVStack(spacing: 16) {
                        ForEach(store.jobs) { job in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(job.title).lineLimit(1)
                                    Text(store.activity(for: job)?.label ?? job.status.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let activity = store.activity(for: job) { DownloadProgressIndicator(activity: activity) }
                            }
                        }
                        Button("Manage downloads") { showDownloadManager = true }
                    }.padding(24) }
                } else { EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "No downloads yet",
                    subtitle: "Save a track from Now Playing — BitChord tags it and keeps it here.",
                    buttonTitle: nil, action: nil
                ) }
            } else {
                content
            }
        }
        .navigationTitle("Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            TopBarLeadingItems()
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .onAppear { store.refresh() }
        .sheet(isPresented: $showDownloadManager) { DownloadManagerView() }
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Manage downloads", systemImage: "arrow.down.circle") { showDownloadManager = true } } }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            tabPicker
            toolbar
            switch selectedTab {
            case .songs:
                songsContent
            case .albums:
                albumsContent
            case .artists:
                artistsContent
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

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter downloads", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())

            Spacer(minLength: 8)

            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if selectedTab == .songs, !filteredAndSortedTracks.isEmpty {
                Button {
                    selecting = true
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                        .labelStyle(.iconOnly)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: Circle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Select downloads")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    private func toggleSelection(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
        Haptics.play(.select)
    }

    private var playShuffleRow: some View {
        HStack(spacing: 12) {
            Button {
                controller.togglePlaybackContext(filteredAndSortedTracks.map(QueueEntry.from), title: "Downloads", contextID: "downloads:songs")
            } label: {
                Label(controller.isPlaybackContextPlaying("downloads:songs") ? "Pause" : "Play",
                      systemImage: controller.isPlaybackContextPlaying("downloads:songs") ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Button {
                controller.play(filteredAndSortedTracks.map(QueueEntry.from), context: "Downloads", contextID: "downloads:songs", shuffleRequested: true, shuffleStart: true)
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

    private var songsContent: some View {
        VStack(spacing: 0) {
            if !filteredAndSortedTracks.isEmpty, !selecting {
                playShuffleRow
            }
            if selecting {
                // Upstream's selection bar (LocalFolder.kt:687), with the
                // WebDAV batch action added alongside delete.
                HStack(spacing: 6) {
                    Button("Done") {
                        selecting = false
                        selectedPaths = []
                    }
                    .buttonStyle(.bordered)
                    Text(selectedPaths.count == 1 ? "1 selected" : "\(selectedPaths.count) selected")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Button("Select All") {
                        selectedPaths = Set(filteredAndSortedTracks.map(\.path))
                    }
                    .buttonStyle(.bordered)
                    Button(action: uploadSelectedDownloads) {
                        if uploadingSelection {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "icloud.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedPaths.isEmpty || uploadingSelection || !webDavStore.isConfigured)
                    .help("Upload selected to WebDAV")
                    .accessibilityLabel("Upload selected to WebDAV")
                    Button("Delete", role: .destructive) {
                        confirmDelete = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPaths.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            List {
                ForEach(Array(filteredAndSortedTracks.enumerated()), id: \.element.id) { index, track in
                    SongRow(
                        entry: QueueEntry.from(track),
                        play: {
                            if selecting {
                                toggleSelection(track.path)
                            } else {
                                controller.play(filteredAndSortedTracks.map(QueueEntry.from), at: index, context: "Downloads", contextID: "downloads:songs")
                            }
                        },
                        playNext: { controller.playNext(QueueEntry.from(track)) },
                        addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                    )
                    .opacity(selectedPaths.contains(track.path) ? 0.55 : 1)
                    .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                }
            }
            .listStyle(.plain)
        }
        .confirmationDialog("Delete the selected downloads?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(selectedPaths.count) download\(selectedPaths.count == 1 ? "" : "s")", role: .destructive) {
                let doomed = selectedPaths
                selectedPaths = []
                selecting = false
                for path in doomed { DownloadStore.shared.delete(path) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will download again when played.")
        }
        .alert("WebDAV upload", isPresented: $showUploadSummary) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uploadSummary)
        }
    }

    @MainActor
    private func uploadSelectedDownloads() {
        let selected = filteredAndSortedTracks.filter { selectedPaths.contains($0.path) }
        guard !selected.isEmpty, webDavStore.isConfigured, !uploadingSelection else { return }
        uploadingSelection = true
        Task { @MainActor in
            var uploaded = 0
            var failed = 0
            var firstFailure: String?
            for track in selected {
                do {
                    _ = try await webDavStore.upload(
                        path: track.path,
                        title: track.title,
                        artist: track.artist,
                        refreshAfterUpload: false
                    )
                    uploaded += 1
                } catch {
                    failed += 1
                    if firstFailure == nil { firstFailure = error.localizedDescription }
                }
            }
            if uploaded > 0 { await webDavStore.load(force: true) }
            uploadingSelection = false
            var summary = "Uploaded \(uploaded) of \(selected.count) selected download\(selected.count == 1 ? "" : "s")."
            if failed > 0 {
                summary += " Failed: \(failed)."
                if let firstFailure { summary += " \(firstFailure)" }
            }
            uploadSummary = summary
            showUploadSummary = true
        }
    }

    private var albumsContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 18)], spacing: 22) {
                ForEach(albumGroups, id: \.name) { group in
                    PushLink {
                        LocalGroupPage(
                            title: group.name,
                            subtitle: "\(group.artist) • \(group.tracks.count) song\(group.tracks.count == 1 ? "" : "s")",
                            artwork: group.tracks.first?.artwork,
                            tracks: group.tracks,
                            contextID: "local-album:\(group.artist):\(group.name)",
                            showsTrackNumbers: true
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ArtworkView(url: group.tracks.first?.artworkURL, data: group.tracks.first?.artwork, side: 160)
                                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            Text(group.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text("\(group.artist) • \(group.tracks.count) song\(group.tracks.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private var artistsContent: some View {
        List {
            ForEach(artistGroups, id: \.name) { group in
                ArtistGroupRow(group: group)
                    .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
            }
        }
        .listStyle(.plain)
    }
}
