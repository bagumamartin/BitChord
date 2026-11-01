import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// Library tab — on iOS, renders upstream's unified LibraryScreen (Replay banner,
/// On Device cards, signed-in shelves). On macOS, when lockedSection is set from
/// the sidebar, directly displays that destination.
struct LibraryView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var local = LocalLibrary.shared
    /// When set (sidebar `TabSection` rows on macOS and iPad), this destination
    /// is shown directly. The section page owns its navigation title and
    /// toolbar — nothing outer may add its own, or the two sets merge.
    var lockedSection: Section? = nil
    var hostsWindowControls: Bool = false

    enum Section: String, CaseIterable, Identifiable {
        case youtube, songs, albums, artists, playlists, subscriptions, podcasts, ondevice, downloads, history, webdav
        var id: String { rawValue }
        var label: String {
            switch self {
            case .youtube: "Recent"
            case .webdav: "WebDAV"
            case .ondevice: "On Device"
            default: rawValue.capitalized
            }
        }
    }

    @State private var pickingFolder = false
    @State private var showSpotifyImport = false

    var body: some View {
        PageStack {
            if let locked = lockedSection {
                // One header only. The section page below owns its title and
                // trailing buttons; an outer `.navigationTitle`/`.toolbar`
                // here would merge with the inner set — two scan-folder
                // pluses and two profile discs side by side, with the outer
                // title ("Songs") fighting the inner one ("Local Music").
                lockedContent(locked)
            } else {
                LibraryLandingView(onPickFolder: { pickFolder() })
                .navigationTitle("Library")
                .toolbar {
                    #if os(iOS)
                    TopBarLeadingItems()
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // One shared pill for the action buttons — not a glass
                        // disc each. (The account disc beside it stays solo,
                        // like on every other tab.)
                        HStack(spacing: 2) {
                            PushLink {
                                HistoryView()
                            } label: {
                                Image(systemName: "clock")
                                    .scaledFont(size: 15, weight: .medium)
                                    .foregroundStyle(.primary)
                                    .frame(width: 40, height: 34)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(ProfileCircleButtonStyle())
                            .accessibilityLabel("Listening History")

                            Divider()
                                .frame(height: 20)
                                .opacity(0.5)

                            // Everything that adds to the library, in one place:
                            // a phone's Library page is the only way in to the
                            // Spotify import (the Playlists grid is not a page here).
                            Menu {
                                if auth.signedIn {
                                    Button("New Playlist", systemImage: "music.note.list") {
                                        appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                                    }
                                    Button("Import from Spotify", systemImage: "square.and.arrow.down") {
                                        showSpotifyImport = true
                                    }
                                }
                                Button("Scan a Folder", systemImage: "folder") {
                                    pickFolder()
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .scaledFont(size: 15, weight: .medium)
                                    .foregroundStyle(.primary)
                                    .frame(width: 40, height: 34)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(ProfileCircleButtonStyle())
                            .accessibilityLabel("Add to Library")
                        }
                        .padding(.horizontal, 6)
                        .toolbarChrome(in: Capsule())

                        TopBarAccountButton()
                    }
                    #else
                    ToolbarItem {
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
                    #endif
                }
            }
        }
        .onAppear {
            local.restoreViewPreferences()
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                local.scanPicked(url)
            }
        }
        .sheet(isPresented: $showSpotifyImport) {
            SpotifyImportSheet()
        }
    }

    @ViewBuilder
    private func lockedContent(_ locked: Section) -> some View {
        switch locked {
        case .youtube: YoutubeLibraryView()
        case .songs: UnifiedSongsView(title: locked.label, onPickFolder: { pickFolder() }, hostsWindowControls: hostsWindowControls)
        case .albums: UnifiedAlbumsView(title: locked.label, onPickFolder: { pickFolder() }, hostsWindowControls: hostsWindowControls)
        case .artists: UnifiedArtistsView(title: locked.label, onPickFolder: { pickFolder() }, hostsWindowControls: hostsWindowControls)
        case .playlists: SavedPlaylistsView(hostsWindowControls: hostsWindowControls)
        case .subscriptions: SavedShelfView(shelfName: "Subscriptions", title: "Subscriptions", emptySubtitle: "Channels you subscribe to show up here.")
        case .podcasts: SavedShelfView(shelfName: "Podcasts", title: "Podcasts", emptySubtitle: "Podcasts you follow show up here.")
        case .ondevice: OnDeviceView()
        case .downloads: DownloadsView()
        case .webdav: WebDavLibraryView()
        case .history: HistoryView()
        }
    }

    private func pickFolder() {
        #if os(macOS)
        local.chooseFolder()
        #else
        pickingFolder = true
        #endif
    }
}
