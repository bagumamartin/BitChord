import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
import AVFAudio
import Photos
#else
import AppKit
#endif

struct LyricsPane: View {
    var lines: [LyricLineDto]
    /// The lyric before translation, when the caller has it. The pane shows
    /// the translation in place; the share card needs both, original above and
    /// translation underneath.
    var originalLines: [LyricLineDto]? = nil
    var loading: Bool
    /// The transport clock. Only the ticker and the line being sung read it,
    /// so the list itself redraws once per line rather than once per frame.
    var clock: LyricsClock
    /// The sung line's type size; the Mac inspector column asks for less.
    var fontSize: CGFloat = 34
    var hasTrack: Bool
    var sourceLabel: String? = nil
    var alignmentInProgress: Bool = false
    /// How much of the lyric this app's on-device alignment timed. The
    /// attribution claims only what was actually timed.
    var alignedLocally: LyricsAudioAligner.Coverage? = nil
    /// Opens the per-track provider picker — shown with the no-lyrics state,
    /// where it is most needed and previously unreachable.
    var onChooseSource: (() -> Void)? = nil
    var onSeek: ((Double) -> Void)? = nil
    /// Absent where the caller has no track to translate, which is the case that
    /// matters: an empty lyric has nothing to translate and offering the control
    /// anyway is an invitation to a request that cannot succeed.
    var translator: LyricsTranslator?
    var trackId: String = ""
    /// The listener's timing correction, in milliseconds. See [LyricsOffsetBridge].
    var offsetMs: Int32 = 0
    var sourceVisible: Bool = true
    /// True while the header's share entry has picking armed. The pane shows
    /// the quote bar for an empty pick so there is somewhere to aim, and
    /// reports back so the header can stop being the way out.
    var sharePicking: Bool = false
    var onSharePicking: ((Bool) -> Void)? = nil
    var onChangeSource: (() -> Void)? = nil
    var onRevealControls: (() -> Void)? = nil
    var onFocusLyrics: (() -> Void)? = nil
    /// Whether lines are being picked for a share card: armed from the header,
    /// or merely because something is already picked. While it holds, a line
    /// tap toggles the pick instead of seeking.
    var picking: Bool { sharePicking || !selection.isEmpty }
    /// What the share card names. The pane draws lines; the card has to say
    /// whose song they are, and only the caller knows.
    var trackTitle: String = ""
    var trackArtist: String = ""
    var artworkData: Data? = nil
    var artworkUrl: String? = nil
    /// Lyric lines picked for a share card, within [maxSharedCharacters].
    @State private var selection: Set<Int> = []
    @State private var shareImage: Image?
    @State private var shareImageData: Data?
    @State private var storyCardFormat = false
    @State private var showPhotoSaveAlert = false
    @State private var photoSaveMessage = ""
    /// True while the listener is scrolling the list themselves, which stands the
    /// auto-scroll down until they have been still for a moment.
    @State private var reading = false
    @State private var focus = LyricFocusState()
    @State private var cache = LyricsDocumentCache()
    @AppStorage("lyrics_blur") private var lyricsBlur = true
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// Bound the quote by characters so a short line does not use up the same
    /// budget as a long one. Count the original text that the card quotes.
    private let maxSharedCharacters = 250

    private var selectedCharacterCount: Int {
        selection.reduce(0) { $0 + shareText(at: $1).count }
    }

    private func shareText(at index: Int) -> String {
        if let originalLines, originalLines.indices.contains(index) {
            return originalLines[index].text
        }
        return lines.indices.contains(index) ? lines[index].text : ""
    }

    /// Where tapping a line should actually seek.
    ///
    /// The inverse of the lyric clock (`LyricsClock.lyricMs`), and it has to be the inverse: a line
    /// whose nominal time is `t` is shown when the adjusted clock reaches `t`,
    /// which is transport position `t + offset`. Seeking to `t` instead would put
    /// the listener a line behind every time they tapped one.
    private func seekTarget(for row: LyricRow) -> Double {
        let ms = max(0, row.timeMs + Swift.Int64(offsetMs))
        return Double(ms) / 1000.0
    }

    /// The focus the ticker last reported, or — for a document it has not seen
    /// yet — one read straight off the clock, so a new lyric opens on the right
    /// line instead of on the first one for a frame.
    private func currentFocus(_ document: PreparedLyrics) -> LyricFocusState {
        if focus.document == ObjectIdentifier(document) { return focus }
        return document.timeline.focus(
            at: clock.lyricMs(at: Date(), offsetMs: offsetMs),
            document: ObjectIdentifier(document)
        )
    }

    /// Down a phone the sung line is read from near the top, with the stack
    /// below it; everywhere else it sits in the middle of the column.
    private var phoneColumn: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var scrollAnchor: UnitPoint {
        phoneColumn ? UnitPoint(x: 0.5, y: 0.32) : .center
    }

    /// How a row sits in the stack, by its distance from the line being sung.
    private func look(for row: LyricRow, document: PreparedLyrics, focus: LyricFocusState, active: Bool) -> LyricRowLook {
        guard document.synced else { return LyricRowLook(alpha: 0.95, blur: 0, scale: 1) }
        guard row.timed else { return LyricRowLook(alpha: 0.9, blur: 0, scale: 1) }
        if active { return LyricRowLook(alpha: 1, blur: 0, scale: 1) }
        if reading { return LyricRowLook(alpha: LyricStyle.browsingAlpha, blur: 0, scale: LyricStyle.inactiveScale) }
        let falloff = phoneColumn ? LyricStyle.falloffAlphaPhone : LyricStyle.falloffAlpha
        let distance = abs(row.id - focus.lead)
        let blur = lyricsBlur
            ? LyricStyle.falloffBlur[min(distance, LyricStyle.falloffBlur.count - 1)]
            : 0
        return LyricRowLook(
            alpha: falloff[min(distance, falloff.count - 1)],
            blur: blur,
            scale: LyricStyle.inactiveScale
        )
    }

    private var tapMode: LyricTapMode {
        !sourceVisible ? .reveal : (picking ? .pick : .seek)
    }

    @ViewBuilder
    private func rowView(_ row: LyricRow, document: PreparedLyrics, focus: LyricFocusState) -> some View {
        if row.isGap && !document.synced {
            Spacer().frame(height: 14)
        } else if row.isGap {
            LyricGapRow(
                row: row,
                open: focus.gap == row.id,
                look: look(for: row, document: document, focus: focus, active: focus.gap == row.id),
                offsetMs: offsetMs,
                clock: clock,
                onTap: { if !picking { onSeek?(seekTarget(for: row)) } }
            )
        } else {
            let active = focus.active.contains(row.id)
            let mode = tapMode
            LyricRowView(
                row: row,
                document: ObjectIdentifier(document),
                active: active,
                look: look(for: row, document: document, focus: focus, active: active),
                fontSize: fontSize,
                duet: document.duet,
                picked: selection.contains(row.id),
                picking: picking,
                tapMode: mode,
                offsetMs: offsetMs,
                clock: clock,
                onTap: {
                    switch mode {
                    case .reveal: onRevealControls?()
                    case .pick: toggleShareSelection(row.id)
                    case .seek: onSeek?(seekTarget(for: row))
                    }
                }
            )
            .equatable()
            .contextMenu {
                Button(selection.contains(row.id) ? "Remove from Share" : "Add to Share") {
                    toggleShareSelection(row.id)
                }
            }
            // While picking, the line is its own toggle: a tap adds or removes
            // it rather than seeking, which is what the bar's hint promises
            // (upstream L14). With the controls hidden and nothing being
            // picked, the tap still belongs to revealing them.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(picking && selection.contains(row.id) ? [.isSelected] : [])
            .accessibilityHint(picking ? "Double-tap to add to the share card" : "")
        }
    }

    var body: some View {
        Group {
            if !hasTrack {
                Text("Play a song to see lyrics here.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
            } else if loading {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            } else if lines.isEmpty {
                VStack(spacing: 14) {
                    Text("No lyrics for this track.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                    if let onChooseSource {
                        // Upstream's status row stays tappable when a track has
                        // no lyric: the sources that lost the race are still
                        // there, and "search again" can still answer.
                        Button("Choose a Source…") { onChooseSource() }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let translator {
                        LyricsTranslationNote(outcome: translator.outcome)
                            .padding(.horizontal, 12)
                    }
                    ScrollViewReader { proxy in
                        let document = cache.document(for: lines)
                        let focus = currentFocus(document)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(document.rows) { row in
                                    rowView(row, document: document, focus: focus)
                                        .id(row.id)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollIndicators(.never)
                        .background {
                            LyricsFocusTicker(document: document, clock: clock, offsetMs: offsetMs) { next in
                                if next != self.focus { self.focus = next }
                            }
                        }
                        // Following the *lead* line rather than the last one that
                        // has started: across a duet those differ, and scrolling
                        // to the answer would push the lead off the top while it
                        // was still the line being sung.
                        .onAppear {
                            proxy.scrollTo(focus.lead, anchor: scrollAnchor)
                        }
                        .onChange(of: trackId) { _, _ in
                            reading = false
                            proxy.scrollTo(focus.lead, anchor: scrollAnchor)
                        }
                        .onChange(of: focus.lead) { _, index in
                            // Not while the listener is reading. A list that
                            // snaps back to the playhead as soon as they let go
                            // is a list nobody can look anything up in.
                            guard !reading else { return }
                            withAnimation(LyricStyle.settle) {
                                proxy.scrollTo(index, anchor: scrollAnchor)
                            }
                        }
                        // The reader's own scroll stands the auto-scroll down
                        // until they have been still for a moment. This is a
                        // separate gesture rather than a `DragGesture` on the
                        // ScrollView so it does not compete with the scroll
                        // itself — simultaneous, and only asked whether a finger
                        // is down.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    reading = true
                                    // Advancing through the transcript (finger
                                    // moves up) gives the lyrics the whole view;
                                    // scrolling back reveals the deck again.
                                    if value.translation.height < -20, sourceVisible {
                                        onFocusLyrics?()
                                    } else if value.translation.height > 20, !sourceVisible {
                                        onRevealControls?()
                                    }
                                }
                                .onEnded { _ in
                                    withAnimation(.easeOut(duration: 1.6).delay(2.5)) {
                                        reading = false
                                    }
                                }
                        )
                    }
                    if !selection.isEmpty || sharePicking {
                        shareBar
                            .padding(.horizontal, 12)
                    }
                    if sourceVisible, let credit = attribution {
                        HStack(spacing: 8) {
                            Text(credit)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.72))
                            if let onChangeSource {
                                Button("Change", action: onChangeSource)
                                    .buttonStyle(.plain)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.14), in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A share card belongs to the song and the lyric it quoted. A new track,
        // or a different lyric source for the same one, makes the old card
        // describe something else — and it would still be sitting in the share
        // preview under the new song's name. The armed pick ends with them:
        // an armed bar that follows you into the next song is a trap.
        .onChange(of: trackId) { _, _ in
            clearShareSelection()
            onSharePicking?(false)
        }
        .onChange(of: lyricsSignature) { _, _ in
            clearShareSelection()
            onSharePicking?(false)
        }
        // Leaving pick mode — from the header's close or the bar's Done —
        // empties the pick with it. Arriving never has to: a fresh pick starts
        // from the same empty state these clearings leave behind.
        .onChange(of: sharePicking) { _, picking in
            if !picking { clearShareSelection() }
        }
        .alert("Save Share Card", isPresented: $showPhotoSaveAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoSaveMessage)
        }
    }

    /// What makes one lyric document different from another: the line objects
    /// themselves. A re-fetch or a translation brings new ones, so the share
    /// card is cleared exactly when the words it quoted may have changed — and
    /// comparing identities costs nothing per render, where hashing every
    /// line's text did.
    private var lyricsSignature: Int {
        var hasher = Hasher()
        hasher.combine(sourceLabel)
        for line in lines { hasher.combine(ObjectIdentifier(line)) }
        return hasher.finalize()
    }

    private func clearShareSelection() {
        guard !selection.isEmpty || shareImage != nil || storyCardFormat else { return }
        selection.removeAll()
        shareImage = nil
        shareImageData = nil
        storyCardFormat = false
    }

    /// The quote bar: what has been picked, and the way to share it.
    private var shareBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedCharacterCount)/\(maxSharedCharacters) characters")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 0)
            if let shareImage {
                Menu {
                    Button("Standard card") { selectStoryCardFormat(false) }
                    Button("Story · 9:16") { selectStoryCardFormat(true) }
                } label: {
                    Label(storyCardFormat ? "9:16" : "Card", systemImage: "aspectratio")
                }
                .font(.caption.weight(.semibold))
                .accessibilityLabel("Share card format")
                .help(storyCardFormat ? "Story format, 9:16" : "Standard card format")
                #if os(iOS)
                Button(action: saveShareCardToPhotos) {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(shareImageData == nil)
                .accessibilityLabel("Save to Photos")
                .help("Save to Photos")
                #endif
                ShareLink(
                    item: shareImage,
                    preview: SharePreview(
                        trackTitle.isEmpty ? "Lyrics" : "\(trackTitle) — lyrics",
                        image: shareImage
                    )
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
            } else if selection.isEmpty {
                // An armed pick with nothing in it yet: say what to do rather
                // than spin a card that does not exist.
                Text("Pick lines to share")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
            Button("Done") {
                selection.removeAll()
                shareImage = nil
                shareImageData = nil
                storyCardFormat = false
                onSharePicking?(false)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.10), in: Capsule())
        .task(id: shareCardKey) { renderShareCard() }
    }

    /// What makes the card worth re-rendering: the pick, and whether the
    /// translation it would quote underneath has arrived or changed.
    private var shareCardKey: ShareCardKey {
        ShareCardKey(
            selection: selection,
            translated: translator?.translatedLines != nil,
            storyFormat: storyCardFormat
        )
    }

    private func selectStoryCardFormat(_ story: Bool) {
        guard storyCardFormat != story else { return }
        storyCardFormat = story
        shareImage = nil
        shareImageData = nil
    }

    private struct ShareCardKey: Equatable {
        var selection: Set<Int>
        var translated: Bool
        var storyFormat: Bool
    }

    private func toggleShareSelection(_ index: Int) {
        if selection.contains(index) {
            selection.remove(index)
        } else if lines.indices.contains(index) {
            let nextTotal = selectedCharacterCount + shareText(at: index).count
            if selection.isEmpty || nextTotal <= maxSharedCharacters {
                selection.insert(index)
            }
        }
        Haptics.play(.select)
    }

    /// The picked lines as the card draws them. A jump over unchosen lines
    /// becomes the omission mark, so the picture says the verse was cut rather
    /// than letting two distant halves read as if they ran on (upstream
    /// LyricsShare.kt:249). The line quoted is the original and the translation
    /// travels as its sub-line — the pane shows the translation in place, but a
    /// card that never says what was actually sung is not a quote.
    private var pickedCardLines: [LyricShareCard.Line] {
        let subLines = translator?.translatedLines
        let subbed = subLines?.count == lines.count
        var out: [LyricShareCard.Line] = []
        var previous = -1
        for index in selection.sorted() {
            guard lines.indices.contains(index) else { continue }
            if previous >= 0, index > previous + 1 {
                out.append(LyricShareCard.Line(text: "", isGap: true))
            }
            let original = shareText(at: index)
            let sub = subbed ? subLines?[index].text : nil
            out.append(LyricShareCard.Line(
                text: original,
                subText: sub.flatMap {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty || $0 == original ? nil : $0
                }
            ))
            previous = index
        }
        return out
    }

    /// Draws the card once per selection. `ImageRenderer` is main-actor work, so
    /// this is an `.task`, and the result is kept until the selection changes.
    private func renderShareCard() {
        guard !selection.isEmpty else {
            shareImage = nil
            shareImageData = nil
            return
        }
        let tint = ArtworkPalette.pageTint(
            from: artworkData,
            seed: trackTitle.hashValue,
            dark: true
        )
        let card = LyricShareCard(
            lines: pickedCardLines,
            title: trackTitle,
            artist: trackArtist,
            tint: tint,
            artwork: artworkData,
            artworkUrl: artworkUrl,
            storyFormat: storyCardFormat
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        #if os(iOS)
        if let image = renderer.uiImage {
            shareImage = Image(uiImage: image)
            shareImageData = image.pngData()
        } else {
            shareImage = nil
            shareImageData = nil
        }
        #else
        if let image = renderer.nsImage {
            shareImage = Image(nsImage: image)
            shareImageData = image.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
        } else {
            shareImage = nil
            shareImageData = nil
        }
        #endif
    }

    #if os(iOS)
    @MainActor
    private func saveShareCardToPhotos() {
        guard let shareImageData else { return }
        Task { @MainActor in
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized else {
                photoSaveMessage = "Allow BitChord to add photos in Settings to save this card."
                showPhotoSaveAlert = true
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: shareImageData, options: nil)
                }
                photoSaveMessage = "Saved to Photos."
            } catch {
                photoSaveMessage = "The share card could not be saved to Photos."
            }
            showPhotoSaveAlert = true
        }
    }
    #endif

    private var attribution: String? {
        guard let sourceLabel, !sourceLabel.isEmpty else { return nil }
        if alignmentInProgress { return "Lyrics by \(sourceLabel) · syncing words…" }
        // Claim only what the audio actually timed. "Synced by BitChord" used
        // to appear when a single line matched; a part-timed lyric now says
        // how much, and a pass that matched nothing claims nothing.
        if let coverage = alignedLocally, coverage.timed > 0 {
            if coverage.fraction >= 0.8 { return "Lyrics by \(sourceLabel) · Synced by BitChord" }
            return "Lyrics by \(sourceLabel) · BitChord synced \(coverage.timed) of \(coverage.total) lines"
        }
        let document = cache.document(for: lines)
        guard document.synced else { return "Lyrics by \(sourceLabel) · unsynced" }
        return document.fullyTimed
            ? "Lyrics by \(sourceLabel)"
            : "Lyrics by \(sourceLabel) · partially synced"
    }
}

func lyricTextIsRightToLeft(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        let value = scalar.value
        guard CharacterSet.letters.contains(scalar) else { continue }
        return (0x0590...0x08FF).contains(value) ||
            (0xFB1D...0xFDFF).contains(value) ||
            (0xFE70...0xFEFF).contains(value) ||
            (0x1EE00...0x1EEFF).contains(value)
    }
    return false
}

/// Upstream's lyrics-sources sheet lives in [LyricsLanguageSheet.swift] as
/// [LyricsSourcesSheet] (the fuller superset: try-order, PaxSeniX key,
/// word-sync preference, reset). The player's More menu presents that same
/// sheet rather than a local copy, so the two can never drift.
