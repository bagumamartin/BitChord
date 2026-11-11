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

// The iPhone and iPad layouts: portrait, two-column and compact landscape.
extension NowPlayingView {
    // ---- The player's arrangements -----------------------------------------
    //
    // Upstream's portrait player is two things, and the port had them the wrong
    // way up. A *pinned bottom deck* — credits, scrubber, transport, toggles —
    // measured at its natural height and fixed to the foot of the screen, and the
    // space above it, which is whatever the artwork or an open panel needs.
    //
    // What this had instead was one `VStack`: the artwork at full size, then
    // everything else crammed beneath it, then lyrics and queue in a fixed
    // 220-point strip. That put the artwork's size in charge of the layout, left
    // the lyrics with a strip too short to read, and moved the transport
    // depending on what was on screen. Pinned to the foot instead, the deck is
    // in the same place on every screen, and all that is left above it is the
    // stage.
    //
    // There are three arrangements, and they are one set of slots arranged
    // differently: the portrait player, the compact two-column player (a short
    // landscape window), and the wide two-column player (the sleeve and the deck
    // beside an open pane — a landscape window, or a regular-width tablet held
    // upright, which is N1).
    //
    // Everything below this comment is shared by both platforms. Only the two
    // bodies and the two toolbars are platform-specific, and they are the
    // arrangement — which is the only thing that should differ.
    #if os(iOS)
    var iOSBody: some View {
        NavigationStack {
            // The arrangement is the only thing that differs between the
            // shapes, so the arrangement is the only thing decided here. Every
            // slot below — the sleeve, the panes, the deck — is built once and
            // used by all of them, which is upstream's arrangement and the
            // reason rotating mid-song carries the open pane, the scrub and the
            // translation mode across instead of resetting them.
            GeometryReader { geo in
                ZStack {
                    MeshBackdrop(seed: controller.current?.id.hashValue ?? 0, artwork: controller.current?.artworkData)
                        .ignoresSafeArea()
                    if !isIPad && pane == .main && !PlayerLayout.takesLandscapeShape(width: geo.size.width, height: geo.size.height) && fullBleedOn && !videoShowing {
                        ArtworkContinuation(entry: controller.current, seam: geo.size.width)
                            .ignoresSafeArea(edges: .bottom)
                    }
                    if usesBlurredArtworkBackdrop(width: geo.size.width, height: geo.size.height) {
                        FullArtworkBlurBackdrop(entry: controller.current)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }

                    // One decision, then one of two arrangements. The
                    // cross-fade is bound to `pane` rather than to the shape,
                    // so rotating still hard-cuts the way it always has.
                    ZStack {
                        if showsTwoColumns(size: geo.size) {
                            twoColumnPlayer(size: geo.size)
                                .transition(.opacity)
                        } else {
                            portraitPlayer
                                .transition(.opacity)
                        }
                    }
                    .animation(isIPad ? .easeInOut(duration: 0.22) : nil, value: pane)
                }
            }
            // Full-screen covers have no swipe-to-dismiss of their own, so the
            // iPad cover gets Music's treatment: a grabber pill top-center
            // plus a top-edge downward drag. The iPhone sheet keeps its
            // system drag indicator and needs no chrome here. The drag is
            // gated to starts in the top chrome band with a deliberate
            // downward travel, so queue/lyrics scrolling underneath never
            // trips it (child scroll gestures win ties by default anyway).
            .overlay(alignment: .top) {
                if isIPad {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 42, height: 5)
                        .padding(.top, 10)
                        .accessibilityLabel("Close")
                        .accessibilityAction { dismiss() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard isIPad,
                              value.translation.height > 140,
                              abs(value.translation.width) < 80,
                              value.startLocation.y < 120
                        else { return }
                        dismiss()
                    }
            )
            .toolbar(.hidden, for: .navigationBar)
            .toolbarTitleDisplayMode(.inline)
            // Keep the established edge-to-edge phone artwork. The iPad page
            // respects its system top inset so the player has room for chrome.
            .ignoresSafeArea(.container, edges: isIPad ? [] : .top)
        }
    }
    #endif

    /// The shape test lives in [PlayerLayout] with the rest of the window rules,
    /// so the thresholds have one definition and can be checked without a window.

    /// Whether the player is arranged as two columns: always in a landscape
    /// window, and in a regular-width window while the lyrics or the queue are
    /// open, where the pane sits beside the sleeve rather than over its stage
    /// (`PlayerLayout.putsPaneBesideStage`, N1).
    ///
    /// The main pane is deliberately not two columns on a tablet held upright:
    /// with neither pane open there is nothing to put in the second column, and
    /// an empty one is dead space beside a sleeve that could have used it. That
    /// leaves the portrait player's main pane — the large sleeve and the pinned
    /// deck — exactly as it is.
    private func showsTwoColumns(size: CGSize) -> Bool {
        if PlayerLayout.takesLandscapeShape(width: size.width, height: size.height) {
            return true
        }
        return pane != .main && PlayerLayout.putsPaneBesideStage(
            width: size.width,
            regularWidth: isIPad
        )
    }

    /// The portrait player: stage above, pinned deck below.
    var portraitPlayer: some View {
        VStack(spacing: 0) {
            stage
            if pane != .lyrics || lyricsControlsOpen || keepsLyricsPlaybackDeckVisible {
                deck
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: lyricsControlsOpen)
    }

    /// The two-column player: the sleeve and the deck on the left, the open pane
    /// on the right.
    ///
    /// A short landscape window takes the compact variant, where the pane's
    /// contents share the right column with the credits and the transport.
    /// Everything else — a landscape iPad or Mac window, and a regular-width iPad
    /// held upright with the lyrics or Up Next open — takes the wide variant:
    /// Apple Music's two-column player, transport always on the left and the pane
    /// on the right.
    func twoColumnPlayer(size: CGSize) -> some View {
        let compact = PlayerLayout.isCompactLandscape(width: size.width, height: size.height)
        let gutter = PlayerLayout.gutter(compact: compact)
        return Group {
            if compact {
                compactLandscapePlayer(size: size, gutter: gutter)
            } else {
                wideTwoColumnPlayer(size: size, gutter: gutter)
            }
        }
    }

    private func compactLandscapePlayer(size: CGSize, gutter: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                GeometryReader { geo in
                    artworkStage(
                        side: max(80, min(geo.size.width, geo.size.height)),
                        collapsed: false
                    )
                }
                playerActionRow
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, gutter)

            Group {
                switch pane {
                case .main:
                    VStack(spacing: 14) {
                        creditsRow
                        currentLyricStrip
                        positionControls
                        playerTransport
                    }
                    .transition(.opacity)
                case .lyrics, .queue:
                    panel(showsQueueCurrentTrackHeader: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: pane)
        }
        .frame(maxWidth: PlayerLayout.landscapeMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func wideTwoColumnPlayer(size: CGSize, gutter: CGFloat) -> some View {
#if os(macOS)
        let maximumWidth = PlayerLayout.macLandscapeMaxWidth
        let artworkMaximum: CGFloat = 460
        let artworkHeightFraction: CGFloat = 0.46
        let leftColumnMaximum: CGFloat = 480
#else
        let maximumWidth = PlayerLayout.ipadLandscapeMaxWidth
        let artworkMaximum: CGFloat = 560
        let artworkHeightFraction: CGFloat = 0.58
        let leftColumnMaximum: CGFloat = 600
#endif
        return HStack(spacing: 36) {
            // Left column: Large Album Artwork + Full Transport Deck
            VStack(spacing: 16) {
                Spacer(minLength: 0)

                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    artworkStage(side: max(180, side), collapsed: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(maxHeight: min(size.height * artworkHeightFraction, artworkMaximum))

                VStack(spacing: 12) {
                    creditsRow

                    // The line being sung, as the phone shows it, while the
                    // lyrics column is closed. With the column open it would
                    // print the same line twice, side by side.
                    if pane != .lyrics {
                        currentLyricStrip
                            .padding(.horizontal, 12)
                    }

                    positionControls
                        .padding(.horizontal, 12)

                    playerTransport

                    #if os(iOS)
                    if !controller.hideVolumeBar {
                        deckVolumeRow
                            .padding(.horizontal, 12)
                    }
                    #endif
                    // The pane-reactive pill lives on every platform: queue
                    // modes in the queue pane, output/party elsewhere. It used
                    // to sit inside the iOS gate below, so macOS never showed
                    // it at all.
                    actionRowPill
                    #if os(iOS)
                    Text(outputCaption)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .accessibilityLabel(outputCaption)
                    #endif
                }
                .frame(maxWidth: leftColumnMaximum - 40)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: leftColumnMaximum)
            // No leading inset when the player stands alone: it centers in
            // the full width rather than sitting gutter-shifted.
            .padding(.leading, pane == .main ? 0 : gutter)

            // Right column: Lyrics or Queue — and nothing in the main pane.
            // With neither panel selected the player takes the full width,
            // centered; an empty panel column would just leave dead space.
            if pane != .main {
                Group {
                    if pane == .queue {
                        UpNextPane(
                            showsCurrentTrackHeader: false,
                            onOpenLyrics: { pane = .lyrics }
                        )
                            .transition(.opacity)
                    } else {
                        desktopLyricsPane
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 72)
                .padding(.trailing, gutter)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: maximumWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if pane == .lyrics {
                lyricsToolsButton
                    .padding(.trailing, gutter)
                    .padding(.top, 18)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            landscapePaneSwitcher
                .padding(.trailing, gutter)
                .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.2), value: pane)
    }

    private var landscapePaneSwitcher: some View {
        // Two separate buttons with air between them, like Music: lyrics and
        // queue are mutually exclusive in function but not one joined
        // toggle — no shared capsule, no cramped spacing. Each one toggles:
        // tapping the highlighted pane returns to the main player, so the
        // switcher can always reach the neither-selected state.
        HStack(spacing: 18) {
            actionGlyph(.bchLyrics, selected: pane == .lyrics, label: "Lyrics") {
                Haptics.play(.expand)
                pane = pane == .lyrics ? .main : .lyrics
            }
            actionGlyph(.bchQueue, selected: pane == .queue, label: "Up Next") {
                Haptics.play(.expand)
                pane = pane == .queue ? .main : .queue
            }
        }
    }

    var lyricsToolsButton: some View {
        Menu {
            Button("Change Lyrics Source", systemImage: "text.magnifyingglass") {
                showLyricsSources = true
            }
            Button("Adjust Lyrics Timing", systemImage: "slider.horizontal.2.square") {
                showLyricsOffset = true
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 42, height: 42)
                .chromeGlass(in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Lyrics options")
        .accessibilityLabel("Lyrics options")
    }
}
