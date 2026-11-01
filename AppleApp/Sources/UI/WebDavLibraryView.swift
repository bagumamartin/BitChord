import SwiftUI
import BitChordShared

/// A WebDAV share, read as a library.
///
/// Upstream's `local:webdav` detail page, and the same three states it has: a share
/// that answered with tracks, a share that answered with none, and a share that
/// refused. They are drawn differently on purpose — see [WebDavStore.State] — because
/// "no audio files" sent to somebody whose password has changed is a bug report they
/// file and we cannot answer.
///
/// The albums are the folders on the share, which is what makes this feel like a
/// library rather than a file listing without reading a single tag.
struct WebDavLibraryView: View {
    @Environment(PlaybackController.self) private var controller
    @State private var store = WebDavStore.shared
    /// Where the page was when it last loaded, so a change to the share is a
    /// deliberate re-read rather than a silent one.
    @State private var loadedFor: String = ""

    var body: some View {
        content
            .navigationTitle("WebDAV")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                TopBarLeadingItems()
                ToolbarItem(placement: .topBarTrailing) {
                    TopBarAccountButton()
                }
            }
            #endif
            .task(id: store.url) {
                // Keyed on the address, so pointing the app at a different share
                // re-reads rather than showing the old one's albums — and a share that
                // was just set up loads on arrival instead of waiting for a pull.
                guard loadedFor != store.url else { return }
                loadedFor = store.url
                await store.load(force: true)
            }
            .refreshable { await store.load(force: true) }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .notConfigured:
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No remote library yet",
                subtitle: "Point BitChord at a WebDAV share in Sources and it will appear here.",
                buttonTitle: nil,
                action: nil
            )
        case .loading:
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Nothing on that share",
                subtitle: "The server answered and there is no audio in it. If you expected a folder here, it may be somewhere else on the share.",
                buttonTitle: nil,
                action: nil
            )
        case .failed(let message):
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Can’t read that share",
                subtitle: message,
                buttonTitle: "Try Again",
                action: { Task { await store.load(force: true) } }
            )
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            Section {
                header
            }
            if !conflicts.isEmpty {
                Section {
                    Button {
                        activeConflict = conflicts.first
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conflictTitle)
                                    .foregroundStyle(.primary)
                                Text("Same song in Downloads and on this share. Choose which copy wins.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Sync Conflicts")
                }
            }
            ForEach(store.albums) { album in
                Section {
                    ForEach(Array(album.songs.enumerated()), id: \.element.videoId) { _, song in
                        SongRow(
                            entry: entry(for: song),
                            play: { play(song) }
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                    }
                } header: {
                    AlbumHeader(album: album)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("WebDAV")
        .sheet(item: $activeConflict) { conflict in
            WebDavConflictAlert(
                conflict: conflict,
                rest: conflicts.filter { $0.id != conflict.id },
                onDone: { next in activeConflict = next }
            )
        }
    }
    @State private var activeConflict: WebDavConflict?

    /// Every local download that names the same song as a remote track.
    ///
    /// Both sides are read live — the remote listing from `WebDavStore`, the
    /// local files from `DownloadStore` — so a conflict that was resolved by
    /// deleting a copy disappears without any bookkeeping here.
    private var conflicts: [WebDavConflict] {
        WebDavConflictDetector.conflicts(
            remote: store.albums.flatMap(\.songs),
            local: DownloadStore.shared.items
        )
    }

    private var conflictTitle: String {
        conflicts.count == 1 ? "1 track in two places" : "\(conflicts.count) tracks in two places"
    }

    /// Which share this is, and how much of it there is.
    ///
    /// Above the tracks rather than in a toolbar, because it is the answer to the
    /// question a remote page raises first — is this the share I meant? — and a
    /// toolbar title is the worst place on a Mac window to put a sentence.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var countLabel: String {
        let albums = store.albums.count
        let tracks = store.trackCount
        let albumWord = albums == 1 ? "album" : "albums"
        let trackWord = tracks == 1 ? "track" : "tracks"
        return "\(albums) \(albumWord) · \(tracks) \(trackWord)"
    }

    private func entry(for song: Song) -> QueueEntry { QueueEntry.from(song) }

    /// Play a track, with the rest of the share behind it.
    ///
    /// The whole share rather than the album, because a queue that stopped at the end
    /// of an album is not what anybody means by pressing play in a library, and
    /// re-ordering by hand is a worse answer than a sensible one.
    private func play(_ song: Song) {
        let entries = store.albums.flatMap { $0.songs }.map(entry(for:))
        guard let index = entries.firstIndex(where: { $0.id == song.videoId }) else { return }
        controller.play(entries, at: index)
    }
}

/// One folder's heading: its cover, and its name.
private struct AlbumHeader: View {
    let album: WebDavStore.RemoteAlbum

    var body: some View {
        HStack(spacing: 10) {
            // The embedded cover is only asked for when no picture was filed: the
            // task behind `remoteId` runs whatever the other fields say, and a folder
            // with a real `cover.jpg` should not pay for a ranged read to find out
            // that it does not need one. Upstream resolves the first track's embedded
            // picture the same way.
            ArtworkView(
                url: album.coverUrl,
                data: nil,
                side: 34,
                remoteId: album.coverUrl == nil ? album.id : nil
            )
            .clipShape(.rect(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(album.name ?? "Unknown album")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(album.songs.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name ?? "Unknown album"), \(album.songs.count) tracks")
    }
}

// MARK: - Sync conflicts

/// One song living in two libraries: a finished download on this device and a
/// track on the configured WebDAV share.
///
/// Upstream meets this as a name clash mid-upload (`WebDavConflictAlert`) with
/// three outcomes. There is no upload path on this platform, so the clash is
/// met where the two copies are both visible — this library — and the data is
/// the real thing on both sides: the remote album the share filed the track
/// under, and the local file's size and modification date read off the disk.
struct WebDavConflict: Identifiable, Equatable {
    /// Remote track id + local path: the two provenances that make it a clash.
    let id: String
    let title: String
    let artist: String
    let remoteAlbum: String?
    let localPath: String
    let localSize: Int64?
    let localModified: Date?
}

/// The clash detector: same song, two libraries.
///
/// Matched on normalized title plus artist — case, diacritics and punctuation
/// folded away, because "Café" on the share and "Cafe (Remastered)"... no:
/// only true normalizations match, never guesses. A featured-artist credit in
/// one library and not the other is still the same song when the title agrees
/// and both artists name the same lead, which is why the artist half matches on
/// containment rather than equality.
enum WebDavConflictDetector {
    static func conflicts(remote: [Song], local: [DownloadedTrack]) -> [WebDavConflict] {
        var out: [WebDavConflict] = []
        for item in local {
            let localTitle = normalize(item.title)
            guard !localTitle.isEmpty else { continue }
            let localArtist = normalize(item.artist)
            guard let match = remote.first(where: { song in
                normalize(song.title) == localTitle && artistsAgree(localArtist, normalize(song.artist))
            }) else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value
            let modified = attributes?[.modificationDate] as? Date
            out.append(WebDavConflict(
                id: "\(match.videoId)|\(item.path)",
                title: item.title,
                artist: item.artist,
                remoteAlbum: match.albumName,
                localPath: item.path,
                localSize: size,
                localModified: modified
            ))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func artistsAgree(_ local: String, _ remote: String) -> Bool {
        if local.isEmpty || remote.isEmpty { return true }
        if local == remote { return true }
        return local.contains(remote) || remote.contains(local)
    }
}

/// Upstream `WebDavConflictAlert`, in a native sheet.
///
/// Keep Both is the emphasised, non-destructive answer — the copies live in
/// different libraries and coexisting is a state that needs no work. Keep
/// Remote deletes the local file for real and refreshes Downloads; Skip leaves
/// this one undecided and moves on. With several clashes queued, Apply to All
/// carries the same answer through the rest.
struct WebDavConflictAlert: View {
    let conflict: WebDavConflict
    let rest: [WebDavConflict]
    /// The next conflict to show, or nil to close.
    let onDone: (WebDavConflict?) -> Void

    @Environment(ToastCenter.self) private var toast
    @State private var applyToAll = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("“\(conflict.title)” is in two places")
                    .font(.headline)
                Text("This download and a track on your WebDAV share name the same song.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Group {
                    HStack {
                        Text("On this device").foregroundStyle(.secondary)
                        Spacer()
                        Text(localDetail).monospacedDigit()
                    }
                    HStack {
                        Text("On the share").foregroundStyle(.secondary)
                        Spacer()
                        Text(remoteDetail)
                    }
                }
                .font(.subheadline)
                if !rest.isEmpty {
                    Toggle("Apply to all \(rest.count + 1) conflicts", isOn: $applyToAll)
                        .font(.subheadline)
                }
                Spacer(minLength: 8)
                Button("Keep Both") {
                    toast.show("Kept both copies of “\(conflict.title)”")
                    advance(deletingLocal: false, applyEverywhere: true)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                Button("Keep Remote — Delete Local Copy", role: .destructive) {
                    advance(deletingLocal: true, applyEverywhere: applyToAll)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                Button("Skip", role: .cancel) {
                    advance(deletingLocal: false, applyEverywhere: applyToAll)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .navigationTitle("Sync Conflict")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 400)
        #endif
    }

    private var localDetail: String {
        var parts: [String] = []
        if let size = conflict.localSize {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modified = conflict.localModified {
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? "Downloaded file" : parts.joined(separator: " · ")
    }

    private var remoteDetail: String {
        conflict.remoteAlbum ?? "On the share"
    }

    /// Resolve this conflict and, when asked, the rest behind it.
    ///
    /// Keeping both is a no-op whatever the toggle says — coexistence needs no
    /// work — so Apply to All only carries deletions and skips. Deletion is the
    /// real file removal plus a Downloads refresh, which is also what makes the
    /// resolved rows disappear from the list behind this sheet.
    private func advance(deletingLocal: Bool, applyEverywhere: Bool) {
        let targets = applyEverywhere && deletingLocal ? [conflict] + rest : [conflict]
        if deletingLocal {
            var removed = 0
            for target in targets {
                if (try? FileManager.default.removeItem(atPath: target.localPath)) != nil {
                    removed += 1
                }
            }
            DownloadStore.shared.refresh()
            toast.show(removed == 1
                ? "Deleted the local copy of “\(conflict.title)”"
                : "Deleted \(removed) local copies")
        }
        if applyEverywhere {
            onDone(nil)
        } else {
            onDone(rest.first)
        }
    }
}
