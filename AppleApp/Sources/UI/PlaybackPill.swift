import SwiftUI
import BitChordShared
#if canImport(UIKit)
import UIKit
#endif

/// The Apple Music-style playback pill (UI spec §3.1/§3.2), shared by both
/// platforms. Ports upstream's `MiniPlayer.kt`: artwork thumbnail (tap →
/// Now Playing), title/artist, transport. The pill is **always visible** —
/// with nothing playing it shows the empty state, exactly as Music keeps its
/// bottom pill around. The macOS variant floats over the content column and
/// carries Music's full cluster: shuffle / prev / play / next / repeat and the
/// party on the left, the now-playing slot in the middle, the lyrics and queue
/// panels, track actions, volume and AirPlay on the right.
struct PlaybackPill: View {
    /// Squeezed between the tab button and Search after the iPhone's tab bar
    /// minimizes on scroll (iOS 26's inline bottom accessory, as in Music).
    var inline = false

    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if os(macOS)
    @Environment(\.macInspectorSelection) private var inspector
    #endif

    var body: some View {
        #if os(macOS)
        macOSPill
        #else
        iOSPill
        #endif
    }

    // ---- iOS: mini-player above the tab bar --------------------------------
    #if os(iOS)
    private enum PillDragAxis: Equatable {
        case horizontal
        case vertical
    }

    private struct PillDragState: Equatable {
        var axis: PillDragAxis? = nil
        var translation = CGSize.zero

        mutating func track(_ translation: CGSize) {
            if axis == nil, max(abs(translation.width), abs(translation.height)) >= 10 {
                axis = abs(translation.height) > abs(translation.width) ? .vertical : .horizontal
            }
            self.translation = translation
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @GestureState private var pillDrag = PillDragState()
    @State private var lockedPillDrag: (start: CGPoint, axis: PillDragAxis)?
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    private var pillPullLift: CGFloat {
        guard pillDrag.axis == .vertical, pillDrag.translation.height < 0 else { return 0 }
        return min(max(-pillDrag.translation.height * 0.5, 0), 72)
    }

    private var iOSPill: some View {
        HStack(spacing: 12) {
            if isRegularWidth {
                padLeadingTransport
            }

            Button {
                appModel.nowPlayingPresented = true
            } label: {
                HStack(spacing: inline ? 8 : 10) {
                    artworkOrPlaceholder
                    info
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(miniPlayerAccessibilityLabel)
            .accessibilityHint("Opens Now Playing")

            if isRegularWidth {
                padTrailingControls
            } else {
                buttons
            }
        }
        .padding(.horizontal, inline ? 8 : 12)
        .padding(.vertical, inline ? 4 : 8)
        .modifier(MiniPlayerChrome(fill: chromeFill, reduceTransparency: reduceTransparency || reduceBlur))
        .overlay(alignment: .bottom) { progressHairline.clipShape(Capsule()) }
        .contentShape(.rect)
        // Long press: what is coming next. Upstream's mini player answers a long
        // press with the queue, and on a phone the pill has no queue button beside
        // the transport — this is the way to reach the next few tracks without
        // opening the player first.
        .contextMenu { quickQueueMenu }
        .offset(y: -pillPullLift)
        // Direct gesture-state updates make the pill follow the finger at half
        // rate. Only the release back to rest springs; the pull itself does not lag.
        .animation(
            pillDrag == PillDragState()
                ? .spring(response: 0.38, dampingFraction: 0.86)
                : nil,
            value: pillDrag
        )
        .modifier(NowPlayingZoomSource())
        // One detector resolves the axis after the system's touch slop: an
        // upward pull opens Now Playing, while a 72 pt horizontal swipe skips.
        .gesture(
            DragGesture(minimumDistance: 10)
                .updating($pillDrag) { value, state, _ in
                    state.track(value.translation)
                }
                .onChanged { value in
                    if let lockedPillDrag, lockedPillDrag.start != value.startLocation {
                        self.lockedPillDrag = nil
                    }
                    if lockedPillDrag == nil,
                       max(abs(value.translation.width), abs(value.translation.height)) >= 10 {
                        lockedPillDrag = (
                            start: value.startLocation,
                            axis: abs(value.translation.height) > abs(value.translation.width)
                                ? .vertical
                                : .horizontal
                        )
                    }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let axis = lockedPillDrag?.axis
                        ?? (abs(dy) > abs(dx) ? PillDragAxis.vertical : .horizontal)
                    lockedPillDrag = nil
                    if axis == .vertical {
                        guard dy < -10 else { return }
                        let heldPull = min(max(-dy * 0.5, 0), 72)
                        let flickedUp = value.predictedEndTranslation.height < dy - 72
                        guard flickedUp || heldPull > 36 else { return }
                        Haptics.play(.tap)
                        appModel.nowPlayingPresented = true
                        return
                    }
                    guard abs(dx) >= 72 else { return }
                    guard !PartyStore.shared.state.controlsLocked else {
                        Haptics.play(.tap)
                        return
                    }
                    if dx < 0 {
                        guard controller.canPlayNext else { return }
                        Haptics.play(.skipNext)
                        controller.next()
                    } else {
                        guard controller.canPlayPrevious else { return }
                        Haptics.play(.skipPrevious)
                        controller.previous()
                    }
                }
        )
    }
    #endif

    // ---- macOS: Music's floating glass pill --------------------------------
    #if os(macOS)
    private var macOSPill: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                pillButton("Shuffle", icon: .bchShuffle) {
                    controller.toggleShuffle()
                }
                .foregroundStyle(controller.shuffleEnabled ? Color.accentColor : .primary)

                pillButton("Previous", system: "backward.fill") {
                    controller.previous()
                }
                .disabled(!controller.canPlayPrevious)

                if controller.isBuffering {
                    Button {
                        controller.togglePlayPause()
                    } label: {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Pause playback while loading")
                    .accessibilityLabel("Pause playback while loading")
                } else {
                    pillButton(
                        controller.isPlaying ? "Pause" : "Play",
                        system: controller.isPlaying ? "pause.fill" : "play.fill",
                        glyph: 17
                    ) {
                        controller.togglePlayPause()
                    }
                    .disabled(controller.current == nil)
                }

                pillButton("Next", system: "forward.fill") {
                    controller.next()
                }
                .disabled(!controller.canPlayNext)

                Button {
                    controller.cycleRepeat()
                } label: {
                    RepeatGlyph(mode: controller.repeatMode, size: 15)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(controller.repeatMode == .off ? .primary : Color.accentColor)
                .help(controller.repeatMode == .one ? "Repeat one" : controller.repeatMode == .all ? "Repeat all" : "Repeat off")

                partyButton
            }
            .foregroundStyle(.primary)

            MacNowPlayingSlot(
                artwork: { artworkOrPlaceholder },
                info: { info }
            )
            .frame(minWidth: 180, maxWidth: 360)

            HStack(spacing: 2) {
                // Lyrics and the queue open the panel beside the library, so
                // the list stays where it is; a second click closes it.
                inspectorToggle(.lyrics, icon: .bchLyrics)
                inspectorToggle(.queue, icon: .bchQueue)
                playerActionsButton
            }

            HStack(spacing: 6) {
                if !controller.hideVolumeBar {
                    PillSlider(volume: Binding(
                        get: { controller.volume },
                        set: { controller.volume = $0 }
                    ))
                    .frame(width: 112)
                    .help("Volume")
                    .accessibilityLabel("Volume")
                }
                AirPlayRouteButton()
                    .frame(width: 20, height: 20)
                    .frame(width: 28, height: 32)
                    .help("AirPlay")
                    .accessibilityLabel("AirPlay")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            // Over the library the pill has artwork under it, so the glass is
            // the regular weight with the window's own colour beneath: thin
            // material let the sleeves show through the controls.
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if reduceTransparency || reduceBlur {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                    .background(.regularMaterial, in: shape)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inspectorToggle(_ kind: MacInspectorKind, icon: ImageResource) -> some View {
        let active = inspector.wrappedValue == kind
        return Button {
            inspector.wrappedValue = active ? nil : kind
        } label: {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : .secondary)
        .help(active ? "Hide \(kind.label)" : "Show \(kind.label)")
        .accessibilityLabel(kind.label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Shared 32pt hit target; glyphs sit at 15pt so shuffle, skip and
    /// repeat weigh the same. Play is the one exception, one step larger.
    private func pillButton(
        _ label: String,
        icon: ImageResource? = nil,
        system: String? = nil,
        glyph: CGFloat = 15,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(icon).resizable().scaledToFit().frame(width: glyph, height: glyph)
                } else if let system {
                    Image(systemName: system)
                        .font(.system(size: glyph, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
    #endif

    // ---- Shared pieces ------------------------------------------------------

    @ViewBuilder
    private var artworkOrPlaceholder: some View {
        let side: CGFloat = inline ? 30 : 40
        if controller.current != nil {
            VideoSurface(cornerRadius: 8) {
                ArtworkView(entry: controller.current, side: side)
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 0.5)
                }
                .id(controller.current?.id)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.6))
                .frame(width: side, height: side)
                .overlay {
                        Image(.bchMusicNote)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 17)
                            .foregroundStyle(.secondary)
                }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(controller.current?.title ?? "Not Playing")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(controller.current == nil ? .secondary : .primary)
                    .lineLimit(1)
                if controller.current?.videoId != nil {
                    Image(systemName: controller.isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(controller.isLiked ? Color.pink : Color.secondary.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
            // Inline there is room for the title alone, as in Music.
            if !inline {
                Text(controller.current?.artist ?? "Music you start appears here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var miniPlayerAccessibilityLabel: String {
        var parts = [controller.current?.title ?? "Not Playing", controller.current?.artist ?? ""]
        if controller.current?.videoId != nil { parts.append(controller.isLiked ? "Liked" : "Not liked") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - The party

    /**
     * Who is listening, and the way in when nobody is.
     *
     * A person glyph and nothing else, on the same reasoning as the rest of this
     * pill: the pill is a row of transport glyphs, and anything that is not transport
     * belongs in the player. But the *count* does belong here, because this is where
     * a listener looks to find out whether anybody else is listening at all, and the
     * alternative — opening the player to discover it — is a step for a fact.
     *
     * Highlighted when in a party, so the pill says "you are not playing this on your
     * own" at a glance. Upstream does the same, and for the same reason.
     */
    private var partyButton: some View {
        let party = PartyStore.shared
        return Button {
            if party.inParty {
                // Who is here, rather than the screen that manages it: there is
                // nothing to create or join once there is a party, and a listener who
                // is already playing wants to know who else is here rather than go
                // and manage anything.
                appModel.partyMembersPresented = true
            } else {
                appModel.listenTogetherPresented = true
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "person.2.fill")
                    .scaledFont(size: 15, weight: .semibold)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
                if party.inParty, party.state.members.count > 1 {
                    Text("\(party.state.members.count)")
                        .scaledFont(size: 9, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(party.inParty ? Color.accentColor : .secondary)
        .help(partyHelp(party))
        .accessibilityLabel(partyHelp(party))
    }

    /// Spoken, the count is the whole point of the control; drawn, it would cost the
    /// pill its symmetry for something the badge already says.
    private func partyHelp(_ party: PartyStore) -> String {
        guard party.inParty else { return "Listen together" }
        let count = party.state.members.count
        return count > 1 ? "Listening together · \(count)" : "Listening together"
    }

    /// Track actions open as a native menu anchored to this button. It stays tied
    /// to the mini player instead of becoming a detached player-sized overlay.
    @ViewBuilder
    private var playerActionsButton: some View {
        #if os(macOS)
        Menu { playerActionItems } label: { playerActionLabel }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(controller.current == nil)
        #else
        Menu { playerActionItems } label: { playerActionLabel }
            .disabled(controller.current == nil)
        #endif
    }

    @ViewBuilder
    private var playerActionItems: some View {
        if let current = controller.current {
            SongActionButtons(entry: current, showSleepTimer: false)
        }
    }

    private var playerActionLabel: some View {
        Image(systemName: "ellipsis")
            .scaledFont(size: 15, weight: .semibold)
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .foregroundStyle(.secondary)
    }

    private var queueButton: some View {
        Button {
            PlatformSettings.shared.putString(key: "last_player_screen", value: "QUEUE")
            appModel.nowPlayingPresented = true
        } label: {
            Image(.bchQueue)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Queue")
        .accessibilityLabel("Queue")
    }

    private var reduceBlur: Bool {
        PlatformSettings.shared.getBoolean(key: "reduce_dynamic_blur", default: false)
    }

    /// The pill's fill, honouring both the app's own preference and the system's.
    ///
    /// Two settings, and the difference matters: `reduce_dynamic_blur` is a
    /// preference *this app* offers and someone can turn it off, while Reduce
    /// Transparency is a system accessibility setting that applies to every
    /// translucent surface on the device. Reading only the first — which is what
    /// this did — left the pill as the one surface in the app that stayed
    /// translucent for someone who had asked the system, everywhere, for it not to
    /// be.
    private var chromeFill: AnyShapeStyle {
        if reduceTransparency || reduceBlur {
            return AnyShapeStyle(Color.primary.opacity(0.12))
        }
        #if os(iOS)
        if #available(iOS 26.0, *), horizontalSizeClass == .compact {
            // On compact width (iPhone), the system bottom accessory draws its
            // own glass shell; a material inside it would be a second, opaque
            // surface inside the first. On regular width (iPad), the pill is
            // mounted via safeAreaInset and owns its own glass/material texture.
            return AnyShapeStyle(.clear)
        }
        #endif
        return AnyShapeStyle(.ultraThinMaterial)
    }

    /// Progress hairline hugging the iOS mini-player's bottom edge.
    private var progressHairline: some View {
        GeometryReader { geo in
            let progress = controller.duration > 0
                ? controller.position / controller.duration
                : 0
            Capsule()
                .fill(.tertiary)
                .frame(width: geo.size.width * progress, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    #if os(iOS)
    /// The mini-player's capsule shell — drawn by us everywhere except inside
    /// iOS 27's bottom accessory on iPhone, whose container draws its own
    /// pill. Keeping ours there nests a second capsule inside the system's
    /// (verified by stripping ours in the simulator: the pill still renders
    /// fully). iPad mounts via inset with no system shell, so it keeps ours,
    /// as do iOS 26 and the pre-26 fallback.
    private struct MiniPlayerChrome: ViewModifier {
        var fill: AnyShapeStyle
        var reduceTransparency: Bool
        @Environment(\.horizontalSizeClass) private var sizeClass

        func body(content: Content) -> some View {
            if #available(iOS 27.0, *), sizeClass == .compact {
                content
            } else if sizeClass == .regular {
                // Over the library the pill has artwork under it, so on iPad
                // (where it floats in a safeAreaInset with no system accessory
                // container) use regular material with the system background
                // colour beneath — matching the Mac pill's frosted texture so
                // album sleeves beneath don't bleed through the controls.
                content
                    .background {
                        if reduceTransparency {
                            Capsule().fill(Color(uiColor: .secondarySystemBackground))
                        } else {
                            Capsule().fill(Color(uiColor: .systemBackground).opacity(0.55))
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5) }
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            } else {
                content
                    .background { Capsule().fill(fill) }
                    .overlay { Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5) }
                    .clipShape(Capsule())
            }
        }
    }
    #endif

    #if os(iOS)
    /// The pill's long-press menu: up next, then the two panes the pill does not
    /// otherwise reach.
    ///
    /// Only a handful of rows: a menu is a glance, and the queue pane is one
    /// button away at the bottom of it. Jumps go through `playQueueItem`, which is
    /// what the queue pane's own rows use, so a jump from here and a jump from
    /// there cannot mean different things.
    @ViewBuilder
    private var quickQueueMenu: some View {
        let start = controller.playingIndex + 1
        let upcoming: [(offset: Int, entry: QueueEntry)] = controller.queue.indices.contains(start)
            ? Array(controller.queue[start...].prefix(4).enumerated()).map { (offset: $0.offset, entry: $0.element) }
            : []

        if upcoming.isEmpty {
            Button("Nothing Queued") {}.disabled(true)
        } else {
            // Keyed by position, not by track id: the same song may sit in the
            // queue twice, and two rows sharing an id would collapse into one.
            ForEach(upcoming, id: \.offset) { item in
                Button {
                    Haptics.play(.tap)
                    controller.playQueueItem(at: start + item.offset)
                } label: {
                    Text(item.entry.artist.isEmpty
                         ? item.entry.title
                         : "\(item.entry.title) — \(item.entry.artist)")
                }
            }
            Button("Clear Up Next", role: .destructive) {
                Haptics.play(.tap)
                controller.clearUpcoming()
            }
        }

        Divider()

        Button {
            PlatformSettings.shared.putString(key: "last_player_screen", value: "QUEUE")
            appModel.nowPlayingPresented = true
        } label: {
            Label("Queue", systemImage: "list.bullet")
        }

        Button {
            PlatformSettings.shared.putString(key: "last_player_screen", value: "LYRICS")
            appModel.nowPlayingPresented = true
        } label: {
            Label("Lyrics", systemImage: "quote.bubble")
        }

        Button {
            appModel.nowPlayingPresented = true
        } label: {
            Label("Open Player", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }

    private var buttons: some View {
        HStack(spacing: inline ? 2 : 8) {
            Button {
                Haptics.play(controller.isPlaying ? .pause : .resume)
                controller.togglePlayPause()
            } label: {
                if controller.isBuffering {
                    ProgressView().controlSize(.small).frame(width: 22, height: 22)
                } else {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .scaledFont(size: 20, weight: .semibold)
                }
            }
            .buttonStyle(.plain)
            .frame(width: inline ? 34 : 40, height: inline ? 34 : 40)
            .disabled(controller.current == nil && !controller.isBuffering)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            Button {
                Haptics.play(.skipNext)
                controller.next()
            } label: {
                Image(systemName: "forward.fill")
                    .scaledFont(size: 19, weight: .semibold)
            }
            .buttonStyle(.plain)
            .frame(width: inline ? 34 : 40, height: inline ? 34 : 40)
            .foregroundStyle(
                PartyStore.shared.state.controlsLocked ? Color.primary.opacity(0.3) : Color.primary
            )
            .disabled(!controller.canPlayNext || PartyStore.shared.state.controlsLocked)
            .accessibilityLabel("Next")

            if !inline {
                partyButton.frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(.primary)
    }

    private var padLeadingTransport: some View {
        HStack(spacing: 4) {
            Button {
                guard controller.canPlayPrevious else { return }
                Haptics.play(.skipPrevious)
                controller.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .scaledFont(size: 15, weight: .semibold)
                    .frame(width: 34, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canPlayPrevious)
            .accessibilityLabel("Previous")

            if controller.isBuffering {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
            } else {
                Button {
                    Haptics.play(controller.isPlaying ? .pause : .resume)
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .scaledFont(size: 18, weight: .semibold)
                        .frame(width: 34, height: 34)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(controller.current == nil && !controller.isBuffering)
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
            }

            Button {
                guard controller.canPlayNext else { return }
                Haptics.play(.skipNext)
                controller.next()
            } label: {
                Image(systemName: "forward.fill")
                    .scaledFont(size: 15, weight: .semibold)
                    .frame(width: 34, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                PartyStore.shared.state.controlsLocked ? Color.primary.opacity(0.3) : Color.primary
            )
            .disabled(!controller.canPlayNext || PartyStore.shared.state.controlsLocked)
            .accessibilityLabel("Next")
        }
        .foregroundStyle(.primary)
    }

    private var padTrailingControls: some View {
        HStack(spacing: 6) {
            playerActionsButton

            Button {
                appModel.nowPlayingPresented = true
                PlatformSettings.shared.putString(key: "last_player_screen", value: "LYRICS")
            } label: {
                Image(.bchLyrics)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Lyrics")

            queueButton

            AirPlayRouteButton()
                .frame(width: 22, height: 22)
                .frame(width: 32, height: 32)
                .accessibilityLabel("AirPlay")

            partyButton.frame(width: 32, height: 32)
        }
    }
    #endif
}

#if os(macOS)
/// The now-playing slot inside the original pill chrome. At rest: artwork +
/// title, with a 2pt seek line only as wide as this slot. Hover: that line
/// thickens and the times replace the artwork, without touching the pill shape.
private struct MacNowPlayingSlot<Artwork: View, Info: View>: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @ViewBuilder var artwork: Artwork
    @ViewBuilder var info: Info

    @State private var hovering = false
    @State private var dragging = false

    init(@ViewBuilder artwork: () -> Artwork, @ViewBuilder info: () -> Info) {
        self.artwork = artwork()
        self.info = info()
    }

    private var scrubbing: Bool { (hovering || dragging) && controller.duration > 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 10) {
                artwork
                info
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .opacity(scrubbing ? 0.35 : 1)
            .blur(radius: scrubbing ? 1.5 : 0)
            .allowsHitTesting(!scrubbing)
            .contentShape(.rect)
            .onTapGesture { appModel.nowPlayingPresented = true }

            if controller.duration > 0 {
                VStack(spacing: 3) {
                    if scrubbing {
                        HStack {
                            Text(clock(controller.position))
                            Spacer(minLength: 0)
                            Text(clock(max(controller.duration - controller.position, 0), remaining: true))
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                    }
                    SlotSeekLine(
                        progress: min(max(controller.position / controller.duration, 0), 1),
                        thick: scrubbing,
                        onSeek: { fraction in
                            controller.seek(to: fraction * controller.duration)
                        },
                        onDragging: { dragging = $0 }
                    )
                }
                .contentShape(.rect)
                .onHover { hovering = $0 }
            }
        }
        .frame(height: 44)
        .clipped()
        .animation(.easeInOut(duration: 0.16), value: scrubbing)
    }

    private func clock(_ seconds: Double, remaining: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0 else { return remaining ? "-0:00" : "0:00" }
        let total = Int(seconds.rounded(.down))
        let body = "\(total / 60):\(String(format: "%02d", total % 60))"
        return remaining ? "-\(body)" : body
    }
}

private struct SlotSeekLine: View {
    var progress: Double
    var thick: Bool
    var onSeek: (Double) -> Void
    var onDragging: (Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h: CGFloat = thick ? 8 : 2
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(thick ? 0.28 : 0.18))
                Capsule()
                    .fill(.primary.opacity(thick ? 0.95 : 0.55))
                    .frame(width: max(0, w * min(max(progress, 0), 1)))
            }
            .frame(height: h)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onDragging(true)
                        onSeek(min(max(g.location.x / max(w, 1), 0), 1))
                    }
                    .onEnded { _ in onDragging(false) }
            )
        }
        .frame(height: 8)
    }
}
#endif

/// Slim volume slider — hairline capsule track with a small knob, in the
/// spirit of upstream's `ThinSlider`. Adapts to the surrounding foreground
/// style (dark Now Playing backdrop vs. light pill).
struct PillSlider: View {
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            GeometryReader { geo in
                let w = geo.size.width
                let x = w * volume
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: max(4, x), height: 4)
                    Circle()
                        .fill(.primary)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(0, x - 5), w - 10))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .frame(height: geo.size.height)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            volume = min(max(0, g.location.x / w), 1)
                        }
                )
            }
            .frame(height: 14)
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume = min(1, volume + 0.1)
            case .decrement: volume = max(0, volume - 0.1)
            default: break
            }
        }
    }
}

#if os(iOS)
/// WWDC 323: the mini player is the zoom source for the Now Playing sheet.
private struct NowPlayingZoomSource: ViewModifier {
    @Environment(\.nowPlayingZoomNamespace) private var zoomNamespace

    func body(content: Content) -> some View {
        if let zoomNamespace {
            content.matchedTransitionSource(id: NowPlayingZoom.sourceID, in: zoomNamespace)
        } else {
            content
        }
    }
}
#endif
