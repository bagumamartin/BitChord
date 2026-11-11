import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
import AVFAudio
#else
import AppKit
#endif

/// Full Now Playing (UI spec §3.3). On macOS this *is* the window: traffic
/// lights stay, back / volume / AirPlay live in the real toolbar, and the
/// wash shows through a hidden title. On iPhone it is a swipe-to-dismiss
/// sheet that zooms from the mini player; on iPad a full-screen cover with
/// Music's grabber-plus-swipe dismissal (a sheet can no longer be trusted
/// full-screen — `.page` sizing presented as a floating card on iPadOS 27).
struct NowPlayingView: View {
    @Environment(PlaybackController.self) var controller
    @Environment(AppModel.self) var appModel
    @Environment(PartyStore.self) var party
    @Environment(\.dismiss) var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(AuthController.self) var auth
    @Environment(ToastCenter.self) private var toast
    // Upstream restores the last expanded-player surface and starts on MAIN
    // for a fresh install. Persisting this here also keeps rotation/reopening
    // from unexpectedly dropping a listener into lyrics.
    @State var pane: PlayerPane = PlayerPane.restored
    #if os(macOS)
    /// The trailing spacer that puts AirPlay as far from the right edge as
    /// Back is from the left.
    @State var trailingInset: CGFloat = 0
    #endif
    @State var lyricsControlsOpen = true
    @State var lyricsControlActivity = 0
    @State var lyricsScrubbing = false
    @State var volumeDragging = false
    @State var showOutputDevice = false
    /// The same switch as Settings ▸ Playback ▸ Show Music Videos, flipped
    /// from the pill while the track plays.
    @AppStorage("show_music_videos") var showMusicVideos = false
    @AppStorage("hide_status_bar_in_player") private var hideStatusBarInPlayer = false
    @State var showPipeline = false
    @State var showLyricsOffset = false
    @State var showLyricsSources = false
    /// Lyric share-picking, driven from the lyrics header: upstream's header
    /// three-dot becomes the way in (and the way out) of picking lines for a
    /// share card while the lyrics pane is up.
    @State var sharePicking = false
    /// Whether the title is crawling, so the artist line waits a beat behind it.
    @State var titleCrawls = false
    /// The offset, held here so a change re-renders the lyrics without the sheet
    /// being open. The notification is the signal; this is the value it carries.
    @State var lyricsOffsetMs: Int32 = LyricsOffsetBridge.offsetMs()

    var body: some View {
        // The platform split has to close *inside* a `Group`: a `#if` in a view
        // builder is two statements, and the `.sheet` after it has nothing to
        // attach to. Both branches present the same readout.
        Group {
            #if os(macOS)
            macOSBody
            #else
            iOSBody
            #endif
        }
        #if os(iOS)
        .statusBarHidden(hideStatusBarInPlayer)
        #endif
        .sheet(isPresented: $showPipeline) {
            AudioPipelineSheet()
        }
        .sheet(isPresented: $showOutputDevice) {
            OutputDeviceSheet()
                .environment(controller)
        }
        .sheet(isPresented: $showLyricsOffset) {
            LyricsOffsetSheet()
                .environment(controller)
        }
        .sheet(isPresented: $showLyricsSources) {
            // Upstream's status row opens the per-track provider picker
            // (NowPlayingScreen.kt:1970): the picker is about THIS track's
            // lyric, and the sources settings stay in Settings.
            LyricsProviderSheet()
        }
        // The offset is adjusted *against the track playing*, so the effect has to
        // be visible while the sheet is still open — a control that only took
        // hold on the next track could not be aimed at anything.
        .onReceive(NotificationCenter.default.publisher(for: .lyricsOffsetChanged)) { _ in
            lyricsOffsetMs = LyricsOffsetBridge.offsetMs()
        }
        .onChange(of: appModel.queueRevealRequested) { _, requested in
            if requested {
                withAnimation(.easeInOut(duration: 0.2)) { pane = .queue }
                appModel.queueRevealRequested = false
            }
        }
        .onChange(of: appModel.lyricsRevealRequested) { _, requested in
            if requested {
                withAnimation(.easeInOut(duration: 0.2)) { pane = .lyrics }
                appModel.lyricsRevealRequested = false
            }
        }
        .onChange(of: pane) { _, value in
            PlatformSettings.shared.putString(key: "last_player_screen", value: value.persistedValue)
            if value == .lyrics {
                lyricsControlsOpen = true
                lyricsControlActivity += 1
            }
        }
        .task(id: lyricsControlActivity) {
            while pane == .lyrics, lyricsControlsOpen {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard !Task.isCancelled, pane == .lyrics, lyricsControlsOpen else { return }
                if lyricsScrubbing { continue }
                withAnimation(.easeInOut(duration: 0.22)) { lyricsControlsOpen = false }
                return
            }
        }
    }

    /// Upstream uses a cropped, pre-blurred cover behind lyrics and queue, and
    /// throughout landscape / tablet playback. The phone's main player keeps
    /// its seam-aware artwork mesh behind the edge-to-edge sleeve.
    func usesBlurredArtworkBackdrop(width: CGFloat, height: CGFloat) -> Bool {
        pane != .main || PlayerLayout.takesLandscapeShape(width: width, height: height) ||
            width >= PlayerLayout.tabletMinWidth || videoShowing
    }

    /// A music video is on screen. The phone's backdrop is then the blurred
    /// sleeve, as on Mac and iPad: the cover continued under the hero fought
    /// the video for contrast.
    var videoShowing: Bool {
        showMusicVideos && VideoPlayback.shared.showsVideo
    }

    /// A regular-width window: an iPad, or a Max phone on its side. The player
    /// lays out for the room it has, not for the device's name.
    var isIPad: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        false
        #endif
    }

    var keepsLyricsPlaybackDeckVisible: Bool {
        #if os(iOS)
        isIPad
        #else
        true
        #endif
    }

    var showsPlaybackStatusLine: Bool { true }

    // iOS only — macOS has its own window-toolbar back button, in
    // `macPlayerToolbar`.
    #if os(iOS)
    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if #available(iOS 26.0, *) {
                Button(role: .close) { dismiss() }
            } else {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            AirPlayRouteButton()
                .frame(width: 22, height: 22)
                .help("AirPlay")
        }
    }
    #endif

    /// Upstream `AppSettings.fullBleedArtwork`: the portrait sleeve runs as a
    /// full-bleed banner rather than a card.
    var fullBleedOn: Bool {
        PlatformSettings.shared.getBoolean(key: "full_bleed_artwork", default: true)
    }

    /// Upstream `AppSettings.hideSongStatus`: hides the playback-origin
    /// caption / nerd line under the credits.
    private var hideSongStatus: Bool {
        PlatformSettings.shared.getBoolean(key: "hide_song_status", default: false)
    }

    /// Upstream `AppSettings.legacyMeshGradient`: the backdrop renders a single
    /// static wash instead of animated blobs.
    private var legacyMesh: Bool {
        PlatformSettings.shared.getBoolean(key: "legacy_mesh_gradient", default: false)
    }

    /// The playback-origin caption under the credits: upstream's
    /// `playbackOriginText` ("Playing from …"), falling back to the nerd line
    /// while a lossless lookup is still racing. Nil when hidden or unknown.
    var songStatusLine: String? {
        guard !hideSongStatus else { return nil }
        var parts: [String] = []
        if let source = controller.playbackSourceName { parts.append(source) }
        if let nerd = controller.nerd {
            parts.append(QualityUpgrade.Format.isLosslessCodec(nerd.codec) ? "Lossless" : nerd.codec)
        }
        if controller.racingLossless { parts.append("Checking for better audio…") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The compact source caption that sits over upstream's full-bleed cover.
    /// Nerd statistics stay in the deck; they are not the origin of playback.
    var playbackOriginCaption: String? {
        guard !hideSongStatus, let current = controller.current else { return nil }
        if controller.resolvedOrigin[current.id] == .substitute,
           let source = controller.playbackSourceName {
            return "Playing from \(source)"
        }
        if let context = controller.playbackContext, !context.isEmpty {
            return "Playing from \(context)"
        }
        if current.isLocal { return "Playing from Local files" }
        if current.source.hasPrefix("yt:") { return "Playing from YouTube" }
        guard !current.source.isEmpty else { return nil }
        return "Playing from \(current.source)"
    }

    // ---- Shared pieces ------------------------------------------------------

}

/// Which of the three the portrait player is showing.
///
/// Three states, not two, and the third is the important one. Upstream's player
/// has a *main* pane that the artwork fills, and lyrics and queue that replace
/// it; a two-state enum can only ever hold one of the last two at a time and has
/// nowhere to go back to, which is why the artwork has to be a control to close
/// them.
enum PlayerPane {
    case main, lyrics, queue

    static var restored: PlayerPane {
        switch PlatformSettings.shared.getString(key: "last_player_screen", default: "MAIN") {
        case "LYRICS": .lyrics
        case "QUEUE": .queue
        default: .main
        }
    }

    var persistedValue: String {
        switch self {
        case .main: "MAIN"
        case .lyrics: "LYRICS"
        case .queue: "QUEUE"
        }
    }
}

extension View {
    /// Soft shadow so white glyphs stay readable on a bright artwork wash.
    func playerGlyph() -> some View {
        shadow(color: .black.opacity(0.55), radius: 5, y: 1)
    }
}
