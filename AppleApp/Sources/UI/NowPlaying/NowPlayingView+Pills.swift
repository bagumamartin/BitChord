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

// Credits, the action row, and the output/party and queue-mode pills.
extension NowPlayingView {
    /// Title and artist, with the like and the overflow menu beside them.
    var creditsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.current?.title ?? "Nothing playing")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                ArtistCreditText(
                    credit: controller.current?.artist ?? "",
                    font: .subheadline,
                    color: .white.opacity(0.75),
                    suffix: albumSuffix
                )
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
            }
            Spacer(minLength: 8)
            if auth.signedIn, controller.current?.videoId != nil {
                GlassCircleButton(
                    icon: controller.isLiked ? .bchHeartFilled : .bchHeart,
                    label: controller.isLiked ? "Remove Like" : "Like"
                ) {
                    controller.toggleLike()
                }
                .help(controller.isLiked ? "Remove from Liked Music" : "Like")
            }
            moreMenu
        }
        .padding(.horizontal, 24)
    }

    /// Below-volume pill, pane-reactive on every layout that carries one:
    /// the queue-modes pill (shuffle · repeat · AutoPlay · AutoMix) in the
    /// queue pane, output/party everywhere else. One definition so the
    /// portrait deck, compact landscape and desktop columns cannot disagree
    /// about which pill a pane shows — the desktop column used to hardcode
    /// the output pill, which is why pane toggles never changed anything on
    /// iPad landscape or macOS.
    var actionRowPill: some View {
        Group {
            if pane == .queue {
                queueModesPill
            } else {
                outputPartyPill
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// Which of the three panes is showing.
    ///
    /// The artwork toggle is here rather than implied by the artwork's size: a
    /// control that only exists while a panel is closed cannot be used to open
    /// the first one, and one that only exists while a panel is open cannot be
    /// used to leave it.
    /// Lyrics and Up Next stay at the two ends. The middle pill follows the
    /// pane through `actionRowPill`, the same definition every layout uses.
    var playerActionRow: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let edgeInset = actionRowEdgeInset(width: geometry.size.width)
                HStack {
                    actionGlyph(.bchLyrics, selected: pane == .lyrics, label: "Lyrics") {
                        Haptics.play(.expand)
                        pane = pane == .lyrics ? .main : .lyrics
                    }
                    Spacer(minLength: 0)
                    // The queue pane swaps the output/party pill for the
                    // queue-modes pill (shuffle · repeat · AutoPlay · AutoMix).
                    // This is the pill's only home, and it is per platform and
                    // pane alike: iPad used to be excluded here, which is why its
                    // queue pane showed output controls instead of these.
                    actionRowPill
                    Spacer(minLength: 0)
                    actionGlyph(.bchQueue, selected: pane == .queue, label: "Up Next") {
                        Haptics.play(.expand)
                        pane = pane == .queue ? .main : .queue
                    }
                }
                .padding(.horizontal, edgeInset)
            }
            .frame(height: 44)

            if !outputCaption.isEmpty {
                Text(outputCaption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .accessibilityLabel(outputCaption)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Where the action row's two 44pt glyph buttons start in from either edge.
    func actionRowEdgeInset(width: CGFloat) -> CGFloat {
        max(0, (width - (44 * 2 + 158)) / 4)
    }

    /// Where the Lyrics and Up Next glyphs' ink starts in from either edge:
    /// the button inset, the 26pt image's place in its 44pt button, and the
    /// 2 of 24 units each drawing leaves clear at its outer side.
    func actionGlyphInkInset(width: CGFloat) -> CGFloat {
        actionRowEdgeInset(width: width) + (44 - 26) / 2 + 26 * 2 / 24
    }

    func actionGlyph(
        _ image: ImageResource,
        selected: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                .frame(width: 44, height: 44)
                .background(.white.opacity(selected ? 0.2 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var outputPartyPill: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.play(.tap)
                showOutputDevice = true
            } label: {
                Image(systemName: "headphones")
                    .scaledFont(size: 23, weight: .regular)
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: outputPartyButtonWidth, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Audio output")

            pillDivider

#if os(iOS)
            if pane == .main {
                Button {
                    let enabled = !controller.mixWithOtherAudio
                    Haptics.play(enabled ? .toggleOn : .toggleOff)
                    controller.setMixWithOtherAudio(enabled)
                } label: {
                    Image(systemName: "waveform")
                        .scaledFont(size: 23, weight: .regular)
                        .foregroundStyle(.white.opacity(controller.mixWithOtherAudio ? 1 : 0.75))
                        .frame(width: outputPartyButtonWidth, height: 44)
                        .background(.white.opacity(controller.mixWithOtherAudio ? 0.14 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.audioMixing")
                .accessibilityLabel("Mix with Other Apps")
                .accessibilityValue(controller.mixWithOtherAudio ? "On" : "Off")
                .accessibilityHint(controller.mixWithOtherAudio
                    ? "Turn off to give BitChord audio priority. Other apps may pause."
                    : "Turn on to keep other apps audible.")
                .accessibilityAddTraits(controller.mixWithOtherAudio ? .isSelected : [])
                .help(controller.mixWithOtherAudio ? "Mixing on" : "BitChord audio priority")

                pillDivider
            }
#endif

            if pane == .main {
                Button {
                    let enabled = !showMusicVideos
                    Haptics.play(enabled ? .toggleOn : .toggleOff)
                    showMusicVideos = enabled
                } label: {
                    Image(systemName: showMusicVideos ? "play.rectangle.fill" : "play.rectangle")
                        .scaledFont(size: 22, weight: .regular)
                        .foregroundStyle(.white.opacity(showMusicVideos ? 1 : 0.75))
                        .frame(width: outputPartyButtonWidth, height: 44)
                        .background(.white.opacity(showMusicVideos ? 0.14 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.musicVideos")
                .accessibilityLabel("Music Videos")
                .accessibilityValue(showMusicVideos ? "On" : "Off")
                .accessibilityAddTraits(showMusicVideos ? .isSelected : [])
                .help(showMusicVideos ? "Music videos on" : "Music videos off")

                pillDivider
            }

            Button {
                Haptics.play(.tap)
                if party.inParty {
                    appModel.partyMembersPresented = true
                } else {
                    appModel.listenTogetherPresented = true
                }
            } label: {
                Image(systemName: "person.fill")
                    .scaledFont(size: 22, weight: .regular)
                    .foregroundStyle(.white.opacity(party.inParty ? 1 : 0.75))
                    .frame(width: outputPartyButtonWidth, height: 44)
                    .background(.white.opacity(party.inParty ? 0.14 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(party.inParty ? "People listening" : "Listen Together")
        }
        .background(.white.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }

    private var outputPartyButtonWidth: CGFloat {
#if os(iOS)
        pane == .main ? 52 : 64
#else
        64
#endif
    }

    /// The phone queue keeps its established shuffle/repeat/AutoPlay pill.
    /// iPad and desktop show these modes with the queue itself instead.
    var queueModesPill: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.play(controller.shuffleEnabled ? .toggleOff : .toggleOn)
                controller.toggleShuffle()
            } label: {
                Image(.bchShuffle)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white.opacity(controller.shuffleEnabled ? 1 : 0.75))
                    .frame(width: 52, height: 44)
                    .background(.white.opacity(controller.shuffleEnabled ? 0.14 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.shuffleEnabled ? "Shuffle on" : "Shuffle off")

            pillDivider

            Button {
                Haptics.play(.select)
                controller.cycleRepeat()
            } label: {
                Group {
                    if controller.repeatMode == .one {
                        Text("1").scaledFont(size: 19, weight: .bold)
                    } else {
                        Image(.bchRepeat).resizable().scaledToFit().frame(width: 22, height: 22)
                    }
                }
                .foregroundStyle(.white.opacity(controller.repeatMode == .off ? 0.75 : 1))
                .frame(width: 52, height: 44)
                .background(.white.opacity(controller.repeatMode == .off ? 0 : 0.14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(repeatLabel)

            pillDivider

            Button {
                Haptics.play(controller.autoplayEnabled ? .toggleOff : .toggleOn)
                controller.toggleAutoplay()
            } label: {
                Image(.bchInfinity)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white.opacity(controller.autoplayEnabled ? 1 : 0.75))
                    .frame(width: 52, height: 44)
                    .background(.white.opacity(controller.autoplayEnabled ? 0.14 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.autoplayEnabled ? "AutoPlay on" : "AutoPlay off")

            pillDivider

            // AutoMix is the fourth and last slot, at the right end of the pill.
            Button {
                Haptics.play(controller.automixEnabled ? .toggleOff : .toggleOn)
                controller.toggleAutomix()
            } label: {
                Image(.bchVinylRecord)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white.opacity(controller.automixEnabled ? 1 : 0.75))
                    .frame(width: 52, height: 44)
                    .background(.white.opacity(controller.automixEnabled ? 0.14 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.automixEnabled ? "AutoMix on" : "AutoMix off")
            .help(controller.automixEnabled
                ? "AutoMix blends the end of one track into the next"
                : "AutoMix off — tracks change at the end")
        }
        .background(.white.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }

    private var pillDivider: some View {
        Rectangle().fill(.white.opacity(0.20)).frame(width: 1, height: 44)
    }

    var outputCaption: String {
        // The live CoreAudio route, which is the only place the *current*
        // output is named on iOS: cpal's default device does not follow a
        // route change, so plugging in AirPods would have kept reporting the
        // built-in speaker. Read it per render — the player re-renders on every
        // position tick, so a route change lands without any observer.
        #if os(iOS)
        let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? ""
        let routeName = port.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        let routeName = controller.outputDevice.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
        let lowered = routeName.lowercased()
        if controller.outputDevice.started, !routeName.isEmpty,
           !lowered.contains("default output") {
            return routeName
        }
        if party.inParty { return party.state.you?.name ?? "Playing together" }
        return "Default Device"
    }
}
