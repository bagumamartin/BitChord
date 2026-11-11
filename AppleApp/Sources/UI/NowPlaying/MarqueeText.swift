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
/// A timeline marks only where each pass starts and ends; the crawl between is
/// one linear animation. Recomputing the offset sixty times a second redrew the
/// text (and its fade mask) on the CPU every frame: a long title held the main
/// thread at about a third of a core for as long as it scrolled. Animated, the
/// text is drawn once and only its position moves. The start fade is on for
/// the pass and off at rest. The content is the same view in both copies, so a
/// link in it answers a click on the name that is under the pointer.
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
                    let left = crawls ? remainingPass(at: context.date) : nil
                    HStack(spacing: Self.gap) {
                        content.fixedSize()
                        if crawls { content.fixedSize() }
                    }
                    .offset(x: left == nil ? 0 : -travel)
                    // Out to the end over what is left of the pass; back to the
                    // start at once, where the second copy stands in for the
                    // first so the jump cannot be seen.
                    .animation(left.map { .linear(duration: $0) }, value: left == nil)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .mask(fadeMask(away: left != nil))
                }
            }
            .clipped()
            .onChange(of: crawls, initial: true) { _, now in
                anchor = Date()
                onOverflowChange(now)
            }
            .onChange(of: contentWidth) { anchor = Date() }
    }

    /// Seconds left in the pass under way at `date`, or nil during the start
    /// delay and the rest.
    private func remainingPass(at date: Date) -> Double? {
        let elapsed = date.timeIntervalSince(anchor) - startDelay
        guard elapsed >= 0 else { return nil }
        let cycle = passDuration + Self.rest
        let within = elapsed.truncatingRemainder(dividingBy: cycle)
        let left = passDuration - within
        // A boundary entry can land a hair either side of the end.
        return left > 0.05 ? left : nil
    }

    @ViewBuilder
    private func fadeMask(away: Bool) -> some View {
        if overflowing {
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(away ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fade)
                    .animation(.easeInOut(duration: 0.3), value: away)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fade)
            }
        } else {
            Rectangle()
        }
    }
}

/// A marquee's timeline: one entry where each pass starts and one where it
/// ends. The crawl between them is an animation, not frames of this schedule.
private struct MarqueeSchedule: TimelineSchedule {
    var anchor: Date
    var startDelay: Double
    var pass: Double
    var rest: Double
    var paused: Bool

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
                // Just past the boundary, so the entry reads as the new state.
                next = current.addingTimeInterval((within < pass ? pass - within : cycle - within) + 0.001)
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
