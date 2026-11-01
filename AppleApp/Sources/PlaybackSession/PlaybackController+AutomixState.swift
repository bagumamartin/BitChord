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

// AutoMix UI state: the adopted plan, the smart window, and artwork.
extension PlaybackController {
    func adoptAutomixPlan(_ plan: TransitionPlanRec) {
        pendingAutomixPlan = plan
        let rateNote = abs(plan.playbackRate - 1) > 0.001
            ? String(format: " @%.3fx", plan.playbackRate)
            : ""
        analysisTier = Self.tierName(plan) + rateNote
        let visibleReason = Self.displayAutomixReason(plan.reason)
        transitionReason = visibleReason.isEmpty ? nil : visibleReason
        let sources = lastAutomixAnalysisSources()
        if sources.count >= 2 {
            analysisSources = "\(sources[0]) → \(sources[1])"
        } else if let only = sources.first, !only.isEmpty {
            analysisSources = only
        } else {
            analysisSources = nil
        }
        automixCueSeconds = plan.cueSeconds
        publishSmartWindow()
    }

    nonisolated static func displayAutomixReason(_ reason: String) -> String {
        guard reason.hasPrefix("safety:") else { return reason }
        return String(reason.dropFirst("safety:".count)).trimmingCharacters(in: .whitespaces)
    }

    func publishSmartWindow() {
        guard automixEnabled, let plan = pendingAutomixPlan, duration > 0 else {
            smartTransitionWindow = nil
            return
        }
        let fade = plan.fadeSeconds > 0
            ? plan.fadeSeconds
            : Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        guard fade > 0, Self.isRealMix(plan) else {
            smartTransitionWindow = nil
            return
        }
        // Match the mixer's authoritative analysed anchor; it can finish
        // before the file ends. Zero denotes the initial duration-based plan.
        let endSeconds = plan.transitionEndSeconds.isFinite && plan.transitionEndSeconds > 0
            ? min(duration, plan.transitionEndSeconds) : duration
        let start = max(0, (endSeconds - fade) / duration)
        let end = min(1, endSeconds / duration)
        smartTransitionWindow = end > start ? TransitionWindow(start: start, end: end) : nil
    }

    func beginSmartMixIfNeeded() {
        smartTransitionWindow = nil
        guard let plan = pendingAutomixPlan, Self.isRealMix(plan) else {
            smartMixInProgress = false
            mixFadeUntil = nil
            pendingAutomixPlan = nil
            analysisTier = nil
            return
        }
        smartMixInProgress = true
        let fade = plan.fadeSeconds > 0 ? plan.fadeSeconds : 6
        mixFadeUntil = Date().addingTimeInterval(fade)
        pendingAutomixPlan = nil
    }

    /// Whether this plan is a real transition rather than the no-analysis
    /// fallback.
    ///
    /// Was `cueSeconds > 0.05 || |playbackRate − 1| > 0.01`, which was a proxy
    /// for "the planner found something". It stopped being one: a mix-in at the
    /// top of the record is now the *correct* answer, so a well-planned
    /// transition can legitimately arrive with a cue of zero and no tempo
    /// stretch — and this read that as "no mix" and dropped the transition
    /// marker and the label, for a transition that was about to be rendered.
    ///
    /// The style used to be the only signal, which left a plain crossfade —
    /// the one a partial analysis actually plays — invisible to the upgrade
    /// guard. Any ramp of a second or more is a transition the quality swap
    /// must not cut across.
    private static func isRealMix(_ plan: TransitionPlanRec) -> Bool {
        switch plan.style {
        case .djBlend, .djFilter, .echoOut, .loopRoll, .reverbWash, .dropCut, .texture, .brake: return true
        case .equalPower, .gapless: return plan.fadeSeconds >= 1
        }
    }

    nonisolated static func tierName(_ plan: TransitionPlanRec) -> String {
        switch plan.style {
        case .djBlend: return "beatmatched blend"
        case .djFilter: return "filter ride"
        case .gapless: return "gapless"
        case .equalPower: return "crossfade"
        case .echoOut: return "echo out"
        case .loopRoll: return "loop roll"
        case .reverbWash: return "reverb wash"
        case .dropCut: return "cut on the one"
        case .texture: return "texture sweep"
        case .brake: return "tape stop"
        }
    }

    func refreshArtwork(_ entry: QueueEntry) {
        let local = loadedSourcePath.flatMap { $0.hasPrefix("/") ? LocalArtwork.reference(path: $0) : nil }
        guard let raw = entry.thumbnailUrl ?? local, !raw.isEmpty else { return }
        let sized = SharedArtwork.sized(raw, 544) ?? raw
        let headers = WebDavBridge.shared.playbackHeaders(fileUrl: sized)
        Task {
            guard let data = await ArtworkRequests.shared.data(url: sized, headers: headers), !data.isEmpty else { return }
            var covered = entry; covered.artworkData = data
            if !entry.isLocal { await StreamFileCache.shared.remember(covered) }
            if let asset = DownloadStore.shared.asset(for: entry), asset.managed {
                await OfflineArtwork.preserve(covered, audioPath: asset.path)
            }
            await MainActor.run { [weak self] in
                guard let self, self.current?.id == entry.id else { return }
                self.current?.artworkData = data
                if !LocalArtwork.isReference(raw), let i = self.queue.firstIndex(where: { $0.id == entry.id }) {
                    self.queue[i].artworkData = data
                }
                self.nowPlaying.update(
                    id: entry.id, title: entry.title, artist: entry.artist,
                    duration: self.duration, artworkData: data,
                    thumbnailUrl: entry.thumbnailUrl, isPlaying: self.isPlaying, position: self.position
                )
                self.widgetPublisher.publish(entry: self.current, isPlaying: self.isPlaying, canNext: self.canPlayNext, canPrevious: self.canPlayPrevious)
            }
        }
    }
}
