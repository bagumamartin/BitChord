import SwiftUI
import BitChordShared

/// The playback cache, listed as songs rather than as files.
///
/// `StreamFileCache` keeps finished stream files on disk and knows nothing about
/// what a track is called, so the names come from `ListeningStore` — the same
/// rows Replay counts. A track that was never played cannot be in the cache, so
/// every entry has a name to show; an entry that somehow lacks one falls back to
/// its id rather than to an empty row.
struct CachedSongsView: View {
    @Environment(PlaybackController.self) private var controller

    @State private var entries: [StreamFileCache.CachedEntry] = []
    @State private var metadata: [String: ListeningStore.Track] = [:]
    @State private var loading = true
    @State private var confirmClear = false

    var body: some View {
        Group {
            if loading {
                List {
                    ForEach(0..<8, id: \.self) { _ in
                        SkeletonSongRow()
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .accessibilityLabel("Loading")
            } else if entries.isEmpty {
                EmptyStateView(
                    icon: Image(.bchMusicNote),
                    title: "Nothing cached",
                    subtitle: "Songs you play are kept on disk so they start instantly and play again offline.",
                    buttonTitle: nil,
                    action: nil
                )
            } else {
                list
            }
        }
        .navigationTitle("Cached Songs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear All", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear the song cache?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear \(totalSize)", role: .destructive) {
                Task {
                    await StreamFileCache.shared.clear()
                    await load()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every cached song is removed from this device. They will download again when played.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var list: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    Button {
                        let selected = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
                        let queue = entries.map { cached in
                            let track = metadata[cached.videoId]
                            let source = cached.videoId.hasPrefix("src:") || cached.videoId.hasPrefix("saavn:") ? cached.videoId : "yt:" + cached.videoId
                            return QueueEntry(id: cached.videoId, title: track?.title ?? cached.videoId,
                                artist: track?.artist ?? "", source: source, thumbnailUrl: track?.art,
                                albumName: track?.album, isLocal: false)
                        }
                        controller.play(queue, at: selected, context: "Cached songs", contextID: "cached:songs")
                    } label: { row(entry) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await remove(entry) }
                            }
                        }
                        .contextMenu {
                            Button("Remove from Cache", systemImage: "trash", role: .destructive) {
                                Task { await remove(entry) }
                            }
                        }
                }
            } footer: {
                Text("\(entries.count) \(entries.count == 1 ? "song" : "songs") · \(totalSize)")
            }
        }
        .listStyle(.plain)
    }

    private func row(_ entry: StreamFileCache.CachedEntry) -> some View {
        let track = metadata[entry.videoId]
        return HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? entry.videoId)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let artist = track?.artist, !artist.isEmpty {
                        Text(artist).lineLimit(1)
                        Text("·")
                    }
                    Text(entry.codec.isEmpty ? Self.size(entry.bytes) : "\(entry.codec) · \(Self.size(entry.bytes))")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var totalSize: String {
        Self.size(entries.reduce(Int64(0)) { $0 + $1.bytes })
    }

    private func load() async {
        let cached = await StreamFileCache.shared.entries()
        let names = ListeningStore.shared.trackMetadata()
        entries = cached
        metadata = names
        loading = false
    }

    private func remove(_ entry: StreamFileCache.CachedEntry) async {
        await StreamFileCache.shared.remove(entry.videoId)
        await load()
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
