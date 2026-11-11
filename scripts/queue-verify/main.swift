import Foundation

// Only the snapshot's enum dependency is needed by this standalone Mac check.
enum PlaybackController {
    enum RepeatMode: Int { case off, all, one }
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
func track(_ id: String, order: Int? = nil, autoplay: Bool = false) -> QueueEntry {
    var entry = QueueEntry.youtube(videoId: id, title: id, artist: "Artist", fromAutoplay: autoplay)
    entry.contextOrder = order
    return entry
}
check(QueueSearchPolicy.matches(title: "Northern Lights", artist: "Mira Vale", query: "NORTHERN"), "Queue search matches titles without case sensitivity")
check(QueueSearchPolicy.matches(title: "Northern Lights", artist: "Mira Vale", query: "mira"), "Queue search matches artist names")
check(!QueueSearchPolicy.matches(title: "Northern Lights", artist: "Mira Vale", query: "another song"), "Queue search excludes non-matching rows")
check(QueueSearchPolicy.matches(title: "Northern Lights", artist: "Mira Vale", query: "  "), "Whitespace-only queue search preserves every row")
check(PlaybackHandoffPolicy.acceptsRepeatOne(title: "A", artist: "Artist", sourceIsArmed: true, currentTitle: "A", currentArtist: "Artist"), "Repeat-one accepts an armed self-mix for the selected track")
check(!PlaybackHandoffPolicy.acceptsRepeatOne(title: "Old", artist: "Artist", sourceIsArmed: true, currentTitle: "New", currentArtist: "Artist"), "Repeat-one rejects a different-track handoff after a manual selection")
check(!PlaybackHandoffPolicy.acceptsRepeatOne(title: "A", artist: "Artist", sourceIsArmed: false, currentTitle: "A", currentArtist: "Artist"), "Repeat-one rejects a handoff whose source was not armed")
let queue = [track("played", order: 0), track("selected", order: 1),
             track("manual"), track("low", order: 2), track("high", order: 3),
             track("suggestion", autoplay: true)]
let scores = [0.0, 0, 100, 0.1, 0.9, 100]
let ordered = PlaybackQueuePolicy.orderList(queue, after: 1, automix: true, shuffle: true, scores: scores)
check(ordered.map(\.id) == ["played", "selected", "manual", "high", "low", "suggestion"], "Automix wins and only sequences unplayed list slots")
let rollingQueue = [
    track("now", order: 0), track("committed-a", order: 1), track("committed-b", order: 2),
    track("manual"), track("window-a", order: 3), track("window-b", order: 4),
    track("window-c", order: 5), track("recommendation", autoplay: true)
]
check(PlaybackQueuePolicy.rollingListWindow(rollingQueue, after: 0) == [4, 5, 6], "Rolling analysis starts after the two committed queue rows and skips manual and autoplay rows")
let longRollingQueue = (0..<16).map { track("rolling-\(String($0))", order: $0) }
check(PlaybackQueuePolicy.rollingListWindow(longRollingQueue, after: 0) == Array(3..<13), "Rolling analysis is capped at ten list rows")
let analyzedOnly = PlaybackQueuePolicy.replacing(
    rollingQueue, at: [4, 6], with: [rollingQueue[6], rollingQueue[4]]
)
check(analyzedOnly[4...6].map(\.id) == ["window-c", "window-b", "window-a"], "Only analyzed rows move, and only among their original slots")
check(PlaybackQueuePolicy.orderList(queue, after: 1, automix: true, shuffle: false, scores: scores) == ordered, "Shuffle preference cannot override Automix")
check(PlaybackQueuePolicy.orderList(ordered, after: 1, automix: false, shuffle: false, scores: scores) == queue, "Ordered mode restores upcoming source order without rewinding history")
check(PlaybackQueuePolicy.orderList(queue, after: 1, automix: true, shuffle: false, scores: Array(repeating: 0, count: queue.count)) == queue, "Equal affinity preserves source order")
var sawShuffle = false
for _ in 0..<30 {
    let shuffled = PlaybackQueuePolicy.orderList(queue, after: 1, automix: false, shuffle: true, scores: scores)
    check(Array(shuffled.prefix(3)) == Array(queue.prefix(3)) && shuffled.last == queue.last, "Shuffle preserves played, selected, manual and autoplay rows")
    check(Set(shuffled[3...4].map(\.id)) == ["low", "high"], "Shuffle keeps every list candidate")
    sawShuffle = sawShuffle || shuffled != queue
}
check(sawShuffle, "Shuffle reorders eligible tracks when Automix is off")
let duplicateManual = [track("seed", order: 0), track("same"), track("same", order: 1), track("best", order: 2)]
let duplicateOrdered = PlaybackQueuePolicy.orderList(duplicateManual, after: 0, automix: true, shuffle: false, scores: [0, 0, 0, 1])
check(duplicateOrdered[1].contextOrder == nil && duplicateOrdered[2].id == "best", "A manual copy of a list song stays protected")
let shuffledSeed = PlaybackQueuePolicy.startingWith(queue, seed: 4)
check(shuffledSeed.first?.id == "high" && Set(shuffledSeed.map(\.id)) == Set(queue.map(\.id)), "A random Shuffle seed keeps all earlier candidates")
let mixed = [track("played-auto", autoplay: true), track("seed"), track("manual"), track("old-auto", autoplay: true)]
check(PlaybackQueuePolicy.appendingFill(mixed, extras: [track("new-1", autoplay: true), track("manual", autoplay: true)]).map(\.id) == mixed.map(\.id) + ["new-1"], "A fill appends only, never removes, reorders or duplicates")
check(PlaybackQueuePolicy.fillRoom(mixed, after: 1) == PlaybackQueuePolicy.autoplayTarget - PlaybackQueuePolicy.autoplayIndices(mixed, after: 1).count, "Fill room counts only upcoming recommendations")
check(!PlaybackQueuePolicy.shouldRefillAutoplay(upcomingCount: 3), "Natural handoff leaves a three-item queue alone")
check(PlaybackQueuePolicy.shouldRefillAutoplay(upcomingCount: 2), "Natural handoff refills below the three-item watermark")
func context(_ source: String = "yt:seed", index: Int = 0, generation: UInt64 = 1, edit: UInt64 = 0, session: Int64 = 1) -> AutoplayRefreshState.Context {
    .init(source: source, index: index, playbackGeneration: generation, queueEditRevision: edit, sessionGeneration: session)
}
var refresh = AutoplayRefreshState()
let initial = context()
let request = refresh.begin(initial)!
check(refresh.begin(initial) == nil, "Arming the engine repeatedly coalesces recommendation requests")
check(refresh.accepts(request, current: initial), "Current request can install recommendations")
for changed in [context("yt:next", index: 1), context(index: 1), context(generation: 2), context(edit: 1), context(session: 2)] {
    check(!refresh.accepts(request, current: changed), "Selection, skip/back, queue or account changes reject stale replies")
}
let rated = refresh.begin(initial, force: true)!
check(!refresh.accepts(request, current: initial) && refresh.accepts(rated, current: initial), "A successful rating supersedes the old request even with the same seed")
check(!refresh.shouldRetry(request), "A superseded reply is never retried")
check((1...AutoplayRefreshState.maxRetries).allSatisfy { _ in refresh.shouldRetry(rated) }, "A reply that landed mid-load is retried while it is the newest request")
check(!refresh.shouldRetry(rated), "Retries stop at the budget")
refresh.noteFilled()
check(refresh.shouldRetry(rated), "A landed fill restores the retry budget")
refresh.invalidate()
check(!refresh.accepts(rated, current: initial), "Disabling autoplay or entering repeat-all invalidates pending recommendations")
check(!refresh.shouldRetry(rated), "An invalidated request is not retried")
let now = 1_800_000_000_000.0
let fresh = PlaybackQueuePolicy.score(transitionFit: nil, affinity: 0, playedAt: nil, now: now)
check(fresh > PlaybackQueuePolicy.score(transitionFit: nil, affinity: 0, playedAt: now - 1000, now: now), "Freshness works without audio analysis")
check(PlaybackQueuePolicy.score(transitionFit: nil, affinity: 1, playedAt: nil, now: now) > fresh, "Listening affinity works without audio analysis")
check(PlaybackQueuePolicy.score(transitionFit: 1, affinity: 0, playedAt: nil, now: now) > fresh, "Available transition analysis contributes to ordering")
for (origin, hasQueue, stopped, audible, expected) in [
    ("list", true, false, true, PlaybackQueuePolicy.HeroState.playing),
    ("list", true, false, false, .paused), ("other", true, false, true, .inactive),
    ("list", true, true, false, .inactive), ("list", false, false, true, .inactive)
] {
    check(PlaybackQueuePolicy.heroState(origin: origin, listID: "list", hasQueue: hasQueue, stopped: stopped, playingOrBuffering: audible) == expected, "Hero reflects playing/buffering, pause, stopped and different-list state")
}
let initialContextWindow = PlaybackQueueWindow.initialRange(count: 100, selectedIndex: 40)
check(initialContextWindow == 39..<66, "Detail playback starts with one previous, current, and 25 upcoming entries")
check(PlaybackQueueWindow.initialRange(count: 100, selectedIndex: 0) == 0..<26, "First detail track still materializes 25 upcoming entries")
check(PlaybackQueueWindow.appendCount(upcomingCount: 13, canonicalRemaining: 100) == 0, "Context window waits above the 12-entry low water")
check(PlaybackQueueWindow.appendCount(upcomingCount: 12, canonicalRemaining: 100) == 13, "Context window tops back up to 25 at low water")
check(PlaybackQueueWindow.appendCount(upcomingCount: 12, canonicalRemaining: 3) == 3, "Context window drains the canonical page before continuation")
check(PlaybackQueueWindow.shouldFetchContinuation(upcomingCount: 12, canonicalRemaining: 0, hasContinuation: true), "Playback requests continuation only after canonical songs run out at low water")
check(!PlaybackQueueWindow.shouldFetchContinuation(upcomingCount: 13, canonicalRemaining: 0, hasContinuation: true), "Playback does not fetch continuation above low water")
let defaults = UserDefaults.standard
let previousSnapshot = defaults.object(forKey: "bitchord_last_played")
defer {
    if let previousSnapshot { defaults.set(previousSnapshot, forKey: "bitchord_last_played") }
    else { defaults.removeObject(forKey: "bitchord_last_played") }
}
var contextVideo = track("context-video", order: 1)
contextVideo.isVideo = true
LastPlayed.save(
    tracks: ordered, index: 1, position: 42, repeatMode: .one, shuffleEnabled: true,
    volume: 0.8, contextID: "list", contextTitle: "Album",
    contextEntries: [track("context-a", order: 0), contextVideo],
    orderedContextEntries: [contextVideo, track("context-a", order: 0)],
    contextContinuation: "next-page", contextCursor: 1, contextBaseIndex: 2
)
let restored = LastPlayed.load()!
check(restored.contextID == "list" && restored.contextTitle == "Album", "Origin is saved atomically with the queue")
check(restored.tracks == ordered && restored.index == 1 && restored.position == 42 && restored.shuffleEnabled, "Order, provenance and playback state survive restore")
check(restored.contextEntries.map(\.id) == ["context-a", "context-video"] && restored.orderedContextEntries.map(\.id) == ["context-video", "context-a"], "Canonical and playback-ordered context survive restore")
check(restored.contextEntries.last?.isVideo == true, "Video metadata survives context restore")
check(restored.contextContinuation == "next-page" && restored.contextCursor == 1 && restored.contextBaseIndex == 2, "Continuation and rolling window cursors survive restore")
var old = try JSONSerialization.jsonObject(with: defaults.data(forKey: "bitchord_last_played")!) as! [String: Any]
old.removeValue(forKey: "contextID")
old.removeValue(forKey: "contextTitle")
old.removeValue(forKey: "contextEntries")
old.removeValue(forKey: "orderedContextEntries")
old.removeValue(forKey: "contextContinuation")
old.removeValue(forKey: "contextCursor")
old.removeValue(forKey: "contextBaseIndex")
old["tracks"] = (old["tracks"] as! [[String: Any]]).map { track in
    var track = track; track.removeValue(forKey: "contextOrder"); return track
}
defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "bitchord_last_played")
check(LastPlayed.load()?.contextID == nil && LastPlayed.load()?.tracks.count == queue.count, "Older snapshots remain readable")
print("PASS \(checks) queue, recommendation, sequencing, hero and restore checks")
