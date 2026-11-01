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

#if DEBUG
extension PlaybackController {
#if os(iOS)
    /// Explicit, muted cold-launch diagnostic: exercise the saved queue that
    /// init restored, rather than loading a replacement fixture in this process.
    func verifyRestoredResumeBehavior(mixing: Bool) async {
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedMixing = mixWithOtherAudio
        let savedAutomix = automixEnabled
        let savedVolume = volume
        let saved = LastPlayed.load()
        let background = UIApplication.shared.beginBackgroundTask(withName: "restored resume verification")
        defer { UIApplication.shared.endBackgroundTask(background) }
        var checks: [String: Bool] = [:]
        var samples: [[String: Any]] = []
        func sample(_ label: String) {
            let session = AVAudioSession.sharedInstance()
            let row: [String: Any] = ["label": label, "id": current?.id ?? "",
                "position": position, "enginePosition": engine.positionSeconds(),
                "state": String(describing: state), "audioActive": AudioSessionManager.isActive,
                "category": session.category.rawValue, "options": session.categoryOptions.rawValue,
                "policy": session.routeSharingPolicy.rawValue, "error": lastError ?? ""]
            samples.append(row)
            debugLog.record("restored resume verification \(row)")
        }
        if let saved {
            let entry = saved.tracks[saved.index]
            checks["restored_track_and_position"] = current?.id == entry.id
                && playingIndex == saved.index && abs(position - saved.position) < 0.01
            checks["cold_output_inactive"] = !started && !AudioSessionManager.isActive && state == .paused
            sample("cold restore")
            do {
                setMixWithOtherAudio(mixing)
                setAutomixEnabled(false)
                volume = 0
                togglePlayPause()
                await playbackStartTask?.value
                // Native commands finish submitting before the render thread
                // publishes its first position snapshot. Observe that snapshot
                // before checking the restored seek, rather than reading 0.
                for _ in 0..<40 {
                    if !isPlaying || engine.positionSeconds() >= max(0, saved.position - 0.1) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                checks["loaded_saved_track"] = isPlaying && current?.id == entry.id && lastError == nil
                let resumedAt = engine.positionSeconds()
                checks["loaded_saved_position"] = abs(resumedAt - saved.position) < 1
                sample("first play")
                try await Task.sleep(for: .seconds(3))
                checks["playback_progress"] = isPlaying && engine.positionSeconds() > resumedAt + 2
                let session = AVAudioSession.sharedInstance()
                checks["mixing_preference_preserved"] = mixWithOtherAudio == mixing
                    && session.categoryOptions.contains(.mixWithOthers) == mixing
                checks["compatible_routing_policy"] = session.routeSharingPolicy == (mixing ? .default : .longFormAudio)
                checks["active_playback_category"] = AudioSessionManager.isActive && session.category == .playback
                sample("playing")
                pausePlayback()
                let pausedAt = engine.positionSeconds()
                try await Task.sleep(for: .milliseconds(500))
                checks["stable_pause"] = state == .paused && abs(engine.positionSeconds() - pausedAt) < 0.1
                try await nowPlaying.onPlayAsync?()
                try await Task.sleep(for: .seconds(2))
                checks["resume_progress"] = isPlaying && engine.positionSeconds() > pausedAt + 1
                sample("resumed")
            } catch {
                checks["runtime_error"] = false
                debugLog.record("restored resume verification error: \(error)")
            }
        } else {
            checks["saved_track_available"] = false
        }
        pausePlayback()
        playGeneration &+= 1
        resumeGeneration &+= 1
        loadSubmissionGate.advance(to: playGeneration) { [engine] in try? engine.stop() }
        nowPlaying.stop()
        await AudioSessionManager.deactivate()
        setMixWithOtherAudio(savedMixing)
        setAutomixEnabled(savedAutomix)
        volume = savedVolume
        if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
        else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
        PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
        restoreSession()
        checks["saved_queue_restored"] = UserDefaults.standard.data(forKey: "bitchord_last_played") == savedQueue
        checks["saved_preferences_restored"] = mixWithOtherAudio == savedMixing && automixEnabled == savedAutomix
            && volume == savedVolume
        let result: [String: Any] = ["checks": checks, "samples": samples, "mixing": mixing,
            "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("restored-resume-\(mixing ? "mixing" : "exclusive")-verification.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report, options: .atomic)
        }
        debugLog.record("restored resume verification complete: \(checks)")
    }

    /// Explicit, muted device diagnostic. Uses the signed-in account already
    /// restored by AuthController and restores the user's saved queue afterward.
    func verifyRapidNavigation() async {
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedAutomix = automixEnabled
        let savedVolume = volume
        let background = UIApplication.shared.beginBackgroundTask(withName: "navigation verification")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            setAutomixEnabled(savedAutomix)
            volume = savedVolume
            if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
            else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
            PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
            restoreSession()
        }
        let ids = ["8UhQfqMkObk", "r6fihQByHx0", "gOnyq8DjpFY", "qKyF5R-IE64",
                   "pNxTO1czMkc", "QX1KRphxnQc", "Xxq1XfsQOIE", "35tNuvmBVMc",
                   "N7IxlspnaQw", "9NM0hPDWIyg"]
        let entries = ids.enumerated().map { index, id in
            QueueEntry(id: id, title: "Navigation fixture \(index + 1)", artist: "BitChord",
                       source: "yt:" + id, durationText: "", isLocal: false)
        }
        var checks: [String: Bool] = [:]
        var samples: [[String: Any]] = []
        func sample(_ label: String) {
            let row: [String: Any] = ["label": label, "id": current?.id ?? "", "index": playingIndex,
                "state": String(describing: state), "position": position, "error": lastError ?? ""]
            samples.append(row)
            debugLog.record("navigation verification \(row)")
        }
        do {
            setAutomixEnabled(false)
            volume = 0
            play(entries)
            for _ in 0..<50 {
                if (isPlaying && duration > 0) || lastError != nil { break }
                try await Task.sleep(for: .milliseconds(400))
            }
            checks["initial_track_playing"] = isPlaying && lastError == nil
            checks["initial_duration_from_resolver"] = duration > 0
            try await Task.sleep(for: .milliseconds(400))
            checks["initial_progress_fraction"] = duration > 0 && position > 0 && position / duration > 0
            seek(to: 15)
            try await Task.sleep(for: .seconds(1))
            checks["seek_changes_real_position"] = isPlaying && position >= 15 && position < 19
            sample("initial")
            var played = isPlaying
            for step in 1..<entries.count {
                next()
                try await Task.sleep(for: .seconds(4))
                checks["next_\(step)_selected"] = current?.id == ids[step]
                checks["next_\(step)_playing"] = isPlaying && lastError == nil
                checks["next_\(step)_duration_known"] = duration > 0
                played = played || isPlaying
                sample("next \(step)")
            }
            // Force the usual restart threshold out of the way so these taps
            // exercise actual Back selection, including after failed loads.
            for step in 1...3 {
                seek(to: 0)
                previous()
                try await Task.sleep(for: .seconds(4))
                checks["back_\(step)_selected"] = current?.id == ids[ids.count - 1 - step]
                checks["back_\(step)_playing"] = isPlaying && lastError == nil
                played = played || isPlaying
                sample("back \(step)")
            }
            checks["at_least_one_live_track_played"] = played
            // Return to the first track after all failures and rapid selections.
            play([entries[0]])
            for _ in 0..<50 {
                if (isPlaying && duration > 0) || lastError != nil { break }
                try await Task.sleep(for: .milliseconds(400))
            }
            checks["first_track_still_playable"] = isPlaying
            sample("return to first")
        } catch { checks["runtime_error"] = false }
        pausePlayback()
        playGeneration &+= 1
        resumeGeneration &+= 1
        loadSubmissionGate.advance(to: playGeneration) { [engine] in try? engine.stop() }
        nowPlaying.stop()
        await AudioSessionManager.deactivate()
        let result: [String: Any] = ["checks": checks, "samples": samples,
            "quality": ["wifiSaved": PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "LOSSLESS"),
                        "mobileSaved": PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "LOSSLESS"),
                        "wifiPolicy": AppSettings.shared.effectiveAudioQuality(metered: false).name,
                        "mobilePolicy": AppSettings.shared.effectiveAudioQuality(metered: true).name,
                        "metered": NetworkQuality.shared.metered,
                        "effective": AppSettings.shared.effectiveAudioQuality(metered: NetworkQuality.shared.metered).name],
            "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("navigation-verification.json")
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        debugLog.record("navigation verification complete: \(checks)")
    }

    /// Reproduces a failed/unarmed prefetch using local audio and the real engine.
    func verifyNaturalEndFallback() async {
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedAutomix = automixEnabled, savedVolume = volume
        let savedRepeat = repeatMode
        var checks: [String: Bool] = [:]
        let background = UIApplication.shared.beginBackgroundTask(withName: "natural end verification")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            setAutomixEnabled(savedAutomix); volume = savedVolume; repeatMode = savedRepeat
            if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
            else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
            PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
            restoreSession()
        }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 8)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 220 / 44100) * 0.02)
                }
            }
            var entries: [QueueEntry] = []
            for index in 0..<2 {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("natural-end-\(index).wav")
                do { let file = try AVAudioFile(forWriting: path, settings: format.settings); try file.write(from: buffer) }
                entries.append(QueueEntry(id: "natural-end-\(index)", title: "End fixture \(index)", artist: "Validation",
                    source: path.path, durationText: "0:08", isLocal: true))
            }
            volume = 0; repeatMode = .off; setAutomixEnabled(false)
            play(entries)
            for _ in 0..<100 { if isPlaying && engineLoadedId == entries[0].id { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["first_started"] = isPlaying && current?.id == entries[0].id
            // Cancel any pending arming job, then explicitly leave no successor.
            queueNextRevision &+= 1
            loadSubmissionGate.setQueueRevision(queueNextRevision)
            try engine.queueNextIfCurrent(request: LoadRequest(source: "", title: "", artist: "", startSeconds: 0,
                plan: nil, headers: [:], claimedKbps: 0, loudnessDb: nil, durationSeconds: nil), expectedSource: entries[0].source)
            checks["no_prefetched_successor"] = engine.pendingTrack() == nil
            for _ in 0..<120 { if current?.id == entries[1].id && isPlaying { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["unarmed_end_advances"] = current?.id == entries[1].id && isPlaying
            handleTrackEnded(.natural, source: entries[0].source)
            checks["obsolete_end_ignored"] = current?.id == entries[1].id && isPlaying
            for _ in 0..<120 { if state == .stopped { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["final_end_releases_loaded_voice"] = state == .stopped && engineLoadedId == nil
            togglePlayPause()
            for _ in 0..<80 { if isPlaying && engineLoadedId == entries[1].id { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["resume_after_end_reopens_from_start"] = isPlaying && engine.positionSeconds() < 2
        } catch { checks["runtime_error"] = false; debugLog.record("natural end verification error: \(error)") }
        pausePlayback(); playGeneration &+= 1; resumeGeneration &+= 1
        loadSubmissionGate.advance(to: playGeneration) { [engine] in try? engine.stop() }
        nowPlaying.stop(); await AudioSessionManager.deactivate()
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("natural-end-verification.json")
        let result: [String: Any] = ["checks": checks, "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        debugLog.record("natural end verification complete: \(checks)")
    }

    /// An explicit diagnostic launch exercises the real controller, RemoteIO,
    /// decoder and published MediaSession. User queue/preferences are restored.
    func verifyNativeResumeBehavior() async {
        let engine = self.engine
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedMixing = mixWithOtherAudio
        let savedAutomix = automixEnabled
        let savedVolume = volume
        let background = UIApplication.shared.beginBackgroundTask(withName: "native resume verification")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            setMixWithOtherAudio(savedMixing)
            setAutomixEnabled(savedAutomix)
            volume = savedVolume
            if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
            else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
            PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
            restoreSession()
        }
        var checks: [String: Bool] = nowPlaying.verifyModernObservation()
        var samples: [[String: Any]] = []
        func sample(_ label: String) {
            let health = engine.outputHealth()
            let row: [String: Any] = ["label": label, "position": engine.positionSeconds(),
                "state": String(describing: state), "audioActive": AudioSessionManager.isActive,
                "rebuilds": health.outputRebuilds, "buffered": health.bufferedFrames,
                "underruns": health.callbackUnderruns, "peak": health.outputPeak]
            samples.append(row)
            debugLog.record("native resume verification \(row)")
        }
        do {
            let directory = FileManager.default.temporaryDirectory
            let wav = directory.appendingPathComponent("native-resume-fixture.wav")
            let aac = directory.appendingPathComponent("native-resume-fixture.m4a")
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let count: AVAudioFrameCount = 44100 * 40
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            for channel in 0..<2 {
                for frame in 0..<Int(count) {
                    // Vary the signal with time so a repeated output segment is
                    // distinguishable from an ordinary steady test tone.
                    let seconds = Double(frame) / 44100
                    buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * (220 * seconds + 3 * seconds * seconds)) * 0.08)
                }
            }
            do {
                let pcm = try AVAudioFile(forWriting: wav, settings: format.settings)
                try pcm.write(from: buffer)
            }
            do {
                let compressed = try AVAudioFile(forWriting: aac, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                try compressed.write(from: buffer)
            }
            setMixWithOtherAudio(false)
            setAutomixEnabled(false)
            volume = 0.08
            for fixture in [wav, aac] {
                let name = fixture.pathExtension
                let entry = QueueEntry(id: "native-resume-\(name)", title: "Resume verification", artist: "BitChord", source: fixture.path, durationText: "0:40", isLocal: true)
                play([entry])
                await playbackStartTask?.value
                try await Task.sleep(for: .seconds(2))
                checks["\(name)_initial_progress"] = isPlaying && engine.positionSeconds() > 1
                sample("\(name) initial")
                for (cycle, delay) in [0.3, 10.0, 0.3].enumerated() {
                    nowPlaying.onPause?()
                    let pausedPosition = engine.positionSeconds()
                    let rebuilds = engine.outputHealth().outputRebuilds
                    try await Task.sleep(for: .seconds(delay))
                    checks["\(name)_\(cycle)_stable_pause"] = state == .paused && abs(engine.positionSeconds() - pausedPosition) < 0.1
                    checks["\(name)_\(cycle)_retained_activation"] = AudioSessionManager.isActive
                    sample("\(name) paused \(cycle)")
                    try await nowPlaying.onPlayAsync?()
                    var positions: [Double] = []
                    for _ in 0..<12 {
                        try await Task.sleep(for: .milliseconds(200))
                        positions.append(engine.positionSeconds())
                    }
                    checks["\(name)_\(cycle)_resume_progress"] = positions.last! > pausedPosition + 1.5
                    checks["\(name)_\(cycle)_monotonic"] = zip(positions, positions.dropFirst()).allSatisfy { $1 + 0.02 >= $0 }
                    checks["\(name)_\(cycle)_no_rebuild"] = engine.outputHealth().outputRebuilds == rebuilds
                    checks["\(name)_\(cycle)_audible_output"] = engine.outputHealth().outputPeak > 0.00001
                    sample("\(name) resumed \(cycle)")
                }
                // The output must NOT be reused after an interruption or an
                // explicit session release, even if its hardware format agrees.
                pausePlayback()
                // Model an inactive output without asking a previously
                // interrupted competing app to resume halfway through this
                // controlled recovery measurement.
                await AudioSessionManager.deactivate(notifyOthers: false)
                let interruptedPosition = engine.positionSeconds()
                let interruptedRebuilds = engine.outputHealth().outputRebuilds
                try await nowPlaying.onPlayAsync?()
                try await Task.sleep(for: .seconds(2))
                checks["\(name)_released_session_recovers"] = isPlaying && engine.positionSeconds() > interruptedPosition + 1 && engine.outputHealth().outputRebuilds > interruptedRebuilds
                checks["\(name)_released_session_audible"] = engine.outputHealth().outputPeak > 0.00001
                sample("\(name) released-session recovery")

                // Pause during an unfinished native Play must win. A later
                // fresh Play must remain usable after the cancelled completion.
                nowPlaying.onPause?()
                let cancelledPosition = engine.positionSeconds()
                let pendingPlay = Task { @MainActor in try await self.nowPlaying.onPlayAsync?() }
                await Task.yield()
                nowPlaying.onPause?()
                _ = try? await pendingPlay.value
                try await Task.sleep(for: .milliseconds(500))
                checks["\(name)_rapid_pause_wins"] = state == .paused && abs(engine.positionSeconds() - cancelledPosition) < 0.15
                try await nowPlaying.onPlayAsync?()
                try await Task.sleep(for: .seconds(2))
                checks["\(name)_fresh_play_after_cancellation"] = isPlaying && engine.positionSeconds() > cancelledPosition + 1
                sample("\(name) fresh play after cancellation")
                nowPlaying.onPause?()
                let mixingPosition = engine.positionSeconds()
                setMixWithOtherAudio(true)
                _ = try await AudioSessionManager.activate()
                checks["\(name)_paused_mixing_on"] = !isPlaying && AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers)
                    && AVAudioSession.sharedInstance().routeSharingPolicy == .default
                setMixWithOtherAudio(false)
                _ = try await AudioSessionManager.activate()
                checks["\(name)_paused_mixing_off"] = !isPlaying && !AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers)
                    && AVAudioSession.sharedInstance().routeSharingPolicy == .longFormAudio
                checks["\(name)_paused_mixing_keeps_position"] = abs(engine.positionSeconds() - mixingPosition) < 0.15
            }
        } catch {
            checks["runtime_error"] = false
            debugLog.record("native resume verification error: \(error)")
        }
        pausePlayback()
        playGeneration &+= 1
        resumeGeneration &+= 1
        loadSubmissionGate.advance(to: playGeneration) { try? engine.stop() }
        nowPlaying.stop()
        await AudioSessionManager.deactivate()
        let result: [String: Any] = ["checks": checks, "samples": samples,
            "quality": ["wifiSaved": PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "LOSSLESS"),
                        "mobileSaved": PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "LOSSLESS"),
                        "wifiPolicy": AppSettings.shared.effectiveAudioQuality(metered: false).name,
                        "mobilePolicy": AppSettings.shared.effectiveAudioQuality(metered: true).name,
                        "metered": NetworkQuality.shared.metered,
                        "effective": AppSettings.shared.effectiveAudioQuality(metered: NetworkQuality.shared.metered).name],
            "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("native-resume-verification.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        debugLog.record("native resume verification result \(checks)")
        print("NATIVE RESUME VERIFICATION \(checks)")
    }
#endif

    /// Explicit Mac validation launch: local audio and controlled recommendation
    /// replies. Run in an isolated bundle so the listener's queue/preferences stay intact.
    func verifyQueueBehavior() async {
        var checks: [String: Bool] = [:]
        volume = 0
        autoplayEnabled = false
        setAutomixEnabled(false)
        repeatMode = .off
        let root = FileManager.default.temporaryDirectory
        let path = root.appendingPathComponent("queue-validation.wav")
        func word<T: FixedWidthInteger>(_ value: T) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        let count: UInt32 = 44100 * 20
        var audio = Data("RIFF".utf8); audio.append(word(UInt32(36 + count * 4)))
        audio.append(Data("WAVEfmt ".utf8)); audio.append(word(UInt32(16)))
        audio.append(word(UInt16(1))); audio.append(word(UInt16(2))); audio.append(word(UInt32(44100)))
        audio.append(word(UInt32(44100 * 4))); audio.append(word(UInt16(4))); audio.append(word(UInt16(16)))
        audio.append(Data("data".utf8)); audio.append(word(count * 4))
        audio.append(Data(count: Int(count * 4)))
        try? audio.write(to: path)
        let entry = QueueEntry(id: "queue-local", title: "", artist: "", source: path.path, durationText: "0:20", isLocal: true)
        togglePlaybackContext([entry], title: "First list", contextID: "first")
        checks["buffering_hero_shows_pause"] = isPlaybackContextPlaying("first")
        for _ in 0..<100 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        checks["local_audio_loaded"] = isPlaying && lastError == nil
        togglePlaybackContext([entry], title: "First list", contextID: "first")
        checks["same_list_pauses"] = state == .paused && !isPlaybackContextPlaying("first")
        togglePlaybackContext([entry], title: "First list", contextID: "first")
        for _ in 0..<30 { if isPlaying { break }; try? await Task.sleep(for: .milliseconds(100)) }
        checks["same_list_resumes"] = isPlaying && isPlaybackContextPlaying("first")
        let beforeInvalidSeek = position
        seek(to: .nan)
        seek(to: .infinity)
        checks["nonfinite_seek_ignored"] = position == beforeInvalidSeek
        seek(to: -10)
        checks["negative_seek_clamped"] = position == 0
        seek(to: duration + 10)
        checks["seek_clamped_to_duration"] = position == duration
        seek(to: 1)
        audioInterruptionBegan()
        checks["interruption_pauses"] = state == .paused && wasInterrupted
        togglePlayPause()
        for _ in 0..<30 { if isPlaying { break }; try? await Task.sleep(for: .milliseconds(100)) }
        let manualResume = resumeGeneration
        audioInterruptionEnded(shouldResume: true)
        checks["manual_resume_survives_interruption_end"] = isPlaying && !wasInterrupted && resumeGeneration == manualResume
        pausePlayback()
        audioInterruptionEnded(shouldResume: true)
        checks["explicit_pause_survives_late_interruption_end"] = state == .paused
        togglePlaybackContext([entry], title: "Second list", contextID: "second")
        checks["different_list_replaces_origin"] = playbackContextID == "second" && !isPlaybackContextActive("first")
        let second = QueueEntry(id: "queue-second", title: "", artist: "", source: path.path, durationText: "0:20", isLocal: true)
        let third = QueueEntry(id: "queue-third", title: "", artist: "", source: path.path, durationText: "0:20", isLocal: true)
        let list = [entry, second, third]
        setAutomixEnabled(true)
        play(list, at: 1, context: "Automix list", contextID: "automix-list", shuffleRequested: true)
        checks["automix_row_keeps_selected_and_prefix"] = current?.id == second.id && playingIndex == 1 && queue[0].id == entry.id
        play(list, context: "Automix hero", contextID: "automix-hero", shuffleRequested: true, shuffleStart: true)
        checks["automix_overrides_shuffle_seed"] = current?.id == entry.id && playingIndex == 0
        setAutomixEnabled(false)
        play(list, context: "Shuffle list", contextID: "shuffle-list", shuffleRequested: true, shuffleStart: true)
        checks["shuffle_hero_keeps_all_tracks"] = Set(queue.map(\.id)) == Set(list.map(\.id)) && playingIndex == 0
        for _ in 0..<100 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        pausePlayback()
        engineLoadedId = nil
        current = .youtube(videoId: "test-seed01", title: "Seed", artist: "Seed artist")
        queue = [current!]
        playingIndex = 0
        state = .paused
        autoplayEnabled = true
        autoplayRefresh.invalidate()
        var replies: [(String, (String?, String?) -> Void)] = []
        recommendationFetchOverride = { seed, reply in replies.append((seed, reply)) }
        func songs(_ ids: [String]) -> String {
            let rows = ids.map { ["videoId": $0, "title": $0, "artist": "Artist \($0)"] }
            return String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
        maybeAutoplay(lowWaterRefill: true)
        checks["initial_seed_requested"] = replies.count == 1 && replies[0].0 == "test-seed01"
        addToQueue(.youtube(videoId: "manual-song", title: "Manual", artist: "Manual artist"))
        checks["queue_add_does_not_refresh_immediately"] = replies.count == 1
        maybeAutoplay(force: true)
        checks["queue_add_is_used_by_next_refresh"] = replies.count == 2
        replies[0].1(songs(["stale-song"]), nil)
        await settle()
        checks["stale_queue_reply_ignored"] = !queue.contains { $0.id == "stale-song" }
        replies[1].1(songs(["manual-song", "suggestion1", "suggestion1", "suggestion2"]), nil)
        await settle()
        checks["manual_before_deduplicated_tail"] = queue.map(\.id) == ["test-seed01", "manual-song", "suggestion1", "suggestion2"]
        addToQueue(.youtube(videoId: "suggestion1", title: "Picked manually", artist: "Artist"))
        checks["manual_pick_promotes_suggestion"] = queue.map(\.id) == ["test-seed01", "manual-song", "suggestion1", "suggestion2"] && !queue[2].fromAutoplay
        let beforeRemoval = replies.count
        if let removeIndex = queue.firstIndex(where: { $0.id == "suggestion2" }) {
            removeFromQueue(at: removeIndex)
        }
        checks["queue_removal_does_not_refresh_immediately"] = replies.count == beforeRemoval && !queue.contains { $0.id == "suggestion2" }
        let beforeRating = replies.count
        refreshAfterRating(failure: "refused", sessionGeneration: PageSession.generation())
        checks["failed_rating_keeps_tail"] = replies.count == beforeRating && queue.last?.id == "suggestion1"
        refreshAfterRating(failure: nil, sessionGeneration: PageSession.generation())
        checks["successful_rating_refreshes"] = replies.count == beforeRating + 1
        replies.last!.1(songs(["fresh-tail1"]), nil)
        await settle()
        checks["rating_appends_without_replacing_tail"] = queue.map(\.id) == ["test-seed01", "manual-song", "suggestion1", "fresh-tail1"]
        let outgoing = replies.last!

        let threeUpcoming = (0..<3).map {
            QueueEntry.youtube(videoId: "queued-\($0)", title: "Queued \($0)", artist: "Artist")
        }
        queue = [queue[0]] + threeUpcoming
        playingIndex = 0
        current = queue[0]
        let beforeNaturalHandoff = replies.count
        maybeAutoplay(lowWaterRefill: true)
        checks["natural_handoff_does_not_refresh_with_three_upcoming"] = replies.count == beforeNaturalHandoff

        playingIndex = 1; current = queue[1]; playGeneration &+= 1
        maybeAutoplay(lowWaterRefill: true)
        let refillReply = replies.last!
        checks["low_water_refill_uses_current_seed"] = refillReply.0 == "queued-0" && replies.count == beforeNaturalHandoff + 1
        refillReply.1(songs(["queued-1", "low-water-extra"]), nil)
        await settle()
        checks["low_water_refill_appends_and_deduplicates"] = queue.map(\.id) == ["test-seed01", "queued-0", "queued-1", "queued-2", "low-water-extra"]

        playingIndex = 2; current = queue[2]; playGeneration &+= 1
        maybeAutoplay(force: true)
        let nextReply = replies.last!
        checks["manual_next_uses_new_seed"] = nextReply.0 == "queued-1"
        playingIndex = 1; current = queue[1]; playGeneration &+= 1
        maybeAutoplay(force: true)
        checks["manual_previous_uses_selected_seed"] = replies.last!.0 == "queued-0"
        nextReply.1(songs(["stale-next1"]), nil); outgoing.1(songs(["stale-rate1"]), nil)
        await settle()
        checks["stale_selection_reply_ignored"] = !queue.contains { $0.id.hasPrefix("stale-") }
        let pending = replies.last!
        toggleAutoplay()
        pending.1(songs(["disabled001"]), nil)
        await settle()
        checks["disabled_autoplay_rejects_reply"] = !queue.contains { $0.id == "disabled001" }
        recommendationFetchOverride = nil
        // Exercise actual mixer handoffs: repeat stays in the output lane,
        // without tearing down/reloading the engine at the end of each lap.
        autoplayEnabled = false
        repeatMode = .one
        setAutomixEnabled(false)
        play([entry], context: "Repeat validation", contextID: "repeat-validation")
        for _ in 0..<100 { if isPlaying && engineLoadedId == entry.id { break }; try? await Task.sleep(for: .milliseconds(50)) }
        let loopGeneration = playGeneration
        try? engine.setCrossfadeWindow(seconds: 0)
        for lap in 1...2 {
            seek(to: 19)
            for _ in 0..<40 { if engine.positionSeconds() >= 18 { break }; try? await Task.sleep(for: .milliseconds(20)) }
            for _ in 0..<80 { if engine.positionSeconds() < 2 && isPlaying { break }; try? await Task.sleep(for: .milliseconds(50)) }
            checks["repeat_lap_\(lap)_retains_output_and_selection"] = isPlaying && engine.positionSeconds() < 2
                && playGeneration == loopGeneration && current?.id == entry.id && playingIndex == 0
            print("repeat validation lap \(lap): state=\(state) position=\(engine.positionSeconds()) generation=\(playGeneration)/\(loopGeneration) repeat=\(repeatMode) loaded=\(engineLoadedId ?? "nil")")
        }
        // A late/unarmed EOS still reopens the already-local recording.
        nextPreparationTask?.cancel()
        queueNextRevision &+= 1
        loadSubmissionGate.setQueueRevision(queueNextRevision)
        try? engine.queueNextIfCurrent(request: LoadRequest(source: "", title: "", artist: "", startSeconds: 0,
            plan: nil, headers: [:], claimedKbps: 0, loudnessDb: nil, durationSeconds: nil), expectedSource: path.path)
        handleTrackEnded(.natural, source: path.path)
        for _ in 0..<100 { if isPlaying && engineLoadedId == entry.id && playGeneration > loopGeneration { break }; try? await Task.sleep(for: .milliseconds(50)) }
        checks["repeat_unarmed_end_reuses_local_recording"] = isPlaying && loadedSourcePath == path.path && lastError == nil
        repeatMode = .off
        sequencingTask?.cancel()
        try? engine.stop()
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }]
        let report = URL(fileURLWithPath: "/tmp/bitchord-queue-runtime.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        print("QUEUE VALIDATION \(checks)")
        #if os(macOS)
        NSApplication.shared.terminate(nil)
        #endif
    }

    /// Runs only on an explicit validation launch in a separate app container.
    func verifySleepBehavior() async {
        #if os(iOS)
        let token = UIApplication.shared.beginBackgroundTask(withName: "sleep validation")
        defer { UIApplication.shared.endBackgroundTask(token) }
        #endif
        let root = FileManager.default.temporaryDirectory
        let path = root.appendingPathComponent("sleep-validation.wav")
        let rate: UInt32 = 44100, count = 44100 * 16
        func word<T: FixedWidthInteger>(_ value: T) -> Data {
            var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) }
        }
        var audio = Data("RIFF".utf8); audio.append(word(UInt32(36 + count * 4)))
        audio.append(Data("WAVEfmt ".utf8)); audio.append(word(UInt32(16)))
        audio.append(word(UInt16(1))); audio.append(word(UInt16(2))); audio.append(word(rate))
        audio.append(word(rate * 4)); audio.append(word(UInt16(4))); audio.append(word(UInt16(16)))
        audio.append(Data("data".utf8)); audio.append(word(UInt32(count * 4)))
        for frame in 0..<count {
            let value = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(rate)) * 3000)
            audio.append(word(value)); audio.append(word(value))
        }
        var checks: [String: Bool] = [:]
        do {
            try audio.write(to: path)
            let secondPath = root.appendingPathComponent("sleep-second.wav"); try audio.write(to: secondPath)
            volume = 0.03
            setAutomixEnabled(true)
            let first = QueueEntry(id: "sleep-first", title: "Sleep fixture", artist: "Validation", source: path.path, durationText: "0:16", isLocal: true)
            let second = QueueEntry(id: "sleep-second", title: "Second fixture", artist: "Validation", source: secondPath.path, durationText: "0:16", isLocal: true)
            play([first, second])
            for _ in 0..<100 { if isPlaying { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["started_audio"] = isPlaying
            armSleep(seconds: 8)
            try await Task.sleep(for: .seconds(4))
            checks["six_second_fade"] = engine.applicationOutputGain() < targetOutputGain * 0.9
            cancelSleep()
            checks["cancel_restores_volume"] = abs(engine.applicationOutputGain() - targetOutputGain) < 0.0001
            armSleep(seconds: 8)
            try await Task.sleep(for: .seconds(9))
            let stoppedPosition = engine.positionSeconds()
            try await Task.sleep(for: .milliseconds(500))
            #if os(iOS)
            checks["background_deadline"] = UIApplication.shared.applicationState == .background
            #endif
            checks["deadline_pauses"] = state == .paused && abs(engine.positionSeconds() - stoppedPosition) < 0.15
            checks["deadline_restores_volume"] = abs(engine.applicationOutputGain() - targetOutputGain) < 0.0001
            cancelSleep(); setAutomixEnabled(false)
            play([first, second])
            for _ in 0..<100 { if isPlaying { break }; try await Task.sleep(for: .milliseconds(100)) }
            repeatMode = .one; autoplayEnabled = true
            startSleepAfterTrack()
            if let source = loadedSourcePath {
                try engine.setPlaybackRegions(source: source, regions: PlaybackRegions(audibleStartSeconds: 0, audibleEndSeconds: 2, excluded: []))
            }
            try await Task.sleep(for: .seconds(4))
            checks["after_song_blocks_repeat_autoplay_next"] = state == .paused && current?.id == first.id
        } catch { debugLog.record("sleep validation error: \(error)"); checks["runtime_error"] = false }
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }, "snapshot": PlaybackDebugLog.sanitize(diagnosticSnapshot)]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sleep-validation.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        print("SLEEP VALIDATION \(checks)")
        debugLog.record("sleep validation \(checks)")
    }
}
#endif

#if DEBUG && os(iOS)
extension PlaybackController {
    func verifyDolbyQueue() async {
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedVolume = volume
        let sampleURL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/Job932393e2-1e4f-4fdb-ab59-0d201f752656-107660254-Transcode_audio_full_en_atmos_0_1-en_audio/prog_index.m3u8"
        var checks: [String: Bool] = [:]
        defer {
            pausePlayback()
            dolbyRenderer?.stop(); dolbyRenderer = nil
            volume = savedVolume
            if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
            else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
            PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
            restoreSession()
        }
        volume = 0
        let entries = (0..<2).map { QueueEntry(id: "dolby-test-\($0)", title: "Dolby validation \($0)", artist: "Apple", source: "dolby-test:" + sampleURL, durationText: "", isLocal: false) }
        play(entries)
        for _ in 0..<150 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(2))
        checks["first_dolby_playing"] = isPlaying && dolbyRenderer != nil && position > 0.5
        togglePlayPause()
        let paused = playbackPosition
        try? await Task.sleep(for: .seconds(1))
        checks["pause_stable"] = state == .paused && abs(playbackPosition - paused) < 0.1
        togglePlayPause()
        try? await Task.sleep(for: .seconds(2))
        checks["resume_progress"] = isPlaying && playbackPosition > paused + 0.5
        next()
        for _ in 0..<150 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        checks["next_dolby"] = current?.id == entries[1].id && isPlaying && dolbyRenderer != nil
        seek(to: 0); previous()
        for _ in 0..<150 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        checks["back_dolby"] = current?.id == entries[0].id && isPlaying && dolbyRenderer != nil
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }, "codec": nerd?.codec ?? "", "error": lastError ?? ""]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dolby-queue-verification.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        NSLog("[BitChord] Dolby queue verification complete: %@", String(describing: checks))
    }
}
#endif
