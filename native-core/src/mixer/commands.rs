//! The engine's commands, applied on the mixer thread.

use super::state::{MixerState, Phase};
use super::types::Command;
use super::voice::Voice;
use super::{accepts_analyzed_plan, loudness_gain, NerdSnapshot, QueuedTrack, TransitionStyle};
use crate::eq::EqCurve;
use crate::sound::{LoudnessMode, Protector, SoundMode};
use rtrb::Producer;
use std::sync::atomic::Ordering;

pub(super) fn handle_command(state: &mut MixerState, cmd: Command, ring: &mut Producer<f32>) {
    match cmd {
        Command::ForSource { source, command } => {
            let handed_off = state.transition.as_ref().is_some_and(|t| t.handed_off);
            let voice = if handed_off {
                state.incoming.as_ref().or(state.current.as_ref())
            } else {
                state.current.as_ref()
            };
            if voice.is_some_and(|voice| voice.info.source == source) {
                handle_command(state, *command, ring);
            } else if let Command::SwapSource { reply, .. } = *command {
                let _ = reply.send(Err("source swap belongs to a superseded track".into()));
            }
        }
        Command::Load { request, reply } => {
            // Upstream: a skip/replace is not a blend. `onSkipRequested` bails
            // and `setMediaItems` replaces the session playlist; the spare is
            // `stop()`+`clearMediaItems()`. Mixing the old voice under the new
            // one reads as the tap being ignored.
            state.hard_cut();
            match Voice::open(
                &request,
                state.spatial_enabled && state.sound_mode == SoundMode::Enhanced,
                state.head_yaw,
                state.device_rate,
                state.playback_speed,
                state.skip_silence && state.sound_mode == SoundMode::Enhanced,
                true,
            ) {
                Ok(mut voice) => {
                    voice.normalization_mode = state.loudness_mode;
                    // A fresh track must enter at its selected level, rather
                    // than spend its first 50 ms driving an unneeded limiter.
                    voice.arm_transition_match(None, state.loudness_enabled);
                    voice.bit_perfect = state.bit_perfect
                        && crate::output::is_lossless_pcm_codec(&voice.info.codec)
                        && voice.info.sample_rate == state.device_rate
                        && matches!(voice.info.bit_depth, 16 | 24)
                        && voice.info.channels == 2;
                    let info = voice.info.clone();
                    let duration = voice.info.duration_seconds;
                    let (_, gain_db) = loudness_gain(voice.loudness_db, state.loudness_enabled);
                    if let Ok(mut nerd) = state.nerd.lock() {
                        *nerd = NerdSnapshot {
                            codec: info.codec.clone(),
                            sample_rate: info.sample_rate,
                            bit_depth: info.bit_depth,
                            channels: info.channels,
                            kbps: info.kbps,
                            loudness_gain_db: gain_db,
                            // A new track clears the previous swap's figure.
                            swap_correlation: None,
                            ..NerdSnapshot::default()
                        };
                    }
                    state.current = Some(voice);
                    state.playing = true;
                    state.position_ms.store(0, Ordering::Relaxed);
                    state
                        .duration_ms
                        .store((duration * 1000.0) as u64, Ordering::Relaxed);
                    state.set_state(crate::PlaybackState::Playing);
                    if duration > 0.0 {
                        state.events.duration_changed(duration);
                    }
                    let _ = reply.send(Ok(info));
                }
                Err(e) => {
                    state.set_state(crate::PlaybackState::Stopped);
                    let _ = reply.send(Err(e));
                }
            }
        }
        Command::SwapSource {
            request,
            crossfade_seconds,
            reply,
        } => match state.swap_source(request, crossfade_seconds) {
            Ok(info) => {
                let _ = reply.send(Ok(info));
            }
            Err(e) => {
                let _ = reply.send(Err(e));
            }
        },
        Command::QueueNext { mut request } => {
            if let Some(current) = &state.current {
                request.plan = crate::playback_regions::constrain(
                    request.plan.into(),
                    current.regions.clone(),
                    crate::playback_regions::get(&request.source),
                    current.info.duration_seconds,
                    request.duration_seconds,
                )
                .into();
                request.start_seconds = request.plan.cue_seconds;
            }
            if state.bit_perfect || state.hold_end {
                return;
            }
            if request.source.is_empty() {
                state.pending_next = None;
                if state
                    .transition
                    .as_ref()
                    .is_some_and(|t| t.phase == Phase::Arming && !t.swap)
                {
                    state.transition = None;
                    state.incoming = None;
                }
            } else if state
                .current
                .as_ref()
                .is_some_and(|c| c.info.source == request.source)
            {
                // Same path as the playing voice is normally a duplicate and is
                // dropped. An explicit gapless plan is a non-Automix loop;
                // a planned fade is an Automix self-mix. Both need a second
                // reader so the output survives EOS without a fresh load.
                if request.plan.fade_seconds > 0.0 || request.plan.style == TransitionStyle::Gapless
                {
                    log::info!(
                        "queued self-mix for {} fade={:.1}s",
                        request.title,
                        request.plan.fade_seconds
                    );
                    state.pending_next = Some(request);
                } else {
                    log::debug!("queueNext ignored; already current");
                }
            } else if state
                .incoming
                .as_ref()
                .is_some_and(|c| c.info.source == request.source)
            {
                // The early overlap can arm before analysis finishes. Replacing
                // it once the fade has started would replay this song after the
                // handoff; replacing the plan while it is still waiting moves
                // the blend to where the analysis said it should be.
                state.upgrade_armed_plan(request);
            } else if state
                .transition
                .as_ref()
                .is_some_and(|transition| transition.phase == Phase::Arming && !transition.swap)
            {
                // Not audible yet. A better encode of the incoming record, or a
                // queue change, replaces the armed voice. Doing this once the
                // fade is sounding would cut the blend.
                state.retarget_armed_source(request);
            } else if state.incoming.as_ref().is_some_and(|incoming| {
                incoming.info.title == request.title && incoming.info.artist == request.artist
            }) {
                log::info!("held a same-song source change; the blend is already audible");
            } else {
                state.pending_next = Some(request);
            }
        }
        Command::PendingTrack { reply } => {
            let queued = state
                .pending_next
                .as_ref()
                .map(|request| QueuedTrack {
                    title: request.title.clone(),
                    artist: request.artist.clone(),
                    source: request.source.clone(),
                })
                .or_else(|| {
                    state.incoming.as_ref().map(|voice| QueuedTrack {
                        title: voice.info.title.clone(),
                        artist: voice.info.artist.clone(),
                        source: voice.info.source.clone(),
                    })
                });
            let _ = reply.send(queued);
        }
        Command::SkipToPending {
            skip_mix_enabled,
            reply,
        } => {
            // The upgrade candidate is not the next song and has not passed correlation yet.
            state.reject_pending_swap();
            // A blend already sounding completes now: the listener asked for
            // its target, not for the rest of the fade.
            if state.incoming.is_some() {
                let info = state.incoming.as_ref().map(|voice| voice.info.clone());
                let arming_skip = skip_mix_enabled
                    && state.transition.as_ref().is_some_and(|transition| {
                        accepts_analyzed_plan(transition.phase, transition.swap)
                    });
                let skip_mix = if arming_skip {
                    state.begin_skip_mix()
                } else {
                    None
                };
                if let Some(info) = skip_mix {
                    state.consider_start_fade();
                    let _ = reply.send(Ok(info));
                } else {
                    state.promote_incoming();
                    state.position_ms.store(0, Ordering::Relaxed);
                    if !state.playing {
                        state.playing = true;
                        state.set_state(crate::PlaybackState::Playing);
                    }
                    match info {
                        Some(info) => {
                            log::info!("skip promoted blending {}", info.title);
                            let _ = reply.send(Ok(info));
                        }
                        None => {
                            let _ = reply.send(Err("nothing to skip to".into()));
                        }
                    }
                }
            } else if let Some(request) = state.pending_next.take() {
                let title = request.title.clone();
                match Voice::open(
                    &request,
                    state.spatial_enabled && state.sound_mode == SoundMode::Enhanced,
                    state.head_yaw,
                    state.device_rate,
                    state.playback_speed,
                    state.skip_silence && state.sound_mode == SoundMode::Enhanced,
                    true,
                ) {
                    Ok(mut voice) => {
                        voice.normalization_mode = state.loudness_mode;
                        voice.arm_transition_match(None, state.loudness_enabled);
                        // Same landing as a Load: ramp out the backlog, drop
                        // every straggler, start the new voice at the top.
                        state.hard_cut();
                        voice.gain = 1.0;
                        voice.release_plan_stretch(state.playback_speed, state.device_rate);
                        let info = voice.info.clone();
                        let duration = info.duration_seconds;
                        let (_, gain_db) = loudness_gain(voice.loudness_db, state.loudness_enabled);
                        if let Ok(mut nerd) = state.nerd.lock() {
                            *nerd = NerdSnapshot {
                                codec: info.codec.clone(),
                                sample_rate: info.sample_rate,
                                bit_depth: info.bit_depth,
                                channels: info.channels,
                                kbps: info.kbps,
                                loudness_gain_db: gain_db,
                                swap_correlation: None,
                                ..NerdSnapshot::default()
                            };
                        }
                        state.current = Some(voice);
                        state.playing = true;
                        state.set_state(crate::PlaybackState::Playing);
                        state.position_ms.store(0, Ordering::Relaxed);
                        state
                            .duration_ms
                            .store((duration * 1000.0) as u64, Ordering::Relaxed);
                        if duration > 0.0 {
                            state.events.duration_changed(duration);
                        }
                        state.publish_audible_position();
                        state.events.handoff(info.clone());
                        log::info!("skip promoted queued {}", info.title);
                        let _ = reply.send(Ok(info));
                    }
                    Err(error) => {
                        // The track is not lost: put the request back so the
                        // planned blend (or a retry) still finds it.
                        state.pending_next = Some(request);
                        log::warn!("skip could not open {title}: {error}");
                        let _ = reply.send(Err(error));
                    }
                }
            } else {
                let _ = reply.send(Err("nothing queued to skip to".into()));
            }
        }
        Command::Play => {
            if state.current.is_some() {
                state.playing = true;
                state.set_state(crate::PlaybackState::Playing);
            }
        }
        Command::Pause => {
            // Silence the DAC immediately (output_paused) but keep the
            // already-mixed ring: those samples are the playhead. Flushing
            // them made pause snappy and resume skip ahead by ~2 s.
            state.publish_audible_position();
            state.playing = false;
            state.set_state(crate::PlaybackState::Paused);
        }
        Command::Stop => {
            state.stop_all();
        }
        Command::Seek { seconds } => {
            if state.transition.is_some() {
                state.bail();
            }
            match &mut state.current {
                Some(voice) => {
                    let r = voice.decoder.seek_seconds(seconds);
                    match r {
                        Ok(()) => {
                            voice.base_position = 0.0;
                            voice.reset_processing();
                            voice.head_trim_allowed = false;
                            for (i, s) in voice.regions.excluded.iter().enumerate() {
                                if seconds >= s.start_seconds && seconds < s.end_seconds {
                                    voice.skipped_regions[i] = true;
                                }
                            }
                            state.eq.flush();
                            state.clarity.reset();
                            state.protector.reset();
                            state.pipeline_tail_frames = 0;
                            state.flush_ring.store(true, Ordering::Release);
                            state.buffered_frames.store(0, Ordering::Relaxed);
                            state
                                .position_ms
                                .store((seconds * 1000.0) as u64, Ordering::Relaxed);
                        }
                        Err(e) => {
                            state.events.error(format!("seek failed: {e}"));
                        }
                    }
                }
                None => {
                    state.events.error("seek ignored — nothing playing".into());
                }
            }
        }
        Command::SetPlaybackRegions { source, regions } => {
            for voice in state.current.iter_mut().chain(state.incoming.iter_mut()) {
                if voice.info.source == source {
                    let regions = regions.clone().normalized(voice.info.duration_seconds);
                    voice.skipped_regions = regions
                        .excluded
                        .iter()
                        .map(|s| {
                            voice
                                .regions
                                .excluded
                                .iter()
                                .position(|old| {
                                    old.start_seconds == s.start_seconds
                                        && old.end_seconds == s.end_seconds
                                })
                                .map(|i| voice.skipped_regions[i])
                                .unwrap_or(false)
                        })
                        .collect();
                    voice.regions = regions;
                }
            }
            if let (Some(current), Some(next)) = (&state.current, &mut state.pending_next) {
                next.plan = crate::playback_regions::constrain(
                    next.plan.clone().into(),
                    current.regions.clone(),
                    crate::playback_regions::get(&next.source),
                    current.info.duration_seconds,
                    next.duration_seconds,
                )
                .into();
                next.start_seconds = next.plan.cue_seconds;
            }
            if let (Some(current), Some(incoming), Some(transition)) =
                (&state.current, &mut state.incoming, &mut state.transition)
            {
                if !transition.swap && transition.phase == Phase::Arming {
                    transition.plan = crate::playback_regions::constrain(
                        transition.plan.clone().into(),
                        current.regions.clone(),
                        incoming.regions.clone(),
                        current.info.duration_seconds,
                        incoming.info.duration_seconds,
                    )
                    .into();
                    transition.fade_frames =
                        (transition.plan.fade_seconds * state.device_rate as f64) as u64;
                    let cue = incoming.regions.next_allowed(transition.plan.cue_seconds);
                    if incoming.decoder.seek_seconds(cue).is_ok() {
                        incoming.reset_processing();
                    }
                }
            }
        }
        Command::SetSleepGain(gain) => {
            state.sleep_gain = if gain.is_finite() {
                gain.clamp(0.0, 1.0)
            } else {
                1.0
            }
        }
        Command::HoldTrackEnd(hold) => {
            state.hold_end = hold;
            if hold {
                if state.transition.as_ref().is_some_and(|t| t.handed_off) {
                    state.current = state.incoming.take();
                    if let Some(voice) = &mut state.current {
                        voice.release_transition_match();
                    }
                }
                state.pending_next = None;
                state.incoming = None;
                state.transition = None;
                if let Some(voice) = &mut state.current {
                    voice.gain = 1.0;
                }
            }
        }
        Command::SetVolume(v) => state.volume = v.clamp(0.0, 1.0),
        Command::SetBitPerfect(enabled) => {
            state.bit_perfect = enabled;
            if enabled {
                state.transition = None;
                state.incoming = None;
                state.pending_next = None;
                state.retiring.clear();
                state.bail_flush.store(false, Ordering::Release);
                state.flush_ring.store(true, Ordering::Release);
            }
            if let Some(current) = &mut state.current {
                current.bit_perfect = enabled;
            }
        }
        Command::SetCrossfadeWindow(s) => state.crossfade_window_s = s.max(0.0),
        Command::CancelAutomixProcessing => {
            // An in-place quality upgrade is not an Automix transition.
            if state.transition.as_ref().is_some_and(|t| !t.swap) {
                state.bail();
            }
            state.pending_next = None;
            for voice in state
                .current
                .iter_mut()
                .chain(state.incoming.iter_mut())
                .chain(state.retiring.iter_mut().map(|r| &mut r.voice))
            {
                voice.release_plan_stretch(state.playback_speed, state.device_rate);
                voice.release_transition_match();
                voice.filter.open();
            }
        }
        Command::SetSpatial(enabled) => {
            state.spatial_enabled = enabled;
            if let Some(current) = &mut state.current {
                current
                    .spatial
                    .set_enabled(enabled && state.sound_mode == SoundMode::Enhanced);
            }
            if let Some(incoming) = &mut state.incoming {
                incoming
                    .spatial
                    .set_enabled(enabled && state.sound_mode == SoundMode::Enhanced);
            }
        }
        Command::SetHeadYaw(yaw) => {
            state.head_yaw = yaw;
            if let Some(current) = &mut state.current {
                current.spatial.set_head_yaw(yaw);
            }
            if let Some(incoming) = &mut state.incoming {
                incoming.spatial.set_head_yaw(yaw);
            }
        }
        Command::SetVoiceFilter {
            incoming,
            low_hz,
            high_hz,
        } => {
            let target = if incoming {
                state.incoming.as_mut()
            } else {
                state.current.as_mut()
            };
            if let Some(voice) = target {
                voice.filter.set_cutoffs(low_hz, high_hz);
            }
        }
        Command::OpenFilters => {
            if let Some(current) = &mut state.current {
                current.filter.open();
            }
            if let Some(incoming) = &mut state.incoming {
                incoming.filter.open();
            }
        }
        Command::SetPlaybackSpeed(speed) => {
            state.playback_speed = speed.clamp(0.5, 2.0);
            if let Some(v) = &mut state.current {
                v.set_playback_speed(state.playback_speed, state.device_rate);
            }
            if let Some(v) = &mut state.incoming {
                v.set_playback_speed(state.playback_speed, state.device_rate);
            }
        }
        Command::SetSkipSilence(enabled) => {
            state.skip_silence = enabled;
            if let Some(v) = &mut state.current {
                v.skip_silence = enabled && state.sound_mode == SoundMode::Enhanced;
            }
            if let Some(v) = &mut state.incoming {
                v.skip_silence = enabled && state.sound_mode == SoundMode::Enhanced;
            }
        }
        Command::ObserveUnderruns(counter) => {
            state.observed_underruns = counter.load(Ordering::Relaxed);
            state.underrun_counter = Some(counter);
        }
        Command::SetDecodeChunk(frames) => crate::diagnostics::set_chunk(frames),
        Command::SetPreferAppleAac(value) => crate::diagnostics::set_prefer_apple_aac(value),
        Command::StartDiagnosticCapture { directory, seconds } => {
            if let Err(e) = crate::diagnostics::start(directory, seconds, state.device_rate) {
                state.events.error(e);
            } else if let Some(v) = state.current.as_ref() {
                crate::diagnostics::source(&v.info.source, v.info.sample_rate);
            }
        }
        Command::FinishDiagnosticCapture { reply } => {
            let settings = state.diagnostic_settings();
            let snapshot = state.nerd.lock().unwrap().clone();
            let events = state.events.clone();
            crate::diagnostics::finish(snapshot, settings, move |result| {
                if let Err(e) = &result {
                    events.error(e.clone());
                }
                if let Some(reply) = reply {
                    let _ = reply.send(result);
                }
            });
        }
        Command::SetSoundMode(mode) => {
            state.sound_mode = mode;
            state.clarity.set(mode, state.clarity_tuning.clone());
            state.protector.reset();
            state.eq.flush();
            state.pipeline_tail_frames = 0;
            if let Some(v) = state.current.as_mut() {
                let position = state.position_ms.load(Ordering::Relaxed) as f64 / 1000.0;
                if let Err(e) = v.decoder.seek_seconds(position) {
                    state.events.error(format!("sound mode seek: {e}"));
                }
                v.reset_processing();
                state.bail_flush.store(true, Ordering::Release);
            }
            for voice in state.current.iter_mut().chain(state.incoming.iter_mut()) {
                voice.spatial.set_enabled(
                    mode == SoundMode::Enhanced
                        && state.spatial_enabled
                        && voice.info.channels >= 2,
                );
                voice.skip_silence = mode == SoundMode::Enhanced && state.skip_silence;
            }
        }
        Command::SetClarityTuning(tuning) => {
            state.clarity_tuning = tuning.clone();
            state.clarity.set(state.sound_mode, tuning);
        }
        Command::SetLoudnessMeasurement(m) => {
            if let Some(v) = state.current.as_mut() {
                v.measured_loudness = Some(m);
            }
        }
        Command::SetLoudnessMode(mode) => {
            state.loudness_mode = mode;
            state.loudness_enabled = mode != LoudnessMode::Off;
        }
        Command::SetLoudnessEnabled(enabled) => {
            state.loudness_enabled = enabled;
            state.loudness_mode = if enabled {
                LoudnessMode::Track
            } else {
                LoudnessMode::Off
            };
            // The readout follows the switch without a reload: the gain each
            // voice *would* apply is recomputed for the one that is audible.
            if let Some(current) = &state.current {
                let info = current.info.clone();
                let db = current.loudness_db;
                state.publish_nerd(&info, db);
            }
        }
        Command::SetEqTuning {
            enabled,
            gains_db,
            qs,
            preamp_db,
            balance,
        } => {
            state.eq.set_tuning(
                enabled,
                &EqCurve {
                    gains_db,
                    qs,
                    preamp_db,
                },
                balance,
            );
        }
        Command::SetOutputFormat {
            rate,
            producer,
            generation,
            acknowledged,
        } => {
            if generation < state.output_generation {
                if let Some(reply) = acknowledged {
                    let _ = reply.send(false);
                }
                return;
            }
            state.output_generation = generation;

            *ring = producer;
            let rate = rate.max(1);
            if rate != state.device_rate {
                log::info!("output format {} Hz -> {rate} Hz", state.device_rate);
                state.device_rate = rate;
                state.eq.retarget(rate, 2);
                state.clarity.retarget(rate);
                state.protector = Protector::new(rate);
                let spatial = state.spatial_enabled;
                let yaw = state.head_yaw;
                if let Some(v) = &mut state.current {
                    v.retarget_device(rate, spatial, yaw);
                }
                if let Some(v) = &mut state.incoming {
                    v.retarget_device(rate, spatial, yaw);
                }
                for ret in &mut state.retiring {
                    ret.voice.retarget_device(rate, spatial, yaw);
                }
            }
            // The ring we just abandoned held everything between the playhead
            // and the decoder's read head, and it is gone — nothing drained it,
            // because the unit it fed is the one being replaced. Re-point the
            // voice at the playhead so the song continues where the listener
            // was, instead of silently skipping the whole ring depth, which is
            // seconds of music, the moment the output route changes.
            let resume_s = state.position_ms.load(Ordering::Relaxed) as f64 / 1000.0;
            // Zero is a valid playhead: a muted freshly loaded voice may
            // already have decoded the entire short track into the old ring.
            if let Some(voice) = &mut state.current {
                match voice.decoder.seek_seconds(resume_s) {
                    Ok(()) => {
                        voice.base_position = 0.0;
                        voice.reset_processing();
                        state.eq.flush();
                        state.clarity.reset();
                        state.protector.reset();
                        state.pipeline_tail_frames = 0;
                        log::info!("output changed; resuming at {resume_s:.3}s");
                    }
                    Err(e) => log::warn!("re-seek after output change failed: {e}"),
                }
            }
            state.flush_ring.store(true, Ordering::Release);
            state.buffered_frames.store(0, Ordering::Relaxed);
            if let Some(reply) = acknowledged {
                let _ = reply.send(true);
            }
        }
        Command::Shutdown => {
            state.stop_all();
        }
    }
    if crate::diagnostics::enabled() {
        crate::diagnostics::record_settings(state.diagnostic_settings());
    }
}
