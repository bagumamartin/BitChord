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

// The stage: artwork or lyrics, the side panel, and the playback deck.
extension NowPlayingView {
    var desktopLyricsPane: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !controller.isPlaying)) { timeline in
            LyricsPane(
                lines: controller.displayedLyrics,
                originalLines: controller.lyrics,
                loading: controller.lyricsLoading,
                position: controller.livePosition(at: timeline.date),
                hasTrack: controller.current != nil,
                sourceLabel: controller.lyricsSourceLabel,
                alignmentInProgress: controller.lyricsAligning,
                alignedLocally: controller.lyricsAlignedLocally,
                onChooseSource: { showLyricsSources = true },
                onSeek: { controller.seek(to: $0) },
                translator: controller.lyricsTranslator,
                trackId: controller.current?.id ?? "",
                offsetMs: lyricsOffsetMs,
                sourceVisible: true,
                onChangeSource: { showLyricsSources = true },
                onRevealControls: {},
                onFocusLyrics: {},
                trackTitle: controller.current?.title ?? "",
                trackArtist: controller.current?.artist ?? "",
                artworkData: controller.current?.artworkData,
                artworkUrl: controller.current?.thumbnailUrl
            )
        }
    }

    /// Everything above the deck: the artwork, or whichever panel is open.
    ///
    /// Takes all the height the deck has left, so the artwork is as large as the
    /// window allows on a tall phone and the panels get the full column on a
    /// short one — which is the trade upstream makes, in the opposite direction
    /// from a fixed strip.
    var stage: some View {
        GeometryReader { geo in
            let collapsed = pane != .main
            // The largest square that fits, with the gutters the player keeps.
            // Measured rather than assumed, so a short window shrinks the
            // artwork instead of pushing the deck off the bottom.
            let full = PlayerLayout.portraitArtworkSide(
                stageWidth: geo.size.width,
                stageHeight: geo.size.height,
                maximumSide: isIPad
                    ? min(
                        PlayerLayout.ipadPortraitArtworkMaxSide,
                        geo.size.width * PlayerLayout.ipadPortraitArtworkWidthFraction
                    )
                    : nil
            )
            // Full Bleed remains a phone preference; the iPad keeps its
            // contained sleeve even when the preference is enabled.
            let hero = !isIPad && !collapsed && PlayerLayout.usesFullBleedArtwork(
                width: geo.size.width, preferenceEnabled: fullBleedOn
            )
            // On iPad portrait, the panel takes the whole stage above the
            // pinned transport; it is part of the player page, not a nested sheet.
            VStack(spacing: 0) {
                if pane == .lyrics {
                    lyricsHeader
                } else if pane == .main {
                    if isIPad {
                        artworkStage(side: full, collapsed: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        artworkStage(
                            side: hero ? geo.size.width : full,
                            collapsed: false,
                            hero: hero
                        )
                    }
                }
                if collapsed {
                    panel()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottomTrailing) {
                if pane == .lyrics {
                    lyricsToolsButton
                        .padding(.trailing, 20)
                        .padding(.bottom, 12)
                }
            }
            .animation(.snappy(duration: 0.28), value: pane)
            // Additive sleeve swipe, upstream's vertical drag: up past 60pt
            // opens Up Next, down while a panel is up returns to the player.
            // The pane buttons stay the primary control; this never replaces
            // them. A plain `gesture` so an open panel's own scroll wins the
            // touch first.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dy = value.translation.height
                        let dx = value.translation.width
                        // Clearly vertical before it counts.
                        guard abs(dy) > abs(dx) else { return }
                        if dy < -60 && pane == .main {
                            Haptics.play(.expand)
                            pane = .queue
                        } else if dy > 60 && pane != .main {
                            Haptics.play(.tap)
                            pane = .main
                        }
                    }
            )
            .accessibilityHint("Swipe up for Up Next, swipe down to return to the player.")
        }
    }

    /// The artwork sleeve.
    ///
    /// A button exactly when there is somewhere to go back to, which is the whole
    /// point of the collapse: upstream shrinks the artwork into a header when a
    /// panel is up, and the shrunk artwork is the way back to the player. In the
    /// main pane it is not a button, because a big artwork that does nothing when
    /// tapped is a control that lies about being one.
    ///
    /// The card is [SleeveArt] — still art with the canvas over it and the
    /// paused shrink inside a fixed slot — unless full-bleed is on and the
    /// window is one the setting acts on, in which case it is the [HeroArtwork]
    /// banner, edge to edge with its bottom dissolved into the mesh.
    @ViewBuilder
    func artworkStage(side: CGFloat, collapsed: Bool, hero: Bool = false) -> some View {
        if collapsed {
            Button {
                Haptics.play(.tap)
                pane = .main
            } label: {
                SleeveArt(
                    entry: controller.current,
                    canvasURL: controller.canvasURL,
                    fallbackURL: controller.canvasFallbackURL,
                    isPlaying: controller.isPlaying,
                    side: side
                )
                .id(controller.current?.id)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to player")
            .padding(.top, 8)
            .padding(.bottom, 4)
        } else if hero {
            HeroArtwork(
                entry: controller.current,
                canvasURL: controller.canvasURL,
                fallbackURL: controller.canvasFallbackURL,
                isPlaying: controller.isPlaying,
                canvasActive: !VideoPlayback.shared.showsVideo
            )
            .id(controller.current?.id)
            // Hero size is the actual viewport width, independent of the
            // remaining height above the controls.
            .frame(width: side, height: side)
            .overlay(alignment: .top) {
                if let caption = playbackOriginCaption {
                    Text(caption)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.55), radius: 5, y: 1)
                        .padding(.top, 22)
                }
            }
            .accessibilityLabel(controller.current?.title ?? "Nothing playing")
        } else {
            VideoSurface(cornerRadius: 12, announcesLoading: true, presentation: .card) {
                SleeveArt(
                    entry: controller.current,
                    canvasURL: controller.canvasURL,
                    fallbackURL: controller.canvasFallbackURL,
                    isPlaying: controller.isPlaying,
                    canvasActive: !VideoPlayback.shared.showsVideo,
                    side: side
                )
            }
            .id(controller.current?.id)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .accessibilityLabel(controller.current?.title ?? "Nothing playing")
        }
    }

    /// The selected content pane, filling the portrait stage or the requested
    /// portion of a compact landscape layout.
    @ViewBuilder
    func panel(showsQueueCurrentTrackHeader: Bool = true) -> some View {
        switch pane {
        case .main:
            Color.clear
        case .lyrics:
            // Frame-driven, not poll-driven. `controller.position` only moves
            // when the transport tick reads the engine — four times a second —
            // so a word highlight judged against it can only change on those
            // four ticks, and steps in 250 ms jumps. Upstream drives the pane
            // from a frame clock for exactly this reason. The interpolated
            // position is still the engine's measurement; the TimelineView only
            // decides how often we ask where it has got to.
            TimelineView(.animation(minimumInterval: nil, paused: !controller.isPlaying)) { timeline in
            LyricsPane(
                lines: controller.displayedLyrics,
                originalLines: controller.lyrics,
                loading: controller.lyricsLoading,
                position: controller.livePosition(at: timeline.date),
                hasTrack: controller.current != nil,
                sourceLabel: controller.lyricsSourceLabel,
                alignmentInProgress: controller.lyricsAligning,
                alignedLocally: controller.lyricsAlignedLocally,
                onChooseSource: { showLyricsSources = true },
                onSeek: { controller.seek(to: $0) },
                translator: controller.lyricsTranslator,
                trackId: controller.current?.id ?? "",
                offsetMs: lyricsOffsetMs,
                sourceVisible: lyricsControlsOpen,
                sharePicking: sharePicking,
                onSharePicking: { sharePicking = $0 },
                onChangeSource: { showLyricsSources = true },
                onRevealControls: { revealLyricsControls() },
                onFocusLyrics: { hideLyricsControls() },
                trackTitle: controller.current?.title ?? "",
                trackArtist: controller.current?.artist ?? "",
                artworkData: controller.current?.artworkData,
                artworkUrl: controller.current?.thumbnailUrl
            )
            }
        case .queue:
            UpNextPane(
                showsCurrentTrackHeader: showsQueueCurrentTrackHeader,
                onOpenLyrics: { pane = .lyrics }
            )
        }
    }

    /// The pinned playback deck: credits, scrubber, transport, volume and actions.
    ///
    /// Measured at its natural height and fixed to the foot, so opening the
    /// lyrics does not shove the transport down. The pane toggles live here
    /// rather than floating over the artwork: they are *which pane* is showing,
    /// which is the same question the rest of this block answers.
    /// The volume row runs edge to edge with the action row's two glyphs on
    /// an upright iPad whose window fills the screen, while neither pane is
    /// open.
    private var volumeSpansActionGlyphs: Bool {
        #if os(iOS)
        guard isIPad, pane == .main,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else { return false }
        let screen = scene.screen.bounds.size
        let window = scene.coordinateSpace.bounds.size
        return screen.width < screen.height && window == screen
        #else
        false
        #endif
    }

    var deck: some View {
        VStack(spacing: 14) {
            // Credits, status and strip live on the main player only. Upstream's
            // queue screen goes Lyrics link straight to the scrubber — the song
            // title and the sung line sitting over the queue is this codebase's
            // invention, and it is what buried the list.
            if pane == .main { creditsRow }
            // The playback-origin caption / nerd line, hidden behind
            // `hide_song_status` exactly as upstream hides it.
            if pane == .main, showsPlaybackStatusLine, let status = songStatusLine {
                Button { showPipeline = true } label: { Text(status) }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(.horizontal, 24)
                    .accessibilityLabel(status)
            }
            // Phones keep the lyric strip in the main and queue panes. On iPad
            // the larger lyric/queue pane already has that space, so the pinned
            // deck stays focused on seek and playback controls.
            if pane != .lyrics && !isIPad { currentLyricStrip }
            positionControls
                .padding(.horizontal, 32)
            playerTransport
            // The volume capsule between transport and toggles, flanked by
            // speaker icons in the hairline style of `ThinSlider`. Gone when
            // `hide_volume_bar` is on, the same as upstream.
            if !controller.hideVolumeBar {
                if volumeSpansActionGlyphs {
                    // Ends at the Lyrics glyph's left edge and Up Next's
                    // right, measured on the same width as the action row.
                    GeometryReader { geometry in
                        volumeRow(hugsGlyphs: true)
                            .padding(.horizontal, actionGlyphInkInset(width: geometry.size.width))
                    }
                    .frame(height: 16)
                } else {
                    deckVolumeRow
                        .padding(.horizontal, 32)
                }
            }
            playerActionRow
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            // A scrim rather than a blur: the backdrop is already a mesh, and a
            // material over it muddies the colours the artwork set up. Short
            // enough to read as the foot of the screen rather than a sheet.
            LinearGradient(
                colors: [.clear, .black.opacity(0.30), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        )
    }
}
