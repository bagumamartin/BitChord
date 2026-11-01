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

extension QueueEntry {
    static func from(_ song: Song) -> QueueEntry {
        QueueEntry(
            id: song.videoId,
            title: song.title,
            artist: song.artist,
            source: song.localPath ?? "",
            thumbnailUrl: song.thumbnailUrl,
            durationText: song.durationText,
            albumName: song.albumName,
            artworkData: nil,
            isLocal: song.localPath != nil,
            // Carried through so the cross-source matcher can tell a clean edition
            // from an unstated one, and a video from catalogue audio.
            isExplicit: song.isExplicit?.boolValue,
            isVideo: song.isVideo
        )
    }

    static func from(_ track: LocalTrack) -> QueueEntry {
        QueueEntry(
            id: track.path,
            title: track.title.isEmpty ? URL(fileURLWithPath: track.path).deletingPathExtension().lastPathComponent : track.title,
            artist: track.artist,
            source: track.path,
            thumbnailUrl: track.artworkURL,
            durationText: track.durationSeconds > 0 ? formatDuration(track.durationSeconds) : nil,
            albumName: track.album.isEmpty ? nil : track.album,
            artworkData: track.artwork,
            isLocal: true
        )
    }

    func asSongJSON(videoIDOverride: String? = nil) -> SongJSON {
        SongJSON(
            videoId: videoIDOverride ?? videoId ?? id,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            durationText: durationText,
            albumName: albumName,
            artistId: artistId,
            albumId: albumId,
            isVideo: false,
            fromAutoplay: fromAutoplay
        )
    }
}

struct SongJSON: Codable {
    let videoId: String
    let title: String
    let artist: String
    let thumbnailUrl: String?
    let durationText: String?
    let albumName: String?
    let artistId: String?
    let albumId: String?
    let isVideo: Bool
    let fromAutoplay: Bool
}

/// Where on the playing track the next Automix transition sits, as fractions
/// of duration (upstream `AppSettings.smartTransitionWindow`).
struct TransitionWindow: Equatable, Sendable {
    var start: Double
    var end: Double
}

enum PlaybackLatencySignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.bitchord.app",
        category: "PlaybackLatency"
    )

    static func record(_ name: StaticString, entryID: String, elapsed: TimeInterval) {
        os_signpost(.event, log: log, name: name,
                    "%{public}@ elapsed_ms=%{public}.1f", entryID as NSString, elapsed * 1_000)
    }
}

/// The app-level playback controller: owns the Rust engine, the queue, and
/// the session-layer integration (now playing, widget state).
///
/// Engine semantics (spec §3): transitions are executed *inside* the engine —
/// queueNext arms the incoming track ~4 s before the current one ends and the
/// crossfade runs there; `onHandoff` fires as the incoming track becomes
/// audible, which is where the queue index and metadata flip (upstream's
/// `onHandoff` timing). A natural track-end reaching Swift means the queue
/// truly ran out.
@MainActor
@Observable
final class PlaybackController {
    typealias PlaybackLatencyRecorder = @Sendable (TimeInterval, String, String) async -> Void

    struct PlaybackLatencySample {
        let entryID: String
        let startedAt: TimeInterval
        let initialPosition: Double
        var resolvedAt: TimeInterval?
        var firstBufferAt: TimeInterval?
        var cacheState = "cold"
        var client = "unknown"
    }

    let engine = PlayerEngine()

    var state: PlaybackState = .stopped
    var current: QueueEntry?
    /// Shelf or collection that started this queue, for the player caption.
    var playbackContext: String?
    /// Stable identity for the collection behind the queue, used by its hero control.
    var playbackContextID: String?
    /// Canonical songs already fetched for a detail-page context. The audible
    /// queue is only a rolling window over this list.
    var playbackContextEntries: [QueueEntry] = []
    var playbackContextContinuation: String?
    var playbackContextRevision: UInt64 = 0
    @ObservationIgnored var contextWindowEntries: [QueueEntry] = []
    @ObservationIgnored var contextWindowCursor = 0
    @ObservationIgnored var contextWindowBaseIndex = 0
    @ObservationIgnored var contextWindowInstalling = false
    @ObservationIgnored var contextWindowGeneration: UInt64 = 0
    @ObservationIgnored var contextContinuationTask: Task<Void, Never>?
    var queue: [QueueEntry] = [] {
        didSet { refreshUpcomingURLPrefetch() }
    }
    var playingIndex: Int = 0 {
        didSet {
            refreshUpcomingURLPrefetch()
            maintainContextWindow()
        }
    }
    var position: Double = 0
    var duration: Double = 0
    var lastError: String?
    var recoveringEntryID: String?
    var recoveryNeedsFreshResolution = false
    var sourceDecisionNotes: [String: String] = [:]
    @ObservationIgnored var streamRecovery = PlaybackRecoveryPolicy()
    @ObservationIgnored var pendingPlaybackLatency: PlaybackLatencySample?
    @ObservationIgnored var nextPreparationTask: Task<Void, Never>?
    @ObservationIgnored var urlPrefetchTask: Task<Void, Never>?
    @ObservationIgnored var urlPrefetchFingerprint: String?
    /// A′3's session pacing: at most one transition in four may use an effect
    /// technique, so a set sounds mixed rather than gimmicky. The planner still
    /// *would* choose a technique for the pair; it blends instead and says
    /// "pacing" in its reason. The pair-keyed value lives in `TransitionPacing`
    /// and is checked on its own.
    ///
    /// Lock-protected rather than main-actor state on purpose: the planning
    /// runs off the main actor, inside the queue-submission gate, and both the
    /// read and the record happen there.
    final class TransitionPacingStore: @unchecked Sendable {
        private let lock = NSLock()
        private var pacing = TransitionPacing<TransitionStyleRec>()

        func allowsEffect(for pair: TransitionPair) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return pacing.allowsEffect(for: pair, isEffect: Self.isEffect)
        }

        /// A plan that was actually queued. A plan attempt the download
        /// invalidated must not spend the budget.
        func note(_ style: TransitionStyleRec, for pair: TransitionPair) {
            lock.lock()
            defer { lock.unlock() }
            pacing.note(style, for: pair)
        }

        private static func isEffect(_ style: TransitionStyleRec) -> Bool {
            switch style {
            case .echoOut, .loopRoll, .reverbWash, .dropCut, .texture, .brake: return true
            case .equalPower, .djFilter, .djBlend, .gapless: return false
            }
        }
    }

    @ObservationIgnored nonisolated let pacing = TransitionPacingStore()

    /// Where the volume slider sits, 0…1 — a position, not an amplitude. See
    /// `outputGain(forVolume:)` for what the output is multiplied by.
    var volume: Double = 0.9 {
        didSet { applyOutputGain() }
    }

    /// The amplitude a slider position stands for.
    ///
    /// Linear amplitude put half the slider at only −6 dB, so most of its travel
    /// sounded alike and every quiet level was crammed into the bottom sliver —
    /// the very range somebody needs when balancing this app against another one
    /// playing at the same time. A cubic taper spreads about 60 dB evenly across
    /// the travel (0.5 ≈ −18 dB, 0.1 ≈ −60 dB), the shape system volume controls
    /// approximate.
    static func outputGain(forVolume volume: Double) -> Double {
        let position = min(max(volume, 0), 1)
        return position * position * position
    }

    /// The gain the output should be at now: the slider's, lowered while ducked.
    var targetOutputGain: Float {
        Float(Self.outputGain(forVolume: volume) * (isDucked ? Self.duckGain : 1))
    }

    /// The one writer of the output gain outside the duck ramp, so a slider move,
    /// a Dolby load or a cancelled sleep fade cannot put the output back to full
    /// while another app holds the primary audio slot.
    private func applyOutputGain() {
        duckTask?.cancel()
        let gain = targetOutputGain
        engine.setVolume(gain: gain)
        dolbyRenderer?.volume = gain
    }

    var isPlaying: Bool { state == .playing }
    /// Read-only, for the muted picture player (O9): the transport rate the
    /// engine is actually running at. The video side follows it; nothing writes
    /// through this.
    var effectivePlaybackRate: Double { playbackRate }
    /// The listener paused while the track was still loading: finish the load,
    /// then sit paused at its start instead of discarding it.
    var holdAfterLoad = false
    /// How often each track has been reloaded after its download failed.
    /// Tracks that failed every way of asking for them, and until when the
    /// queue steps over them instead of stopping on them.
    var unplayableUntil: [String: Date] = [:]
    /// The queue entry this player moved to on its own (a song ended), so a
    /// failure to load it moves on again rather than stopping the music.
    var automaticLoadEntryId: String?
    /// Tracks stepped over in a row; bounded so a dead network does not walk
    /// the whole queue.
    var automaticSkips = 0
    var deferredNetworkRecovery: (entryID: String, position: Double, generation: UInt64)?
    var streamRecoveryPathChanges = 0
    /// Recommendations that have had their one Automix ordering pass.
    var settledAutoplayIds: Set<String> = []
    /// The selection whose load is in flight, cleared once it lands or fails.
    var loadingGeneration: UInt64?
    var isBuffering: Bool { state == .buffering }
#if os(iOS)
    private(set) var mixWithOtherAudio = PlatformSettings.shared.getBoolean(
        key: "mix_with_other_audio", default: true
    )
    private var mixingPreferenceGeneration: UInt64 = 0

    /// Explicit listener choice; app transitions never change this policy.
    func setMixWithOtherAudio(_ enabled: Bool) {
        guard mixWithOtherAudio != enabled else { return }
        mixWithOtherAudio = enabled
        PlatformSettings.shared.putBoolean(key: "mix_with_other_audio", value: enabled)
        mixingPreferenceGeneration &+= 1
        nowPlaying.audioSessionUnavailable()
        guard started, isPlaying || isBuffering || AudioSessionManager.isActive else { return }
        let preference = mixingPreferenceGeneration
        let selection = playGeneration
        let intent = resumeGeneration
        Task { [weak self] in
            guard let self, self.mixingPreferenceGeneration == preference,
                  self.playGeneration == selection, self.resumeGeneration == intent,
                  self.isPlaying || self.isBuffering || AudioSessionManager.isActive else { return }
            do {
                // AudioSessionManager owns the serial worker queue. Awaiting
                // here does not configure AVAudioSession on the main thread.
                _ = try await AudioSessionManager.activate()
                guard self.mixingPreferenceGeneration == preference,
                      self.playGeneration == selection, self.resumeGeneration == intent,
                      self.isPlaying else { return }
                self.nowPlaying.updateRate(self.playbackRate, position: self.playbackPosition)
                self.nowPlaying.requestPrimaryIfPossible(reason: "mixing preference changed")
            } catch {
                guard self.mixingPreferenceGeneration == preference,
                      self.playGeneration == selection, self.resumeGeneration == intent else { return }
                self.audioActivationFailed(error)
            }
        }
    }
#endif
    var canPlayPrevious: Bool {
        playingIndex > 0 || contextWindowBaseIndex > 0 || (repeatMode == .all && !queue.isEmpty)
    }
    var canPlayNext: Bool {
        playingIndex + 1 < queue.count
            || (repeatMode == .all && !queue.isEmpty)
            || (repeatMode == .one && automixEnabled && current != nil)
    }

    /// Upstream ExoPlayer `REPEAT_MODE_OFF / ALL / ONE`.
    enum RepeatMode: Int, CaseIterable {
        case off, all, one
    }

    var repeatMode: RepeatMode = .off {
        didSet { syncSkipMixEnabled() }
    }
    var shuffleEnabled = false
    /// AutoPlay tail removed while repeat-all is on, put back when it ends —
    /// upstream `repeatAllStash`. Taken once per stretch of ALL so OFF→ALL→ONE
    /// does not overwrite a full stash with the empty tail the first step left.
    var repeatAllStash: [QueueEntry] = []
    /// `id` of the track that was current when [repeatAllStash] was taken.
    var repeatAllStashSeed: String?
    @ObservationIgnored var autoplayRefresh = AutoplayRefreshState()
    @ObservationIgnored var queueEditRevision: UInt64 = 0
    @ObservationIgnored var sequencingTask: Task<Void, Never>?
    @ObservationIgnored var sequencingGeneration: UInt64 = 0
    #if DEBUG
    @ObservationIgnored var recommendationFetchOverride: ((String, @escaping (String?, String?) -> Void) -> Void)?
    #endif
    var lyrics: [LyricLineDto] = []
    /// Empty when lyrics came from the file itself (EmbeddedLyrics).
    var lyricsSourceLabel: String?
    var lyricsLoading = false

    /// Translation and romanisation, and the state the panel's controls read.
    let lyricsTranslator = LyricsTranslator()

    /// The lyric as it should be shown: the translation when there is one.
    ///
    /// Kept beside `lyrics` rather than replacing it, so "Show Original" is
    /// instant and so a track change cannot leave a translation on screen for
    /// whatever is playing now.
    var displayedLyrics: [LyricLineDto] {
        lyricsTranslator.translatedLines ?? lyrics
    }

    /// Whether a lyric was looked for and none was found, as opposed to one still
    /// being looked for.
    ///
    /// The deck's current-lyric strip shows something in both cases, and they are
    /// different messages: "no lyrics for this track" is a fact about the track
    /// and "looking" is a fact about the moment. Telling them apart needs a flag
    /// rather than `lyrics.isEmpty`, which is true during the search too.
    var lyricsUnavailable: Bool {
        attemptedLyrics && !lyricsLoading && lyrics.isEmpty
    }

    var attemptedLyrics = false
    /// True while local audio analysis is filling in word timings.
    var lyricsAligning = false
    /// True when the playing lyric's word timings were added by this app's
    /// on-device alignment rather than arriving from the provider. Cleared on
    /// every new fetch; see `alignFetchedLyricsIfNeeded`.
    var lyricsAlignedLocally = false
    /// Re-run a lookup that began before the decoder reported the real duration.
    @ObservationIgnored var lyricsNeedsDurationRefresh = false
    /// A newer retry for the same track must win over an older provider race.
    @ObservationIgnored var lyricsRequestGeneration: UInt64 = 0
    @ObservationIgnored var lyricsAlignmentTask: Task<Void, Never>?
    var canvasURL: URL?
    var canvasFallbackURL: URL?
    /// Source returned with the active canvas payload (`SPOTIFY` or another
    /// provider). Kept with the clip so a version change does not lose it.
    var canvasSource: String?
    var canvasLookupGeneration: UInt64 = 0
    var canvasIdentity: String?
    var nerd: NerdStatsRec?
    /// True while a lossless/module lookup is still running for the playing track
    /// (upstream `NerdStats.racingLossless`).
    var racingLossless = false
    /// Automix analysis tier for stats-for-nerds: `beatmatched`, `dj`, or `plain`.
    var analysisTier: String?
    /// The planner's own words for why the next transition is what it is.
    var transitionReason: String?
    /// Analysis backends for the last planned pair: outgoing / incoming
    /// (`music_understanding`, `beat_this`, `dsp`, `disk_cache`).
    var analysisSources: String?
    /// Beat-grid confidence when native-core exposes it. Nil until then.
    var analysisConfidence: Double?
    /// Marker on the progress bar while a planned Automix window is known.
    var smartTransitionWindow: TransitionWindow?
    /// True during a real Automix (not a plain equal-power fallback).
    var smartMixInProgress = false
    /// Where in *this* track the last planned transition cued it, in seconds.
    ///
    /// Published so the mix-in point is visible while the track plays rather
    /// than only in a log line. A deep value is the symptom of a planning bug
    /// rather than a setting, and seeing it in the player is how it gets
    /// noticed; `0` means the track started at the top, which is the ordinary
    /// case now that the planner enters a record at the head of its own intro.
    var automixCueSeconds: Double?
    var sleepDeadline: ContinuousClock.Instant?
    var sleepTask: Task<Void, Never>?
    var sleepSecondsRemaining: Int?
    var sleepAfterTrack = false
    var autoplayEnabled = PlatformSettings.shared.getBoolean(key: "autoplay", default: true)
    var automixEnabled = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: true)
    var automixOnSkipEnabled = PlatformSettings.shared.getBoolean(key: "automix_on_skip", default: false)
    var hideVolumeBar = PlatformSettings.shared.getBoolean(key: "hide_volume_bar", default: false)
    /// Hides the "Playing from" / "Played by" caption on the main player.
    /// Read by the player UI; persisted here so the choice survives restarts.
    var hideSongStatus = PlatformSettings.shared.getBoolean(key: "hide_song_status", default: false)
    /// Requested PCM word length at the output boundary (`PCM_16` /
    /// `FLOAT_32`, upstream's two rungs). The engine opens the unit as int16
    /// or float to match; the Audio Pipeline readout reports what is actually
    /// in effect.
    var outputPcmMode = migrateOutputPcmMode()
    /// Opt-in exact integer output on qualifying direct routes. Unsupported
    /// tracks and routes stay on the normal path.
    var bitPerfectOutput = PlatformSettings.shared.getBoolean(key: "bit_perfect_output", default: false)
    /// Request the current source's sample rate from the DAC/audio session.
    var matchSourceSampleRate = PlatformSettings.shared.getBoolean(key: "match_source_sample_rate", default: true)
    /// Prefer an attached USB audio output over the system's normal route.
    /// The engine picks the USB device at (re)build; on iOS the session owns
    /// the route, so there it stays advisory and the readout says which route
    /// is in effect.
    var preferUsbDac = PlatformSettings.shared.getBoolean(key: "prefer_usb_dac", default: false)
    /// Level every track to the same loudness. The engine applies the
    /// catalogue figure per track (upstream's clamp); tracks without one play
    /// at unity and the readout says so.
    var soundMode = PlatformSettings.shared.getString(key: "sound_mode", default: "TRANSPARENT")
    var clarityPreset = PlatformSettings.shared.getString(key: "clarity_preset", default: "REFERENCE")
    var clarityWet = Double(PlatformSettings.shared.getFloat(key: "clarity_wet", default: 1))
    var loudnessMode = PlatformSettings.shared.getString(key: "loudness_mode", default: PlatformSettings.shared.getBoolean(key: "loudness_normalization", default: true) ? "TRACK" : "OFF")
    var loudnessNormalization = PlaybackController.storedLoudnessMode() != .off
    /// CPU budget for Automix's background analysis (EFFICIENT / BALANCED /
    /// PERFORMANCE). EFFICIENT skips the vocal model; the 1 / 2 / 4 thread
    /// counts are upstream's ORT numbers, reported for the analysis path.
    var automixPerformanceMode = PlatformSettings.shared.getString(key: "automix_performance", default: "BALANCED")
    /// Fixed effect phrase length in bars; zero keeps the analyzer's adaptive windows.
    var automixPhraseBars: Int = {
        let stored = Int(PlatformSettings.shared.getInt(key: "automix_phrase_bars", default: 0))
        return stored == 8 || stored == 16 ? stored : 0
    }()
    /// Whether a manual version switch keeps the playback position.
    /// Upstream aligns the matching moment by waveform; this port has no
    /// analyser, so "aligned" means resuming where the listener was. Off
    /// restarts from the top, since no alignment is attempted at all.
    var smartVersionAlignment = PlatformSettings.shared.getBoolean(key: "smart_version_alignment", default: true)
    /// Prefer the catalogue audio release when the queued result is a music
    /// video. Applied in the resolve race: a video entry waits for the
    /// substitute lookup instead of taking YouTube's own upload first.
    var preferMusicOnly = PlatformSettings.shared.getBoolean(key: "prefer_music_only", default: false)
    /// Which artist a scrobble credits: the full track credit ("track") or the
    /// lead name alone ("album"). Applied to every scrobble payload below.
    var scrobblePrimaryArtist = PlatformSettings.shared.getString(key: "scrobble_primary_artist", default: "track")
    var scrobbleArmed = false
    var scrobbleSent = false
    /// Loudness figure of the track the engine has loaded. Kept so a
    /// mid-track quality upgrade (same recording, new file) can carry the
    /// correction across instead of dropping to unity mid-song.
    var currentLoudnessDb: Double?
    /// Upstream `BACK_RESTARTS_AFTER_MS = 10_000`.
    static let backRestartsAfter: TimeInterval = 10

    /// Song-menu sleep-timer trailing string (`"3:21"` / `"After this song"`).
    var sleepTimerStatus: String? {
        if let sleepDeadline {
            let remaining = sleepRemaining(sleepDeadline)
            guard remaining > 0 else { return nil }
            let seconds = sleepSecondsRemaining ?? Int(remaining.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return sleepAfterTrack ? "After this song" : nil
    }

    /// Last resolve/upgrade/source decisions, for a UI "Debug log" action.
    var debugLogText: String { debugLog.dump() }
    var diagnosticSnapshot: String { "engine=\(String(describing: engine.nerdStats()))\nroute=\(String(describing: engine.outputDevice()))\ntrim_edges=\(PlatformSettings.shared.getBoolean(key: "trim_edge_silence", default: false)) skip_non_music=\(PlatformSettings.shared.getBoolean(key: "skip_non_music", default: false))\noutput=\(String(describing: engine.outputHealth()))\nstate=\(state) automix=\(automixEnabled) volume=\(volume)" }

    let debugLog = PlaybackDebugLog.shared
    var pendingAutomixPlan: TransitionPlanRec?
    var upgradeFor: String?
    @ObservationIgnored var qualityUpgradeTask: Task<Void, Never>?
    var mixFadeUntil: Date?

    /// Id the engine currently has loaded — nil after a cold restore until Play.
    var dolbyRenderer: AppleDolbyRenderer?
    var playbackPosition: Double { dolbyRenderer?.position ?? engine.positionSeconds() }
    @ObservationIgnored var durationRepairTask: Task<Void, Never>?
    var engineLoadedId: String?
    /// Cached once per selection; history polling does not scan download assets.
    var historyVideoID: String?
    /// The file the engine actually opened for the loaded track, as it reports
    /// it back. Kept because `QueueEntry.source` is **not** a path for a
    /// YouTube track — it is `yt:<videoId>` (see `QueueEntry.youtube`) — and the
    /// planner needs something it can decode. Handing it the identifier made
    /// `duration_of` return 0, which skips the whole-track analysis, leaves
    /// `bpm` at 0, and drops every plan to `Tier::Plain`: a plain crossfade on
    /// essentially all normal streaming playback, with the smart path never
    /// reached. Skipping the plan (as the load path does when it cannot get a
    /// path) is also wrong — it forgoes the cue and the arm — so the path is
    /// remembered instead.
    var regionTasks: [String: Task<Void, Never>] = [:]
    var resolvedVideoIds: [String: String] = [:]
    var preparedRegionSources: Set<String> = []
    /// The last detected edges per source, for C's no-tail instrumentation.
    var regionEdgesBySource: [String: (start: Double, end: Double?)] = [:]
    var loudnessMeasurementTask: Task<Void, Never>?
    var loadedSourcePath: String? {
        didSet { if oldValue != loadedSourcePath {
            scheduleLoudnessMeasurement()
            if let source = loadedSourcePath {
                DownloadStore.shared.retainPlayback(paths: Set([source] + Array(sourceHeadersByPath.keys)))
                prepareRegions(source: source, videoId: resolvedVideoIds[source] ?? DownloadStore.shared.provenance(for: source))
            } else { DownloadStore.shared.retainPlayback(paths: Set(sourceHeadersByPath.keys)) }
        } }
    }
    /// Request credentials travel with a source for both playback and analysis.
    /// Prefetched headers are held by source until the mixer reports handoff.
    var loadedSourceHeaders: [String: String] = [:]
    var sourceHeadersByPath: [String: [String: String]] = [:]
    /// Invalidates an older source-resolution or analysis task when the queue
    /// changes without changing the currently playing track.
    var queueNextRevision: UInt64 = 0
    /// Where a restored session left off, **and which track it was left on**.
    ///
    /// The id is the whole point. Held as a bare `Double?` the position was
    /// consumed by whichever track loaded next, so pressing Next during the
    /// window between `restoreSession` (which sets this and clears
    /// `engineLoadedId`) and the first play started a *different* song that far
    /// in — the log's `requested_start=13.013s` on a track the listener had just
    /// skipped to. A resume position belongs to a track, so it is stored with
    /// one.
    var restoredStart: (entryId: String, position: Double)?
    private var lastPersistAt = Date.distantPast

    private var positionTimer: Timer?
    var started = false
    /// The output stream must exist before a restored track is loaded into the
    /// engine. Keeping the startup task lets each load await that one boot
    /// instead of racing it on a second detached task.
    var engineStartupTask: Task<Void, Error>?
    /// Incremented on every user-initiated load so in-flight resolves/downloads
    /// from a previous tap cannot `loadTrack`/`queueNext` into the new song.
    var playGeneration: UInt64 = 0
    /// Serializes the last synchronous engine setup/load step and drops any
    /// request whose generation was superseded while it resolved or probed.
    @ObservationIgnored let loadSubmissionGate = PlaybackLoadSubmissionGate()
    /// Invalidates an in-flight audio-session reactivation when another
    /// transport command arrives before it finishes.
    var resumeGeneration: UInt64 = 0
#if os(iOS)
    @ObservationIgnored var playbackStartTask: Task<Void, Never>?
#endif
    let nowPlaying = NowPlayingController()
    let widgetPublisher = WidgetStatePublisher()
    let headTracker = HeadTracker()
    /// Session route-change observers. Held so they stay registered for the
    /// life of the controller; releasing them is what unsubscribes.
    private var routeObservers: [NSObjectProtocol] = []
    /// Tracks if playback was interrupted by phone calls, Siri, or other exclusive audio.
    var wasInterrupted = false

    init() {
        NativeStreamVerifier.install()
        _ = LoadingMonitor.shared
        _ = LaunchReadiness.shared
        let configuredSpeed = Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
        playbackRate = configuredSpeed.isFinite ? min(max(configuredSpeed, 0.5), 2.0) : 1.0
        engine.registerCallback(callback: EngineCallbacks(controller: self))
        // `didSet` does not run for the initial value: without this the engine
        // plays at its own default of full gain until something moves the slider.
        applyOutputGain()
        // The engine rebuilds the *device* on a route change; only the app can
        // re-activate the session it rebuilds against. See `outputRouteChanged`.
        // Also pause if the old device became unavailable (e.g. headphones unplugged).
        routeObservers = AudioSessionManager.observeRouteChanges(
            { [weak self] in
                Task { @MainActor in
                    AudioRouteState.shared.refresh()
                    self?.applySpatialPreference()
                    self?.outputRouteChanged()
                }
            },
            onOldDeviceUnavailable: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isPlaying || self.isBuffering || self.wasInterrupted else { return }
                    self.pausePlayback()
                }
            }
        )
        routeObservers.append(NotificationCenter.default.addObserver(
            forName: .partyMembershipDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncSkipMixEnabled() }
        })
        #if os(iOS)
        routeObservers.append(NotificationCenter.default.addObserver(forName: UIAccessibility.monoAudioStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in AudioRouteState.shared.refresh(); self?.applySpatialPreference() }
        })
        #endif
        AudioRouteState.shared.refresh()
        syncSkipMixEnabled()
        routeObservers += AudioSessionManager.observeSpatialCapabilities { [weak self] enabled in
            Task { @MainActor in
                AudioRouteState.shared.refresh(systemSpatialEnabled: enabled)
                self?.applySpatialPreference()
            }
        }
        // Handle interruptions cleanly: when an incoming call, Siri, navigation,
        // or another app begins, pause engine, notify nowPlaying, and deactivate
        // session so the other app has exclusive audio access. When interruption
        // ends with .shouldResume, automatically resume playback.
        routeObservers += AudioSessionManager.observeInterruptions(
            began: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    NSLog("[BitChord] Audio interruption began")
                    self.audioInterruptionBegan()
                }
            },
            ended: { [weak self] shouldResume in
                Task { @MainActor in
                    guard let self else { return }
                    NSLog("[BitChord] Audio interruption ended, shouldResume=\(shouldResume)")
                    self.audioInterruptionEnded(shouldResume: shouldResume)
                }
            }
        )
        // Log secondary audio events and media reset notifications
        routeObservers += AudioSessionManager.observeSessionEvents { [weak self] event in
            PlaybackDebugLog.shared.record(event)
            NSLog("[BitChord] %@", event)
            if event == "audio media services were reset" {
                Task { @MainActor in
                    self?.nowPlaying.audioSessionUnavailable()
                    AudioRouteState.shared.refresh()
                    self?.applySpatialPreference()
                    self?.outputRouteChanged()
                }
            }
        }
        // And the one session signal that asks for an action rather than a line
        // in the log: another app wants the primary audio slot. Duck, don't
        // pause — the music is the thing this app promises not to take away, and
        // the prompt is the thing that has to be heard over it.
        routeObservers += AudioSessionManager.observeSecondaryAudioSilence { [weak self] shouldSilence in
            Task { @MainActor in
                self?.applyDuck(shouldSilence)
                if !shouldSilence {
                    self?.nowPlaying.requestPrimaryIfPossible(reason: "other audio ended")
                }
            }
        }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onPlay = { [weak self] in
            guard let self, !self.isBuffering else { return }
            if self.isPlaying {
                // Selecting a secondary native card can send Play while the
                // engine is already playing. Re-anchor its actual snapshot and
                // honor that focus request without toggling playback off.
                self.nowPlaying.updateRate(self.playbackRate, position: self.playbackPosition)
                self.reactivateAudioSessionAfterForeground(reason: "native play")
                return
            }
            self.togglePlayPause()
        }
#if os(iOS)
        nowPlaying.onPlayAsync = { [weak self] in
            guard let self else { throw CancellationError() }
            self.nowPlaying.onPlay?()
            let intent = self.resumeGeneration
            let selection = self.playGeneration
            await self.playbackStartTask?.value
            guard self.resumeGeneration == intent, self.playGeneration == selection,
                  self.isPlaying else { throw CancellationError() }
        }
#endif
        nowPlaying.onPause = { [weak self] in
            guard let self else { return }
            // A physical/remote Pause during a Siri interruption still cancels
            // the pending resume, even though the engine is already paused.
            self.wasInterrupted = false
            self.resumeGeneration &+= 1
            guard self.isPlaying || self.isBuffering else { return }
            self.pausePlayback()
        }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlaying.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        // The audio session is activated by `startEngineIfNeeded`, not here.
        // Activating from `init` raced the engine start — two detached tasks
        // with nothing ordering them — and a RemoteIO unit built before the
        // session was up never gets pulled, so the track played in silence.
        QualityUpgrade.forgetLastSession()
        restoreSession()
        let token = PlatformSettings.shared.getSecret(key: "discord_token") ?? ""
        if !token.isEmpty { DiscordGateway.shared.connect(token: token) }
    }

    func startEngineIfNeeded() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            guard let self else { return }
            await reloadAutomixModels(playbackStarted: self.started)
            if self.automixEnabled { self.syncEngineQueueNext() }
        }
        // Engine start touches HAL / cpal which blocks (~1s) and triggers
        // Thread Performance Checker if done on main. Run on utility QoS
        // so it doesn't outrank the Default QoS cpal monitor thread
        // (upstream runs PlaybackService on its own thread).
        let eng = engine
        let crossfade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        let spatial = PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false) && AudioRouteState.shared.permitsCustomSpatial
        let skip = PlatformSettings.shared.getBoolean(key: "skip_silence", default: false)
        let speed = PlatformSettings.shared.getFloat(key: "playback_speed", default: 1)
        let startBitPerfect = effectiveBitPerfectOutput
        playbackRate = Double(speed).isFinite ? min(max(Double(speed), 0.5), 2.0) : 1.0
        let eq = Self.currentEqTuning()
        engineStartupTask = Task.detached(priority: .utility) { [weak self] in
            do {
                // The session has to be up before the output stream exists, and
                // the iOS session owns the hardware format — so this is awaited,
                // and its answer is what the engine is told to open at.
                let format = try await AudioSessionManager.activate()
                // Configure device choice and sample format before opening the
                // stream. Applying them just after start caused a second output
                // build while the first track could already be playing.
                try eng.setOutputPcmMode(mode: Self.migrateOutputPcmMode())
                try eng.setBitPerfectEnabled(enabled: startBitPerfect)
                try eng.setPreferUsbDac(
                    enabled: PlatformSettings.shared.getBoolean(key: "prefer_usb_dac", default: false)
                )
                eng.setAutomixPerformance(
                    mode: PlatformSettings.shared.getString(key: "automix_performance", default: "BALANCED")
                )
                let storedPhraseBars = PlatformSettings.shared.getInt(key: "automix_phrase_bars", default: 0)
                let phraseBars = storedPhraseBars == 8 || storedPhraseBars == 16 ? storedPhraseBars : 0
                eng.setAutomixPhraseBars(bars: UInt32(phraseBars))
                try eng.start(
                    rate: format?.rate,
                    channels: format?.channels
                )
                try eng.setSoundMode(mode: PlatformSettings.shared.getString(key: "sound_mode", default: "TRANSPARENT") == "ENHANCED" ? .enhanced : .transparent)
                try eng.setClarityTuning(tuning: Self.storedClarityTuning())
                try eng.setLoudnessMode(mode: Self.storedLoudnessMode())
                try eng.setCrossfadeWindow(seconds: crossfade)
                try eng.setSpatialEnabled(enabled: spatial)
                try eng.setSkipSilence(enabled: skip)
                try eng.setPlaybackSpeed(speed: speed)
                try eng.setEqTuning(
                    enabled: eq.enabled,
                    gainsDb: eq.gains,
                    qs: eq.qs,
                    balance: eq.balance
                )

                if spatial && PlatformSettings.shared.getString(key: "sound_mode", default: "TRANSPARENT") == "ENHANCED" {
                    await MainActor.run { [weak self] in self?.headTracker.start(engine: eng) }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.started = false
                    self.positionTimer?.invalidate()
                    self.positionTimer = nil
                    self.lastError = "Audio engine failed to start: \(error)"
                }
                throw error
            }
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for event in drainTechnicalEvents() { self.debugLog.record(event) }
                self.pollWidgetCommands()
                self.pollStreamRecovery()
                guard self.state == .playing else { return }
                // Load/handoff snapshots precede the first rendered chunk. Refresh
                // engine evidence as playback changes; do not display that stale snapshot.
                if self.dolbyRenderer == nil {
                    let latest = self.engine.nerdStats()
                    if self.nerd != latest { self.nerd = latest }
                }
                self.position = self.playbackPosition
                self.positionSampledAt = Date()
                self.nowPlaying.update(position: self.position)
                if let sample = self.pendingPlaybackLatency,
                   sample.entryID == self.current?.id,
                   let resolvedAt = sample.resolvedAt,
                   let firstBufferAt = sample.firstBufferAt,
                   self.position > sample.initialPosition + 0.01 {
                    let audibleAt = ProcessInfo.processInfo.systemUptime
                    let summary = String(
                        format: "latency: tap→resolved %.0fms, →first buffer %.0fms, →first audible %.0fms (%@, %@)",
                        (resolvedAt - sample.startedAt) * 1_000,
                        (firstBufferAt - sample.startedAt) * 1_000,
                        (audibleAt - sample.startedAt) * 1_000,
                        sample.cacheState as NSString,
                        sample.client as NSString
                    )
                    PlaybackDebugLog.shared.record(summary, about: sample.entryID)
                    self.pendingPlaybackLatency = nil
                }
                // The periodic output-health NSLog that used to sit here is
                // gone: every figure it carried — buffered frames, silent
                // callbacks, rebuilds, xruns and the output peak — is on the
                // Audio Pipeline sheet, live and without a console. It was the
                // loudest thing in the log, five lines a second after every
                // load, and it answered its question.
                self.tickSleep()
                self.tickScrobble()
                self.tickHistory()
                self.tickListening()
                if Date().timeIntervalSince(self.lastPersistAt) >= 4 {
                    self.lastPersistAt = Date()
                    self.persistSession()
                }
            }
        }
    }

    /// A running output can survive in the background while iOS temporarily
    /// deactivates its audio session. Reassert playback activation on return
    /// only when actively playing; do not hijack audio when paused or idle.
    func reactivateAudioSessionAfterForeground(reason: String = "foreground") {
        guard started, state == .playing else { return }
        let selection = playGeneration
        let intent = resumeGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try await AudioSessionManager.activate()
                await MainActor.run { [weak self] in
                    guard let self, self.state == .playing,
                          self.playGeneration == selection, self.resumeGeneration == intent else { return }
                    self.nowPlaying.requestPrimaryIfPossible(reason: reason)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == selection,
                          self.resumeGeneration == intent else { return }
                    self.audioActivationFailed(error)
                }
            }
        }
    }

    func audioActivationFailed(_ error: Error) {
        nowPlaying.audioSessionUnavailable()
        if isPlaying || isBuffering { pausePlayback(releaseAudioSession: true) }
        lastError = "Audio session could not activate: \(error)"
    }

    /// The output route moved under us — AirPods put down, a device connected,
    /// the route reconfigured.
    ///
    /// The engine hears about this directly from CoreAudio and rebuilds the
    /// audio unit. Two things still have to happen here, and they are the
    /// reason this handler exists at all:
    ///
    /// 1. The session is the app's, so only the app can re-activate it. A unit
    ///    built while the session is down is never pulled by the audio daemon —
    ///    silent, with the mixer cheerfully filling a ring that nothing drains.
    /// 2. That has to be ordered *before* the rebuild. Activation lands in
    ///    milliseconds and `requestOutputRebuild` is not dropped when a rebuild
    ///    is already running, so this second pass runs after the session is up
    ///    even if CoreAudio's own rebuild beat us to it.
    private var routeRecoveryGeneration: UInt64 = 0
    private func outputRouteChanged() {
        let route = AudioRouteState.shared
        let returnedFromBluetooth = route.previousKind.lowercased().contains("bluetooth") && route.carriesLossless
        routeRecoveryGeneration &+= 1
        let recovery = routeRecoveryGeneration
        guard started, state == .playing else { return }
        let selection = playGeneration
        let intent = resumeGeneration
        let engine = self.engine
        let sessionWasActive = AudioSessionManager.isActive
        Task.detached(priority: .userInitiated) { [weak self] in
            let sessionFormat: AudioSessionManager.Format?
            do {
                sessionFormat = try await AudioSessionManager.activate()
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == selection,
                          self.resumeGeneration == intent, self.routeRecoveryGeneration == recovery else { return }
                    self.audioActivationFailed(error)
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.isPlaying, self.playGeneration == selection,
                      self.resumeGeneration == intent, self.routeRecoveryGeneration == recovery else { return }
                do {
                    try engine.setLoudnessMode(mode: self.routeAwareLoudnessMode)
                    try engine.setBitPerfectEnabled(enabled: self.effectiveBitPerfectOutput)
                    if self.dolbyRenderer == nil {
                        if Self.routeEventKeepsOutput(engine.outputDevice(), session: sessionFormat,
                                                      sessionWasActive: sessionWasActive) {
                            self.debugLog.record("route event kept the rebuilt output")
                        } else {
                            try engine.requestOutputRebuild(force: true)
                        }
                    }
                    if returnedFromBluetooth, let entry = self.current {
                        QualityUpgrade.resetAutomaticAttemptForRoute(entry.id)
                        self.lookForBetterCopy(entry, codec: self.nerd?.codec ?? "", kbps: self.nerd?.kbps ?? 0)
                    }
                    self.nowPlaying.requestPrimaryIfPossible(reason: "route activation")
                } catch {
                    NSLog("[BitChord] output rebuild after route change failed: \(error)")
                }
            }
        }
    }

    /// Whether a route event's second, forced rebuild would only repeat the one
    /// the engine already made.
    ///
    /// On iOS the engine hears every route event from CoreAudio and rebuilds the
    /// unit itself. This handler's own rebuild exists for the session: a unit
    /// built while the session was down is never pulled. When the session stayed
    /// up and the rebuilt unit already matches its format, a second rebuild only
    /// throws the buffered audio away and seeks back again — twice per event in a
    /// burst of them, which is what AirPods hopping between devices on a
    /// notification sounded like: the music all but stopping, over and over.
    ///
    /// macOS keeps its rebuild: there the event is a default-device change the
    /// engine does not see on its own.
    nonisolated static func routeEventKeepsOutput(
        _ output: OutputDeviceRec, session: AudioSessionManager.Format?, sessionWasActive: Bool
    ) -> Bool {
        #if os(iOS)
        guard sessionWasActive, output.started, let session else { return false }
        return Double(output.sampleRate) == session.rate && output.channels == session.channels
        #else
        return false
        #endif
    }

    /// How far down a duck goes: −16 dB.
    ///
    /// Audible as "quieter", not as "gone". A navigation prompt reads clearly
    /// over it and the listener's own music does not stop, which is the promise
    /// this app makes about coexisting with other audio.
    private static let duckGain: Double = 0.16

    /// The ramp in flight, if any.
    ///
    /// Held so a new instruction cancels the one it interrupts — two ramps
    /// writing the output gain at once is a fight the engine cannot arbitrate.
    @ObservationIgnored private var duckTask: Task<Void, Never>?
    /// Whether a duck is currently applied, so repeat notifications are free.
    @ObservationIgnored private var isDucked = false

    /// Quieter while iOS says another app wants the primary audio slot.
    ///
    /// Three deliberate choices:
    ///
    /// - **Duck, not pause.** The session is mixable, so the system will not
    ///   stop us; whether to get out of the way is ours to decide, and stopping
    ///   the music for a two-second prompt is not the trade this app makes.
    /// - **Ramp, not step.** The engine applies the gain per sample, so a jump
    ///   is a click. Twenty steps of ~10 ms is ~200 ms to −16 dB: fast enough to
    ///   be out of the way when a prompt starts, slow enough not to be heard as
    ///   a jump.
    /// - **The output, not `volume`.** This calls the engine directly instead of
    ///   going through the published `volume`, so the slider keeps showing what
    ///   the listener chose while the *output* is quieter. Ducking by writing
    ///   `volume` would have moved their control and then had to guess what to
    ///   put it back to.
    private func applyDuck(_ shouldDuck: Bool) {
        guard shouldDuck != isDucked else { return }
        isDucked = shouldDuck
        duckTask?.cancel()
        let full = Self.outputGain(forVolume: volume)
        let from = Float(full * (shouldDuck ? 1.0 : Self.duckGain))
        let to = targetOutputGain
        let engine = self.engine
        duckTask = Task(priority: .userInitiated) { [weak self] in
            let steps = 20
            for step in 1...steps {
                if Task.isCancelled { return }
                let progress = Float(step) / Float(steps)
                engine.setVolume(gain: from + (to - from) * progress)
                self?.dolbyRenderer?.volume = from + (to - from) * progress
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    // ---- Queue operations ---------------------------------------------------

    /// Song entries the video toggle replaced with their music-video upload,
    /// keyed by that upload's id, so turning the toggle off can put each back.
    @ObservationIgnored var songVersions: [String: QueueEntry] = [:]

    /// Told when *the listener* uses this device's controls, so a party can stop
    /// trying to undo the press for a moment.
    ///
    /// The listener, specifically, and not "whenever the transport changes": a party
    /// binding moves this transport itself several times a minute, and telling it
    /// about its own corrections would leave it permanently convinced that the
    /// listener had just pressed something and it should therefore not correct
    /// anything at all. The binding wraps its own calls in
    /// [withLocalIntentSuppressed].
    ///
    /// A closure rather than a direct reference to the binding, because the controller
    /// is created before anything else exists and a party is not always there.
    @ObservationIgnored var onLocalIntent: (() -> Void)?

    /// How deep the party binding is in the middle of moving the transport itself.
    ///
    /// A counter rather than a flag because reconcile can be re-entered — a load that
    /// finishes can schedule work that seeks — and a boolean cleared by an inner call
    /// would leave the outer one reporting itself as the listener.
    @ObservationIgnored var intentSuppression = 0

    /// When [position] was last read from the engine. See [livePosition].
    @ObservationIgnored var positionSampledAt = Date.distantPast
    /// The engine advances source time at this rate between position polls.
    @ObservationIgnored var playbackRate = 1.0

    var resolvedOrigin: [String: ResolvedSource.Origin] = [:]


    /// The provider picker's model, upstream's `lyricsProviderStates`: every
    /// enabled source's state for the current track, plus the lines a FOUND
    /// source already returned, so tapping it applies them from memory instead
    /// of asking again. Keyed by source name.
    var lyricsProviderStates: [String: LyricsSourceState] = [:]
    var lyricsProviderResults: [String: [LyricLineDto]] = [:]
    /// The provider the listener chose for this track, remembered across
    /// fetches and across devices (iCloud key-value store). When the race's
    /// winner and the choice both have lines, the choice wins.
    var lyricsProviderChoice: String?
}

/// Where a per-track provider choice is kept. A protocol because the
/// destination is iCloud's key-value store once provisioning allows the
/// entitlement; today it is local defaults, which keep the picker honest
/// on this device alone.
protocol LyricsChoiceStore {
    func choice(for trackId: String) -> String?
    func remember(_ source: String, for trackId: String)
}

