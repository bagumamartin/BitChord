import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// The Albums row: saved albums from the signed-in library, then this
/// device's scanned albums. Same contract as Songs: each half stands alone.
struct UnifiedAlbumsView: View {
    var title = "Albums"
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
        libraryShelf(titled: "albums", in: shelves)?.items ?? []
    }

    private var hasCloud: Bool { !saved.isEmpty }
    private var hasDevice: Bool { local.scanned && !local.albumGroups.isEmpty }

    var body: some View {
        Group {
            if auth.signedIn && loading {
                ScrollView { SkeletonGrid(showsTitle: true) }
            } else if let error, !hasDevice {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Albums couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if !hasCloud && !hasDevice {
                combinedEmpty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if hasCloud {
                            collectionSection(title: "Saved Albums", items: saved)
                        }
                        if local.scanned {
                            if hasDevice {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("On This Device")
                                        .font(.title3.weight(.bold))
                                        .padding(.horizontal, 24)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                                        ForEach(local.albumGroups, id: \.name) { group in
                                            LocalAlbumCell(group: group)
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                }
                            } else {
                                Text("No albums in the scanned folder.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)
                            }
                        } else if hasCloud {
                            scanPrompt(kind: "albums")
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

    private func collectionSection(title: String, items: [ShelfCard]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 24)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                ForEach(items) { card in
                    ShelfCardView(card: card)
                }
            }
            .padding(.horizontal, 24)
        }
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
                title: "Your albums live here",
                subtitle: "Save albums on YouTube Music — or scan a folder on this device.",
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
                title: "No saved albums yet",
                subtitle: "Albums you save on YouTube Music show up here — or scan a folder on this device.",
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
