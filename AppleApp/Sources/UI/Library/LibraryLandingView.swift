import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// Upstream's unified Library landing page (`LibraryScreen.kt`):
/// 1. Replay hero banner
/// 2. "On device" shelf: horizontal scroll with cards for Downloads, Local Music, WebDAV, History
/// 3. Signed-out prompt (if signed out)
/// 4. Signed-in shelves (if signed in): Playlists (with NewPlaylistTile and pinned first), Albums, Artists
struct LibraryLandingView: View {
    var onPickFolder: () -> Void
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @Environment(PlaybackController.self) private var controller
    @State private var downloadStore = DownloadStore.shared
    @State private var local = LocalLibrary.shared
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // 1. Replay hero: cards when there is listening data, banner before.
                ReplayHeroSection { page in appModel.openReplay(at: page) }

                // 2. On Device Shelf
                onDeviceShelf

                // 3. Signed-out prompt or Signed-in shelves
                if !auth.signedIn {
                    signedInPrompt
                    // Upstream keeps the Playlists row visible signed out, so the
                    // page still says where playlists will live and how to start
                    // one — its New Playlist tile asks for a sign-in instead of
                    // opening a picker that could not save anything.
                    shelfSection(FeedShelf(title: "Playlists", items: []))
                } else if loading {
                    FeedSkeleton(padded: false)
                } else if let error, shelves.isEmpty {
                    EmptyStateView(
                        icon: Image(.bchLibrary),
                        title: "Library couldn't load",
                        subtitle: error,
                        buttonTitle: "Retry"
                    ) { Task { await loadShelves() } }
                } else {
                    signedInShelves
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .refreshable {
            downloadStore.refresh()
            await loadShelves(force: true)
        }
        .task(id: auth.sessionEpoch) {
            downloadStore.refresh()
            await loadShelves()
        }
    }

    private var onDeviceShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On device")
                .font(.title3.weight(.bold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    // Upstream's On-Device shelf leads with the playlists and
                    // albums downloaded whole, as artwork cards, before the
                    // folder destinations — they are the things a listener is
                    // actually going offline to play.
                    ForEach(downloadStore.collections) { collection in
                        if let browseId = collection.browseId {
                            OnDeviceCard(
                                title: collection.title,
                                subtitle: "\(collection.requests.count) saved",
                                systemImage: "square.and.arrow.down.fill",
                                tintColor: .green,
                                destination: DetailView(browseId: browseId, initialTitle: collection.title)
                            )
                        }
                    }

                    OnDeviceCard(
                        title: "Downloads",
                        subtitle: "\(downloadStore.items.count) downloaded song\(downloadStore.items.count == 1 ? "" : "s")",
                        systemImage: "arrow.down.circle.fill",
                        tintColor: .accentColor,
                        destination: DownloadsView()
                    )

                    OnDeviceCard(
                        title: "Local Music",
                        subtitle: local.scanned ? "\(local.tracks.count) song\(local.tracks.count == 1 ? "" : "s")" : "Choose folder",
                        systemImage: "folder.fill",
                        tintColor: .indigo,
                        destination: LocalMusicView(onPickFolder: onPickFolder)
                    )

                    OnDeviceCard(
                        title: "WebDAV",
                        subtitle: WebDavStore.shared.isConfigured ? "Connected" : "Not configured",
                        systemImage: "cloud.fill",
                        tintColor: .teal,
                        destination: WebDavLibraryView()
                    )

                    OnDeviceCard(
                        title: "History",
                        subtitle: "Listening history",
                        systemImage: "clock.fill",
                        tintColor: .orange,
                        destination: HistoryView()
                    )
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var signedInPrompt: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: "person.crop.circle.badge.plus")
                    .scaledFont(size: 26, weight: .semibold)
                    .foregroundStyle(.tint)
            }
            Text("Sign in for your library")
                .font(.headline)
            Text("Liked playlists, albums and artists you save show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign In") {
                auth.loginPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var signedInShelves: some View {
        VStack(alignment: .leading, spacing: 26) {
            let sortedShelves = pinnedShelves(shelves)
            let hasPlaylists = sortedShelves.contains { isPlaylistsShelf($0) }

            // Upstream parity: fresh account has no Playlists shelf yet, but
            // needs the New Playlist tile to start one.
            if !hasPlaylists {
                shelfSection(FeedShelf(title: "Playlists", items: []))
            }

            ForEach(sortedShelves) { shelf in
                shelfSection(shelf)
            }
        }
    }

    private func shelfSection(_ shelf: FeedShelf) -> some View {
        let isPlaylists = isPlaylistsShelf(shelf)
        let totalCount = shelf.items.count + (isPlaylists ? 1 : 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(shelf.title).font(.title3.weight(.bold))
                Spacer()
                if totalCount > 5 {
                    PushLink {
                        LibraryGridView(title: shelf.title, items: shelf.items, isPlaylists: isPlaylists)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Show all")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.callout)
                        .foregroundStyle(.tint)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if isPlaylists {
                        NewPlaylistTile {
                            // Signed out there is nothing to save into: ask for the
                            // sign-in the page is already about, rather than opening
                            // a picker whose create button cannot work.
                            if auth.signedIn {
                                appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                            } else {
                                auth.loginPresented = true
                            }
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

    private func pinnedShelves(_ shelves: [FeedShelf]) -> [FeedShelf] {
        let pinned = PlaylistPinning.pinnedIds()
        return shelves.map { shelf in
            guard isPlaylistsShelf(shelf) else { return shelf }
            let items = shelf.items.sorted { a, b in
                let ap = pinned.contains(a.browseId ?? "")
                let bp = pinned.contains(b.browseId ?? "")
                if ap == bp { return false }
                return ap && !bp
            }
            return FeedShelf(title: shelf.title, items: items, subtitle: shelf.subtitle)
        }
    }

    private func displayItems(_ shelf: FeedShelf) -> [ShelfCard] {
        let cap = isPlaylistsShelf(shelf) ? 4 : 5
        return Array(shelf.items.prefix(cap))
    }

    private func isPlaylistsShelf(_ shelf: FeedShelf) -> Bool {
        shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "playlists"
    }

    private func loadShelves(force: Bool = false) async {
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

/// Upstream's card representation on the "On device" shelf.
struct OnDeviceCard<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tintColor: Color
    let destination: Destination

    var body: some View {
        PushLink(destination: destination) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tintColor.opacity(0.12))
                        .frame(width: 160, height: 160)
                    Image(systemName: systemImage)
                        .scaledFont(size: 46, weight: .medium)
                        .foregroundStyle(tintColor)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )

                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(MacCardHoverLift())
    }
}
