import SwiftUI

/// One line that crawls in place, only when it is too long for its width.
///
/// Upstream's `MarqueeText`: idle text never moves. A line that would need an
/// ellipsis is drawn twice with a gap between the copies and the pair slides
/// left by exactly one copy plus the gap, so the copy chasing the first lands
/// where the first started and the reset cannot be seen. A pass waits
/// `startDelay`, crawls once at 26 points a second, then rests five seconds.
/// The line fades out at its end while it overflows, and at its start while it
/// is away from its resting place.
///
/// Driven by a timeline rather than an animation so the start fade can follow
/// the offset, and the content is the same view in both copies, so a link in
/// it answers a click on the name that is under the pointer.
struct Marquee<Content: View>: View {
    var enabled = true
    var startDelay: Double = 0
    var onOverflowChange: (Bool) -> Void = { _ in }
    @ViewBuilder var content: Content

    @State private var contentWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var anchor = Date()

    private static var gap: CGFloat { 48 }
    private static var speed: CGFloat { 26 }
    private static var rest: Double { 5 }
    private static var fade: CGFloat { 20 }

    private var overflowing: Bool { boxWidth > 0 && contentWidth > boxWidth + 0.5 }
    private var crawls: Bool { enabled && overflowing }
    private var travel: CGFloat { contentWidth + Self.gap }
    private var passDuration: Double { max(0.4, Double(travel / Self.speed)) }

    var body: some View {
        content
            .fixedSize()
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            // minWidth 0: without it the frame never goes below its child, so
            // the full-length line widened the whole player column.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: .leading) {
                TimelineView(MarqueeSchedule(
                    anchor: anchor, startDelay: startDelay, pass: passDuration,
                    rest: Self.rest, paused: !crawls
                )) { context in
                    let moved = crawls ? offset(at: context.date) : 0
                    HStack(spacing: Self.gap) {
                        content.fixedSize()
                        if crawls { content.fixedSize() }
                    }
                    .offset(x: -moved)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .mask(fadeMask(moved: moved))
                }
            }
            .clipped()
            .onChange(of: crawls, initial: true) { _, now in
                anchor = Date()
                onOverflowChange(now)
            }
            .onChange(of: contentWidth) { anchor = Date() }
    }

    /// How far left the pair has slid at `date`: nothing during the start
    /// delay and the rest, a linear crawl in between.
    private func offset(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(anchor) - startDelay
        guard elapsed > 0 else { return 0 }
        let cycle = passDuration + Self.rest
        let within = elapsed.truncatingRemainder(dividingBy: cycle)
        guard within < passDuration else { return 0 }
        return travel * CGFloat(within / passDuration)
    }

    @ViewBuilder
    private func fadeMask(moved: CGFloat) -> some View {
        if overflowing {
            let start = min(1, max(0, min(moved, travel - moved) / Self.fade))
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(1 - start), .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fade)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fade)
            }
        } else {
            Rectangle()
        }
    }
}

/// Frames for a marquee: sixty a second while the line moves, none while it
/// waits out its start delay or rests. `.animation` ticked at the display's
/// full rate for as long as a title overflowed, rests included, which redrew
/// the player a hundred and twenty times a second for a line standing still.
private struct MarqueeSchedule: TimelineSchedule {
    var anchor: Date
    var startDelay: Double
    var pass: Double
    var rest: Double
    var paused: Bool
    private static let frame = 1.0 / 60.0

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if paused {
            var sent = false
            return AnyIterator {
                defer { sent = true }
                return sent ? nil : startDate
            }
        }
        let origin = anchor.addingTimeInterval(startDelay)
        let cycle = pass + rest
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            let elapsed = current.timeIntervalSince(origin)
            if elapsed < 0 {
                next = origin
            } else {
                let within = elapsed.truncatingRemainder(dividingBy: cycle)
                if within < pass {
                    // The last frame of a pass lands on its end, so the line
                    // is drawn at rest rather than one step short of it.
                    next = current.addingTimeInterval(min(Self.frame, pass - within + 0.0005))
                } else {
                    next = current.addingTimeInterval(cycle - within)
                }
            }
            return current
        }
    }
}

/// The explicit mark before a title, in the artist line's colour.
struct ExplicitMark: View {
    var color: Color

    var body: some View {
        Image(systemName: "e.square.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel("Explicit")
    }
}
