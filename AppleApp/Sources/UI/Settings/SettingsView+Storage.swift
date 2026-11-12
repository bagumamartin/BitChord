import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Local music folders, storage and the stream cache.
extension SettingsView {
    func buildLocalMusicRows(_ rows: inout SettingsRows) {
        rows.row("Folder", "local music", "local library", "folder", "scan", "files", "library", "voice",
                 "all audio folders") {
            Button {
                pickLocalFolder()
            } label: {
                SettingsLine(
                    glyph: .folder,
                    title: "Folder",
                    subtitle: localFolderName ?? "No folder chosen"
                ) {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        if localFolderName != nil {
            rows.row("Forget Folder", "folders", "forget", "local music", "library") {
                Button {
                    LocalLibrary.shared.forgetFolder()
                    localFolderName = nil
                } label: {
                    SettingsLine(
                        glyph: .localMusic,
                        title: "Forget Folder",
                        subtitle: "Forgets the chosen folder"
                    ) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        rows.row("Filter Non-Music Audio", "filter", "non-music", "podcast", "recording", "ringtone", "clips") {
            SettingsToggleLine(
                glyph: .filter,
                title: "Filter Non-Music Audio",
                subtitle: "Hides clips under 30 seconds, ringtones, podcasts and recorder output",
                isOn: $filterNonMusic
            )
        }
    }

    private func pickLocalFolder() {
        #if os(macOS)
        LocalLibrary.shared.chooseFolder()
        localFolderName = SettingsView.storedLocalFolderName()
        #else
        pickingFolder = true
        #endif
    }

    /// The chosen library folder's display name, from the persisted bookmark.
    ///
    /// Read from the bookmark rather than held in state: the library owns the
    /// bookmark and this screen only reports it, so resolving it fresh is what
    /// keeps the row honest after a pick made from the Library tab.
    static func storedLocalFolderName() -> String? {
        let stored = PlatformSettings.shared.getString(key: "local_library_path", default: "")
        guard !stored.isEmpty, let data = Data(base64Encoded: stored) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty ? nil : name
    }

    // MARK: - Storage

    func buildStorageRows(_ rows: inout SettingsRows) {
        rows.row("Song Cache Limit", "cache", "storage", "disk", "limit", "space", "songs", "size",
                 "clear cache", "show cache folder") {
            SettingsSliderRow(
                glyph: .storage,
                title: "Song Cache Limit",
                subtitle: cacheUnlimited
                    ? "Stream cache keeps played audio until the disk is full."
                    : cacheLimitMB > 2048
                        ? "Up to \(Self.formatCache(cacheLimitMB)) of stream cache for played audio."
                        : "Played audio kept for instant seeking and replays; saved downloads are separate.",
                valueText: cacheUnlimited ? "Unlimited" : Self.formatCache(cacheLimitMB),
                value: Binding(
                    get: { Double(cacheLimitMB) },
                    set: { cacheLimitMB = Int($0.rounded()) }
                ),
                range: 512...10240,
                step: 512
            )
            .disabled(cacheUnlimited)
        }

        // Upstream's "Unlimited": the ceiling is a disk-space question, and
        // someone with the room should be able to say yes to all of it.
        rows.row("Unlimited", "cache", "disk", "space", "storage") {
            Toggle("Unlimited", isOn: $cacheUnlimited)
                .onChange(of: cacheUnlimited) { _, unlimited in
                    AppSettings.shared.setAudioCacheLimitBytes(
                        value: unlimited ? Int64.max : Swift.Int64(cacheLimitMB) * 1024 * 1024
                    )
                    Task { await StreamFileCache.shared.trim() }
                }
        }
        // Upstream gates the Library's cached-songs folder on a switch like
        // this one. The row used to be always visible, which put a storage
        // detail in the middle of somebody's music.
        rows.row("Show Cached Songs in Library", "cache", "cached songs", "library", "folder", "show") {
            SettingsToggleLine(
                glyph: .storage,
                title: "Show Cached Songs in Library",
                subtitle: "Adds the stream cache to the Library's folders",
                isOn: $showCachedSongs
            )
        }
        rows.row("Clear Song Cache", "clear", "clear cache", "cache", "free space", "delete", "songs") {
            Button {
                Task {
                    await StreamFileCache.shared.clear()
                    await MainActor.run { songCacheNote = "Song cache cleared" }
                }
            } label: {
                SettingsLine(
                    glyph: .clearSongs,
                    title: "Clear Song Cache",
                    subtitle: songCacheNote ?? "Frees space used by downloaded audio"
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        }
        rows.row("Clear Image Cache", "clear", "image", "artwork", "cache", "space") {
            Button {
                ArtworkCache.shared.clear()
                imageCacheNote = "Image cache cleared"
            } label: {
                SettingsLine(
                    glyph: .clearImages,
                    title: "Clear Image Cache",
                    subtitle: imageCacheNote ?? "Frees space used by album artwork"
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Your data

    static func cacheLimitMegabytes() -> Int {
        let bytes = PlatformSettings.shared.getLong(key: "audio_cache_limit_bytes", default: Int64(512) * 1024 * 1024)
        // "Unlimited" is the sentinel the shared setting stores; the slider it
        // disables remembers an ordinary size for when it is turned back off.
        guard bytes < Int64.max else { return 1024 }
        return max(512, Int(bytes / (1024 * 1024)))
    }

    static func cacheIsUnlimited() -> Bool {
        PlatformSettings.shared.getLong(key: "audio_cache_limit_bytes", default: 0) >= Int64.max
    }

    private static func formatCache(_ mb: Int) -> String {
        if mb >= 1024 {
            let gb = Double(mb) / 1024
            return String(format: gb == floor(gb) ? "%.0f GB" : "%.1f GB", gb)
        }
        return "\(mb) MB"
    }
}
