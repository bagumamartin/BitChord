import SwiftUI
import BitChordShared

// How the lyric list is drawn, and how little of it has to move.
//
// The list used to sit inside a frame clock: every display frame re-ran the
// whole pane, asked the shared module three times which lines were being sung
// (each call walking the bridged list), re-split every line's words and rebuilt
// every row. That was one core, flat out, for as long as the lyrics were open.
//
// Now the work is split by how often it actually changes:
// - the document (rows, words, timings) is prepared once per lyric;
// - which lines are sung is read thirty times a second by a ticker that draws
//   nothing and only hands the pane a new focus when it differs, which is once
//   per line;
// - only the line being sung reads the clock every frame, and it only redraws
//   its own glyphs through [LyricSweepRenderer] — no layout, no list.

/// Where the transport is, for the views that need to know between ticks.
///
/// Handed down rather than a position, so reading the clock is something only
/// the line being sung (and the ticker) does. A position parameter re-ran the
/// whole pane every time it moved.
struct LyricsClock {
    var playing: Bool
    var read: (Date) -> Double

    /// The lyric clock in milliseconds: the transport, `offsetMs` behind.
    func lyricMs(at date: Date, offsetMs: Int32) -> Int64 {
        max(0, Int64(read(date) * 1000) - Int64(offsetMs))
    }
}

/// Which lines are being sung, the line the list follows, and the break that is
/// playing. Equatable so the ticker only reports a change.
struct LyricFocusState: Equatable {
    var document: ObjectIdentifier?
    var active: [Int] = []
    var lead = 0
    var gap: Int?
}

/// The shared module's [LyricFocus] over plain arrays.
///
/// The same rules, line for line (`activeRows`, `scrollLead`, `leadRow`), but
/// read from arrays built once per document instead of from a bridged Kotlin
/// list on every frame. `LyricFocusTest` in the shared module is still the
/// specification; change both together.
struct LyricTimeline {
    private let starts: [Int64]
    private let ends: [Int64]
    private let holds: [Bool]
    private let gaps: [Bool]
    let synced: Bool

    static let scrollLeadMinMs: Int64 = 350
    static let scrollLeadMaxMs: Int64 = 500

    init(lines: [LyricLineDto], synced: Bool) {
        var starts: [Int64] = [], ends: [Int64] = [], holds: [Bool] = [], gaps: [Bool] = []
        starts.reserveCapacity(lines.count)
        ends.reserveCapacity(lines.count)
        holds.reserveCapacity(lines.count)
        gaps.reserveCapacity(lines.count)
        for line in lines {
            starts.append(Self.startMs(line))
            ends.append(line.endMs)
            holds.append(line.hasKnownEnd || line.background?.hasKnownEnd == true)
            gaps.append(line.isGap)
        }
        self.starts = starts
        self.ends = ends
        self.holds = holds
        self.gaps = gaps
        self.synced = synced
    }

    /// A missing line stamp falls back to the first word's.
    static func startMs(_ line: LyricLineDto) -> Int64 {
        guard line.timeMs == 0 else { return line.timeMs }
        if let first = line.words.map(\.startMs).min() { return first }
        if let first = line.background?.words.map(\.startMs).min() { return first }
        return line.timeMs
    }

    private func lastStarted(by ms: Int64, skippingGaps: Bool = false) -> Int {
        var index = starts.count - 1
        while index >= 0 {
            if starts[index] <= ms, !(skippingGaps && gaps[index]) { return index }
            index -= 1
        }
        return -1
    }

    func focus(at ms: Int64, document: ObjectIdentifier?) -> LyricFocusState {
        guard synced, !starts.isEmpty else { return LyricFocusState(document: document) }
        let latest = lastStarted(by: ms)
        var active: [Int] = []
        if latest >= 0 {
            for index in 0...latest where !gaps[index] {
                if index == latest || (holds[index] && starts[index] <= ms && ms < ends[index]) {
                    active.append(index)
                }
            }
        }
        let lead: Int
        if let first = active.first {
            lead = first
        } else {
            lead = lastStarted(by: ms + scrollLead(latest: latest), skippingGaps: true)
        }
        return LyricFocusState(
            document: document,
            active: active,
            lead: lead < 0 ? 0 : min(lead, starts.count - 1),
            gap: latest >= 0 && gaps[latest] ? latest : nil
        )
    }

    private func scrollLead(latest: Int) -> Int64 {
        guard latest >= 0, latest + 1 < starts.count else { return Self.scrollLeadMinMs }
        return min(max(starts[latest + 1] - ends[latest], Self.scrollLeadMinMs), Self.scrollLeadMaxMs)
    }
}

struct LyricWord: Equatable {
    let text: String
    let startMs: Int64
    let endMs: Int64
}

/// One lyric line, prepared for drawing: everything the row needs that does not
/// depend on the clock.
struct LyricRow: Identifiable {
    let id: Int
    let isGap: Bool
    /// The line has its own timings. False for the rows of a transcript that
    /// on-device alignment has not reached yet; those stay crisp.
    let timed: Bool
    let secondVoice: Bool
    let rightToLeft: Bool
    /// What the row shows while it is not being sung. The words joined when
    /// there are words, so the line does not reflow as it starts.
    let leadText: String
    let backingText: String?
    /// The same words with their timings attached, for the sweep. Built once
    /// here: the frame clock only changes how they are drawn.
    let leadSwept: Text?
    let backingSwept: Text?
    let timeMs: Int64
    /// Where the break that this row stands for ends, for its dots.
    let untilMs: Int64
}

/// The lyric document as the pane draws it, rebuilt only when the lines do.
final class PreparedLyrics {
    let identity: [ObjectIdentifier]
    let rows: [LyricRow]
    let timeline: LyricTimeline
    let synced: Bool
    /// Some line is sung from the other side, so both voices keep a lane.
    let duet: Bool
    /// Every lyric row has timings (no "partially synced" credit).
    let fullyTimed: Bool

    init(lines: [LyricLineDto]) {
        identity = lines.map(ObjectIdentifier.init)
        let synced = LyricFocus.shared.isSynced(lines: lines)
        self.synced = synced
        timeline = LyricTimeline(lines: lines, synced: synced)
        var rows: [LyricRow] = []
        rows.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            rows.append(Self.row(line, at: index, synced: synced,
                                 until: next.map(LyricTimeline.startMs) ?? line.endMs))
        }
        self.rows = rows
        duet = lines.contains { $0.alignment == .end }
        let lyricRows = rows.filter { !$0.isGap }
        fullyTimed = lyricRows.allSatisfy(\.timed)
    }

    private static func row(_ line: LyricLineDto, at index: Int, synced: Bool, until: Int64) -> LyricRow {
        let leadText: String
        let backingText: String?
        let leadWords: [LyricWord]
        let backingWords: [LyricWord]
        if let background = line.background, !background.text.isEmpty {
            leadText = line.text
            backingText = background.text
            leadWords = line.words.map(word)
            backingWords = background.words.map(word)
        } else {
            let split = splitBackground(line.text)
            leadText = split.lead
            backingText = split.backing
            leadWords = line.words.filter { !isBackingToken($0.text) }.map(word)
            backingWords = line.words.filter { isBackingToken($0.text) }.map(word)
        }
        let timed = line.timeMs > 0 || line.sungUntilMs != nil ||
            line.words.contains(where: { $0.startMs > 0 || $0.endMs > 0 }) ||
            (line.background?.timeMs ?? 0) > 0 ||
            line.background?.words.contains(where: { $0.startMs > 0 || $0.endMs > 0 }) == true ||
            // A timed document's first line may really start at zero.
            (index == 0 && synced)
        let shown = leadWords.isEmpty ? leadText : leadWords.map(\.text).joined(separator: " ")
        let backingShown = backingWords.isEmpty ? backingText : backingWords.map(\.text).joined(separator: " ")
        return LyricRow(
            id: index,
            isGap: line.isGap,
            timed: timed,
            secondVoice: line.alignment == .end,
            rightToLeft: lyricTextIsRightToLeft(line.text),
            leadText: shown.isEmpty ? "♪" : shown,
            backingText: backingShown.flatMap { $0.isEmpty ? nil : $0 },
            leadSwept: swept(leadWords),
            backingSwept: swept(backingWords),
            timeMs: line.timeMs,
            untilMs: until
        )
    }

    private static func word(_ dto: LyricWordDto) -> LyricWord {
        LyricWord(
            text: dto.text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""),
            startMs: dto.startMs,
            endMs: dto.endMs
        )
    }

    /// The words as one `Text`, each carrying its timing for the renderer.
    private static func swept(_ words: [LyricWord]) -> Text? {
        guard !words.isEmpty else { return nil }
        var text = Text(verbatim: "")
        for (index, word) in words.enumerated() {
            let piece = Text(verbatim: word.text)
                .customAttribute(LyricWordTiming(startMs: word.startMs, endMs: word.endMs))
            text = index == 0 ? piece : Text("\(text) \(piece)")
        }
        return text
    }

    private static func isBackingToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("(") || trimmed.hasSuffix(")")
    }

    /// Display-only split matching upstream `withBackgroundVocals`.
    static func splitBackground(_ text: String) -> (lead: String, backing: String?) {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), close > open else {
            return (text, nil)
        }
        let inner = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return (text, nil) }
        let lead = (text[..<open] + text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (lead.isEmpty ? "♪" : String(lead), String(inner))
    }
}

/// Holds the prepared document between renders. Not observable: it is a memo,
/// and replacing its contents is never itself a reason to redraw.
final class LyricsDocumentCache {
    private var current: PreparedLyrics?

    func document(for lines: [LyricLineDto]) -> PreparedLyrics {
        if let current, current.identity.count == lines.count,
           zip(current.identity, lines).allSatisfy({ $0 == ObjectIdentifier($1) }) {
            return current
        }
        let prepared = PreparedLyrics(lines: lines)
        current = prepared
        return prepared
    }
}

// MARK: - Look

/// Upstream's lyric motion constants (PlayerLyrics.kt), so the two apps move alike.
enum LyricStyle {
    /// One curve for the dim, the blur, the scale and the scroll.
    static let settle = Animation.timingCurve(0.41, 0, 0.12, 0.99, duration: 0.4)
    static let falloffAlpha: [Double] = [1, 0.8, 0.7, 0.58, 0.46]
    static let falloffAlphaPhone: [Double] = [1, 0.74, 0.6, 0.48, 0.4, 0.34]
    static let falloffBlur: [CGFloat] = [0, 1, 1, 1.7, 2.4]
    static let inactiveScale: CGFloat = 0.98
    static let browsingAlpha = 0.8
    static let unsungAlpha = 0.45
    static let backingAlpha = 0.72
    static let backingScale: CGFloat = 23.0 / 34.0
    static let wipeFeather: CGFloat = 30
    static let wordRise: CGFloat = 2
    static let glowAlpha = 0.62
    static let glowRadius: CGFloat = 6
    /// A note held at least this long glows; quick syllables never do.
    static let heldNoteMs: Int64 = 900
    static let duetLane: CGFloat = 44
    static let rowInset: CGFloat = 10
}

struct LyricRowLook: Equatable {
    var alpha: Double
    var blur: CGFloat
    var scale: CGFloat
}

// MARK: - Sweep

/// A word's timing, carried on its glyph run to the renderer.
struct LyricWordTiming: TextAttribute {
    let startMs: Int64
    let endMs: Int64
}

/// Draws the line being sung: words ahead of the singer held back, the sung
/// part lit by a feathered wavefront rather than a hard cut, each word lifting
/// a couple of points as it is reached, and a soft bloom only on notes that are
/// actually held. No underline, no change of weight — the text never reflows.
///
/// Drawing only: the layout is the `Text`'s own and is not redone per frame.
struct LyricSweepRenderer: TextRenderer {
    var ms: Int64
    var glow: Bool

    var displayPadding: EdgeInsets {
        let room = LyricStyle.glowRadius * 2
        return EdgeInsets(top: room, leading: room, bottom: room, trailing: room)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let timing = run[LyricWordTiming.self] else {
                    // The spaces between words: nothing to light.
                    var dim = context
                    dim.opacity = LyricStyle.unsungAlpha
                    dim.draw(run)
                    continue
                }
                draw(run, timing: timing, in: context)
            }
        }
    }

    private func draw(_ run: Text.Layout.Run, timing: LyricWordTiming, in base: GraphicsContext) {
        let span = max(1, timing.endMs - timing.startMs)
        let progress = min(1, max(0, Double(ms - timing.startMs) / Double(span)))
        var context = base
        if progress > 0 {
            // Up in the first third of the word, and it stays up for the rest of
            // the line.
            let rise = 1 - pow(1 - min(1, progress * 3), 3)
            context.translateBy(x: 0, y: -LyricStyle.wordRise * rise)
        }
        if progress >= 1 {
            context.draw(run)
            return
        }
        var dim = context
        dim.opacity = LyricStyle.unsungAlpha
        dim.draw(run)
        guard progress > 0 else { return }

        let rect = run.typographicBounds.rect
        if glow, span >= LyricStyle.heldNoteMs {
            // Swells and blooms over the note, gone again as it ends.
            let envelope = sin(Double.pi * progress)
            var halo = context
            halo.addFilter(.blur(radius: LyricStyle.glowRadius))
            halo.opacity = LyricStyle.glowAlpha * envelope
            halo.draw(run)
        }

        let feather = LyricStyle.wipeFeather
        let travel = rect.width + feather
        let rtl = run.layoutDirection == .rightToLeft
        let edge = rtl ? rect.maxX + feather - progress * travel : rect.minX - feather + progress * travel
        let band = rect.insetBy(dx: -feather, dy: -LyricStyle.glowRadius)
        var lit = context
        lit.clipToLayer { mask in
            mask.fill(
                Path(band),
                with: .linearGradient(
                    Gradient(colors: [.white, .white.opacity(0)]),
                    startPoint: CGPoint(x: edge, y: band.midY),
                    endPoint: CGPoint(x: rtl ? edge - feather : edge + feather, y: band.midY)
                )
            )
        }
        lit.draw(run)
    }
}

// MARK: - Views

/// Reads the clock thirty times a second and reports the focus when it changes.
/// Draws nothing, so its own updates cost almost nothing.
struct LyricsFocusTicker: View {
    let document: PreparedLyrics
    let clock: LyricsClock
    let offsetMs: Int32
    let onChange: (LyricFocusState) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !clock.playing)) { timeline in
            let focus = document.timeline.focus(
                at: clock.lyricMs(at: timeline.date, offsetMs: offsetMs),
                document: ObjectIdentifier(document)
            )
            Color.clear
                .onChange(of: focus, initial: true) { _, focus in onChange(focus) }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a tap on a row does. Part of the row's equality, so a row that is not
/// redrawn never keeps an out-of-date tap.
enum LyricTapMode: Equatable {
    case reveal, pick, seek
}

struct LyricRowView: View, Equatable {
    let row: LyricRow
    let document: ObjectIdentifier
    let active: Bool
    let look: LyricRowLook
    let fontSize: CGFloat
    let duet: Bool
    let picked: Bool
    let picking: Bool
    let tapMode: LyricTapMode
    let offsetMs: Int32
    let clock: LyricsClock
    let onTap: () -> Void

    static func == (lhs: LyricRowView, rhs: LyricRowView) -> Bool {
        lhs.row.id == rhs.row.id && lhs.document == rhs.document && lhs.active == rhs.active &&
            lhs.look == rhs.look && lhs.fontSize == rhs.fontSize && lhs.duet == rhs.duet &&
            lhs.picked == rhs.picked && lhs.picking == rhs.picking && lhs.tapMode == rhs.tapMode &&
            lhs.offsetMs == rhs.offsetMs && (!lhs.active || lhs.clock.playing == rhs.clock.playing)
    }

    private var trailingSide: Bool { row.secondVoice != row.rightToLeft }

    var body: some View {
        VStack(alignment: row.secondVoice ? .trailing : .leading, spacing: 2) {
            line(row.leadText, swept: row.leadSwept, size: fontSize, glow: true)
            if let backing = row.backingText {
                line(backing, swept: row.backingSwept, size: fontSize * LyricStyle.backingScale, glow: false)
                    .opacity(LyricStyle.backingAlpha)
            }
        }
        .frame(maxWidth: .infinity, alignment: row.secondVoice ? .trailing : .leading)
        .padding(.leading, duet && row.secondVoice ? LyricStyle.duetLane : 0)
        .padding(.trailing, duet && !row.secondVoice ? LyricStyle.duetLane : 0)
        .padding(.vertical, LyricStyle.rowInset * 0.8)
        .padding(.horizontal, LyricStyle.rowInset)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(picked ? 0.16 : (picking ? 0.05 : 0)))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onTap)
        .environment(\.layoutDirection, row.rightToLeft ? .rightToLeft : .leftToRight)
        .scaleEffect(look.scale, anchor: trailingSide ? .trailing : .leading)
        .opacity(look.alpha)
        .blur(radius: look.blur)
        .animation(LyricStyle.settle, value: look)
    }

    @ViewBuilder
    private func line(_ plain: String, swept: Text?, size: CGFloat, glow: Bool) -> some View {
        Group {
            if active, let swept {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !clock.playing)) { timeline in
                    swept.textRenderer(LyricSweepRenderer(
                        ms: clock.lyricMs(at: timeline.date, offsetMs: offsetMs),
                        glow: glow
                    ))
                }
            } else {
                Text(verbatim: plain)
            }
        }
        .scaledFont(size: size, weight: .heavy, design: .default)
        .foregroundStyle(.white)
        .multilineTextAlignment(row.secondVoice ? .trailing : .leading)
        .lineSpacing(size * 0.06)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// An instrumental break, counted out by three dots that light in turn. The row
/// only stands open while the break is playing, so the list carries no hole
/// through the verses either side of it.
struct LyricGapRow: View {
    let row: LyricRow
    let open: Bool
    let look: LyricRowLook
    let offsetMs: Int32
    let clock: LyricsClock
    let onTap: () -> Void

    private let dot: CGFloat = 13
    private let spacing: CGFloat = 5

    var body: some View {
        ZStack(alignment: row.secondVoice ? .trailing : .leading) {
            if open {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !clock.playing)) { timeline in
                    dots(through: through(at: timeline.date))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.76, anchor: .leading)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: open ? dot + LyricStyle.rowInset * 2 + 16 : 0)
        .padding(.horizontal, LyricStyle.rowInset)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .opacity(look.alpha)
        .blur(radius: look.blur)
        .animation(LyricStyle.settle, value: open)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Instrumental break")
        .accessibilityHint("Double-tap to seek to this break")
        .accessibilityAction(named: Text("Seek to instrumental break")) { onTap() }
    }

    private func through(at date: Date) -> Double {
        let now = clock.lyricMs(at: date, offsetMs: offsetMs)
        let span = max(1, row.untilMs - row.timeMs)
        return min(1, max(0, Double(now - row.timeMs) / Double(span)))
    }

    private func dots(through: Double) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                let lit = min(1, max(0, through * 3 - Double(index)))
                Circle()
                    .fill(.white.opacity(0.25 + 0.75 * lit))
                    .frame(width: dot, height: dot)
            }
        }
    }
}
