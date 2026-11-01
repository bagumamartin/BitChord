import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// The On Device row: everything that lives on this hardware — downloads,
/// the scanned folder, the remote share — the destinations upstream's
/// On Device shelf cards open.
struct OnDeviceView: View {
    var title = "On Device"
    @State private var downloadStore = DownloadStore.shared
    @State private var local = LocalLibrary.shared
    /// Settings ▸ Storage gates this browser, as upstream gates its cache
    /// folder: the stream cache is a storage detail, not a music library.
    @AppStorage("show_cached_songs_in_library") private var showCachedSongs = false

    var body: some View {
        List {
            PushLink(destination: DownloadsView()) {
                deviceRow(
                    systemImage: "arrow.down.circle.fill", tint: .accentColor,
                    title: "Downloads",
                    subtitle: "\(downloadStore.items.count) downloaded song\(downloadStore.items.count == 1 ? "" : "s")"
                )
            }
            PushLink(destination: LocalMusicView()) {
                deviceRow(
                    systemImage: "folder.fill", tint: .indigo,
                    title: "Local Music",
                    subtitle: local.scanned ? "\(local.tracks.count) song\(local.tracks.count == 1 ? "" : "s")" : "Choose a folder to scan"
                )
            }
            if showCachedSongs {
                PushLink(destination: CachedSongsView()) {
                    deviceRow(
                        systemImage: "internaldrive.fill", tint: .orange,
                        title: "Cached Songs",
                        subtitle: "Songs kept on disk for instant and offline playback"
                    )
                }
            }
            PushLink(destination: WebDavLibraryView()) {
                deviceRow(
                    systemImage: "cloud.fill", tint: .teal,
                    title: "WebDAV",
                    subtitle: WebDavStore.shared.isConfigured ? "Connected" : "Not configured"
                )
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            TopBarLeadingItems()
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .onAppear {
            downloadStore.refresh()
            local.restoreViewPreferences()
        }
    }

    private func deviceRow(systemImage: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: systemImage)
                    .scaledFont(size: 20, weight: .medium)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 12))
    }
}
