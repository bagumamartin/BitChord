import Foundation
import BitChordShared
import os
#if os(iOS)
import UIKit
#if DEBUG
import AVFoundation
#endif
#else
import AppKit
#endif

// Likes, ratings and the live position.
extension PlaybackController {
    /// The heart in the player, for whatever is playing.
    func toggleLike() {
        guard let vid = current?.videoId else { return }
        toggleLike(videoId: vid)
    }

    /// The heart for a named track — the row swipe and the long-press menu use
    /// this one, so there is a single like path rather than three that disagree.
    ///
    /// `LibraryActions.toggleLike` owns the optimistic write and its rollback;
    /// this adds the reporting, which every call site used to skip by writing
    /// the result to `_`. A refused rating was therefore invisible *and*
    /// permanent — the heart kept a status the account did not have. `lastError`
    /// is the app's single failure surface (RootView turns it into a toast), so
    /// a like that YouTube refuses is said out loud in the same place a
    /// playback failure is.
    func toggleLike(videoId: String) {
        Task { @MainActor [weak self] in
            if let failure = await self?.toggleLikeAndWait(videoId: videoId) {
                self?.lastError = failure
            }
        }
    }

    func toggleLikeAndWait(videoId: String) async -> String? {
        let generation = PageSession.generation()
        let failure = await LibraryActions.toggleLike(videoId: videoId)
        refreshAfterRating(failure: failure, sessionGeneration: generation)
        return failure
    }

    func rateTrack(videoId: String, status: String) async -> String? {
        let generation = PageSession.generation()
        let previous = LibraryActions.cachedLike(videoId)
        let failure = await LibraryActions.rate(videoId: videoId, status: status)
        if generation == PageSession.generation() {
            if failure != nil { LikeStore.shared.set(videoId, previous) }
            // The one rating that edits what is already queued: a disliked
            // recommendation leaves the tail. Nothing else moves.
            if failure == nil, status == "DISLIKE" {
                let before = queue.count
                queue = queue.enumerated().filter {
                    $0.offset <= playingIndex || !$0.element.fromAutoplay || youtubeVideoID(for: $0.element) != videoId
                }.map(\.element)
                if queue.count != before { persistSession(); syncEngineQueueNext() }
            }
            refreshAfterRating(failure: failure, sessionGeneration: generation)
        }
        return failure
    }

    func refreshAfterRating(failure: String?, sessionGeneration: Int64) {
        guard failure == nil, sessionGeneration == PageSession.generation() else { return }
        maybeAutoplay(force: true)
    }

    var isLiked: Bool {
        _ = LikeStore.shared.epoch
        guard let vid = current?.videoId else { return false }
        return LibraryActions.cachedLike(vid) == "LIKE"
    }

    /// The transport position, advanced between engine polls.
    ///
    /// `position` is the engine's answer, four times a second. Judging a word
    /// highlight against it means the highlight can only change on those four
    /// ticks — up to 250 ms late, in 250 ms steps, and frozen for as long as the
    /// engine is not reporting. Upstream keeps a reconciler and a per-frame
    /// advance for exactly this ([LyricClock]), added on the grounds that a
    /// twice-a-second clock is "far too coarse for a highlight".
    ///
    /// So the lyric pane reads this instead: the last reported position plus the
    /// wall clock since it arrived, which the pane drives at frame rate through
    /// a `TimelineView(.animation)`.
    ///
    /// Only while `state == .playing`, deliberately. Paused, buffering or
    /// seeking, the answer is exactly `position` — interpolation must never
    /// invent motion the engine is not making. A stalled tick is answered by a
    /// fresh engine reading rather than a long extrapolation.
    ///
    /// The listener's playback-rate setting is included; omitting it made every
    /// lyric drift steadily whenever playback was slower or faster than 1×. A
    /// beatmatched transition can still stretch the incoming by up to 5 %, which
    /// over one 250 ms poll is at most 12 ms before the next engine sample.
    func livePosition(at now: Date) -> Double {
        guard state == .playing else { return position }
        let elapsed = now.timeIntervalSince(positionSampledAt)
        guard elapsed > 0 else { return position }
        // A late tick (main thread busy during a transition burst) used to
        // freeze this at the last sample, which the video sync read as the
        // picture running ~1 s ahead and seeked it backwards. Past one poll
        // interval, ask the engine instead of extrapolating or freezing.
        guard elapsed < 0.4 else { return playbackPosition }
        return position + elapsed * playbackRate
    }

    func youtubeVideoID(for entry: QueueEntry) -> String? {
        if entry.source.hasPrefix("yt:") { return entry.videoId }
        return entry.isLocal ? DownloadStore.shared.selectedYouTubeVideoId(for: entry.source) : nil
    }

    var recommendationContext: AutoplayRefreshState.Context? {
        guard autoplayEnabled, repeatMode != .all, let current,
              let id = youtubeVideoID(for: current), state != .stopped else { return nil }
        return .init(
            source: "yt:\(id)", index: playingIndex, playbackGeneration: playGeneration,
            queueEditRevision: queueEditRevision, sessionGeneration: PageSession.generation()
        )
    }
}
