//! Handing the playhead to the incoming: gapless queues, seeks, tempo glides.

use super::*;

#[test]
fn disabling_automix_releases_its_processing_but_keeps_user_speed() {
    let path =
        std::env::temp_dir().join(format!("bitchord-automix-off-{}.wav", std::process::id()));
    test_wav(&path, 6.0, 440.0);
    let mut state = armed_test_state(&path, &path, Phase::Arming);
    state.transition = None;
    state.incoming = None;
    state.playback_speed = 1.25;
    let voice = state.current.as_mut().unwrap();
    voice.set_playback_speed(1.25, 44_100);
    voice.base_plan_rate = 1.03;
    voice.post_glide_seconds = 8.0;
    voice.begin_tempo_glide(44_100);
    voice.filter.set_cutoffs(1_000.0, 200.0);
    voice.match_db = 2.0;
    let (mut producer, _) = rtrb::RingBuffer::new(4096);
    super::super::commands::handle_command(
        &mut state,
        Command::CancelAutomixProcessing,
        &mut producer,
    );
    let voice = state.current.as_mut().unwrap();
    assert_eq!(voice.glide_total_frames, 0);
    assert_eq!(voice.match_db, 0.0);
    assert_eq!(
        voice.filter.target_high_pass_hz(),
        crate::transition_filter::TransitionFilter::off_hz()
    );
    for _ in 0..20 {
        voice.pull(512, 44_100);
    }
    assert!(voice.stretch.is_none());
    assert_eq!(voice.user_stretch.as_ref().unwrap().rate(), 1.25);
    drop(state);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn disabling_automix_preserves_a_pending_quality_swap() {
    let path = std::env::temp_dir().join(format!(
        "bitchord-automix-off-swap-{}.wav",
        std::process::id()
    ));
    test_wav(&path, 2.0, 440.0);
    let mut state = armed_test_state(&path, &path, Phase::Fading);
    state.transition.as_mut().unwrap().swap = true;
    let (mut producer, _) = rtrb::RingBuffer::new(4096);
    super::super::commands::handle_command(
        &mut state,
        Command::CancelAutomixProcessing,
        &mut producer,
    );
    assert!(state.transition.as_ref().unwrap().swap);
    assert!(state.incoming.is_some());
    drop(state);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn a_unity_plan_replaces_the_armed_stretcher_and_cannot_leak_into_the_song() {
    let path =
        std::env::temp_dir().join(format!("bitchord-unity-replan-{}.wav", std::process::id()));
    test_wav(&path, 6.0, 440.0);
    let mut state = armed_test_state(&path, &path, Phase::Arming);
    let voice = state.incoming.as_mut().unwrap();
    voice.base_plan_rate = 1.03;
    voice.set_plan_rate(1.03);
    voice.prime_for_fade(2048, 44_100);
    assert!(voice.stretch.is_some());
    // A later cue can coincide with the decoder head. A rate change still
    // requires re-priming: the pending PCM was rendered with the old plan.
    let cue = voice.decoder.position_seconds();
    state.upgrade_armed_plan(TrackSource {
        source: path.display().to_string(),
        title: "replacement plan".into(),
        artist: String::new(),
        start_seconds: cue,
        plan: TransitionPlan {
            playback_rate: 1.0,
            fade_seconds: 1.0,
            ..TransitionPlan::default()
        },
        headers: Default::default(),
        claimed_kbps: 0,
        loudness_db: None,
        duration_seconds: 6.0,
    });
    state.start_fade();
    state.finish_transition();
    let voice = state.current.as_mut().unwrap();
    for _ in 0..20 {
        voice.pull(512, 44_100);
    }
    assert!(
        voice.stretch.is_none(),
        "A stale stretcher survived the completed unity-rate transition"
    );
    assert_eq!(voice.plan_rate, 1.0);
    drop(state);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn releasing_tempo_processing_keeps_every_pending_decoded_frame() {
    let path = std::env::temp_dir().join(format!(
        "bitchord-stretch-backlog-{}.wav",
        std::process::id()
    ));
    test_wav(&path, 2.0, 440.0);
    let mut state = armed_test_state(&path, &path, Phase::Arming);
    let voice = state.current.as_mut().unwrap();
    voice.set_plan_rate(1.03);
    let input = vec![0.3; 16000];
    voice.stretch.as_mut().unwrap().process(&input);
    voice.stretch.as_mut().unwrap().take();
    voice.pending_dev = vec![0.11, 0.11, 0.22, 0.22, 0.33, 0.33, 0.44, 0.44];
    voice.pending_dev_cursor = 0;
    voice.release_plan_stretch(1.0, 44_100);
    assert_eq!(voice.pull(2, 44_100), vec![0.11, 0.11, 0.22, 0.22]);
    assert_eq!(
        voice.pull(2, 44_100),
        vec![0.33, 0.33, 0.44, 0.44],
        "Draining the stretcher overwrote decoded audio still waiting to play"
    );
    for _ in 0..20 {
        voice.pull(512, 44_100);
    }
    assert!(voice.stretch.is_none());
    drop(state);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn gapless_queue_advances_and_fires_handoff() {
    let dir = std::env::temp_dir().join("bitchord-mixer-test");
    std::fs::create_dir_all(&dir).unwrap();
    let a = dir.join("a.wav");
    let b = dir.join("b.wav");
    test_wav(&a, 1.0, 440.0);
    test_wav(&b, 1.0, 660.0);

    let events = std::sync::Arc::new(RecordedEvents::default());
    let (tx, rx) = crossbeam_channel::unbounded::<Command>();
    let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
    let buffered = std::sync::Arc::new(AtomicU64::new(0));
    let position = std::sync::Arc::new(AtomicU64::new(0));
    let duration = std::sync::Arc::new(AtomicU64::new(0));
    let shutdown = std::sync::Arc::new(AtomicBool::new(false));

    let handle = std::thread::spawn({
        let events = events.clone();
        let buffered = buffered.clone();
        let position = position.clone();
        let duration = duration.clone();
        let shutdown = shutdown.clone();
        move || {
            run_mixer(
                rx,
                consumer_side,
                buffered,
                position,
                duration,
                44_100,
                events,
                shutdown,
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
            )
        }
    });

    tx.send(Command::Load {
        request: TrackSource {
            source: a.display().to_string(),
            title: "A".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan::default(),
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        },
        reply: crossbeam_channel::bounded(1).0,
    })
    .unwrap();
    tx.send(Command::QueueNext {
        request: TrackSource {
            source: b.display().to_string(),
            title: "B".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan::default(),
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        },
    })
    .unwrap();

    // Drain the ring the way the device callback would, saturating the
    // shared counter (regression: a plain fetch_sub wrapped u64 and
    // wedged every tail computation — no handoff ever fired).
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        while let Ok(_) = consumer.pop() {
            let mut current = buffered.load(Ordering::Relaxed);
            while current > 0 {
                match buffered.compare_exchange_weak(
                    current,
                    current - 1,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => break,
                    Err(v) => current = v,
                }
            }
        }
        let handoffs = events.handoffs.lock().unwrap();
        if !handoffs.is_empty() || std::time::Instant::now() > deadline {
            break;
        }
        drop(handoffs);
        std::thread::sleep(std::time::Duration::from_millis(5));
    }

    let handoffs = events.handoffs.lock().unwrap().clone();
    assert_eq!(handoffs, vec!["B".to_string()], "handoff to B must fire");

    shutdown.store(true, Ordering::Relaxed);
    let _ = handle.join();
}

/// Repeat-one / single-item repeat-all with Automix: the same file must be
/// accepted as pending-next when it carries a fade, so the track can blend
/// into itself instead of stopping at EOS.
#[test]
fn a_planned_self_mix_is_accepted_and_hands_off() {
    check_self_handoff(false);
}

#[test]
fn an_explicit_gapless_repeat_is_accepted_and_hands_off() {
    check_self_handoff(true);
}

fn check_self_handoff(gapless: bool) {
    let dir = std::env::temp_dir().join(format!("bitchord-mixer-self-mix-{gapless}"));
    std::fs::create_dir_all(&dir).unwrap();
    let a = dir.join("loop.wav");
    test_wav(&a, 3.0, 440.0);

    let events = std::sync::Arc::new(RecordedEvents::default());
    let (tx, rx) = crossbeam_channel::unbounded::<Command>();
    let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 4);
    let buffered = std::sync::Arc::new(AtomicU64::new(0));
    let position = std::sync::Arc::new(AtomicU64::new(0));
    let duration = std::sync::Arc::new(AtomicU64::new(0));
    let shutdown = std::sync::Arc::new(AtomicBool::new(false));

    let handle = std::thread::spawn({
        let events = events.clone();
        let buffered = buffered.clone();
        let position = position.clone();
        let duration = duration.clone();
        let shutdown = shutdown.clone();
        move || {
            run_mixer(
                rx,
                consumer_side,
                buffered,
                position,
                duration,
                44_100,
                events,
                shutdown,
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
            )
        }
    });

    let path = a.display().to_string();
    tx.send(Command::Load {
        request: TrackSource {
            source: path.clone(),
            title: "Loop".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan::default(),
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 3.0,
        },
        reply: crossbeam_channel::bounded(1).0,
    })
    .unwrap();
    tx.send(Command::QueueNext {
        request: TrackSource {
            source: path,
            title: "Loop".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan {
                style: if gapless {
                    TransitionStyle::Gapless
                } else {
                    TransitionStyle::EqualPower
                },
                fade_seconds: if gapless { 0.0 } else { 1.0 },
                effect_seconds: 0.0,
                effect_start_seconds: 0.0,
                ..TransitionPlan::default()
            },
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 3.0,
        },
    })
    .unwrap();

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        while let Ok(_) = consumer.pop() {
            let mut current = buffered.load(Ordering::Relaxed);
            while current > 0 {
                match buffered.compare_exchange_weak(
                    current,
                    current - 1,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => break,
                    Err(v) => current = v,
                }
            }
        }
        let handoffs = events.handoffs.lock().unwrap();
        if !handoffs.is_empty() || std::time::Instant::now() > deadline {
            break;
        }
        drop(handoffs);
        std::thread::sleep(std::time::Duration::from_millis(5));
    }

    let handoffs = events.handoffs.lock().unwrap().clone();
    let ended = events.ended.lock().unwrap().clone();
    assert_eq!(
        handoffs,
        vec!["Loop".to_string()],
        "self-mix must hand off into the same title, not drain: ended={ended:?}"
    );

    shutdown.store(true, Ordering::Relaxed);
    let _ = handle.join();
}

#[test]
fn load_pushes_current_voice_into_the_ring() {
    let dir = std::env::temp_dir().join("bitchord-mixer-current");
    std::fs::create_dir_all(&dir).unwrap();
    let a = dir.join("solo.wav");
    test_wav(&a, 0.5, 440.0);

    let events = std::sync::Arc::new(RecordedEvents::default());
    let (tx, rx) = crossbeam_channel::unbounded::<Command>();
    let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
    let buffered = std::sync::Arc::new(AtomicU64::new(0));
    let position = std::sync::Arc::new(AtomicU64::new(0));
    let duration = std::sync::Arc::new(AtomicU64::new(0));
    let shutdown = std::sync::Arc::new(AtomicBool::new(false));

    let handle = std::thread::spawn({
        let events = events.clone();
        let buffered = buffered.clone();
        let position = position.clone();
        let duration = duration.clone();
        let shutdown = shutdown.clone();
        move || {
            run_mixer(
                rx,
                consumer_side,
                buffered,
                position,
                duration,
                44_100,
                events,
                shutdown,
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
            )
        }
    });

    tx.send(Command::Load {
        request: TrackSource {
            source: a.display().to_string(),
            title: "solo".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan::default(),
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        },
        reply: crossbeam_channel::bounded(1).0,
    })
    .unwrap();

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    let mut samples = 0usize;
    while std::time::Instant::now() < deadline && samples == 0 {
        while consumer.pop().is_ok() {
            samples += 1;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert!(
        samples > 0,
        "current voice must reach the ring (got {samples})"
    );

    shutdown.store(true, Ordering::Relaxed);
    let _ = handle.join();
}

#[test]
fn cold_resume_seek_at_180_seconds_outputs_pcm_from_that_position() {
    // A seekable source must start directly at the requested timestamp:
    // restoring a saved playhead must not decode 180 seconds of audio, and
    // the first ring samples must contain the signal at that position.
    let a = std::env::temp_dir().join(format!("bitchord-mixer-resume-{}.wav", std::process::id()));
    test_wav(&a, 190.0, 997.0);

    let events = Arc::new(RecordedEvents::default());
    let (tx, rx) = crossbeam_channel::unbounded::<Command>();
    let (producer, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 2);
    let buffered = Arc::new(AtomicU64::new(0));
    let position = Arc::new(AtomicU64::new(0));
    let duration = Arc::new(AtomicU64::new(0));
    let shutdown = Arc::new(AtomicBool::new(false));
    let handle = std::thread::spawn({
        let (events, buffered, position, duration, shutdown) = (
            events.clone(),
            buffered.clone(),
            position.clone(),
            duration.clone(),
            shutdown.clone(),
        );
        move || {
            run_mixer(
                rx,
                producer,
                buffered,
                position,
                duration,
                44_100,
                events,
                shutdown,
                Arc::new(AtomicBool::new(false)),
                Arc::new(AtomicBool::new(false)),
                Arc::new(Mutex::new(NerdSnapshot::default())),
            )
        }
    });

    let (reply, result) = crossbeam_channel::bounded(1);
    tx.send(Command::Load {
        request: TrackSource {
            source: a.display().to_string(),
            title: "resume".into(),
            artist: String::new(),
            start_seconds: 180.0,
            plan: TransitionPlan::default(),
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        },
        reply,
    })
    .unwrap();
    result
        .recv_timeout(std::time::Duration::from_secs(3))
        .unwrap()
        .unwrap();

    // Past the limiter's look-ahead, which opens every load with a few
    // milliseconds of the delay line rather than the track.
    let wanted = 256 + 2 * crate::sound::Protector::new(48_000).delay_frames();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    let mut first_samples = Vec::new();
    while std::time::Instant::now() < deadline && first_samples.len() < wanted {
        while first_samples.len() < wanted {
            match consumer.pop() {
                Ok(sample) => first_samples.push(sample),
                Err(_) => break,
            }
        }
        if first_samples.len() < wanted {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
    }
    assert_eq!(
        first_samples.len(),
        wanted,
        "mixer did not fill the output ring"
    );
    let peak = first_samples
        .iter()
        .map(|sample| sample.abs())
        .fold(0.0, f32::max);
    assert!(peak > 0.1, "first ring PCM is silent (peak {peak})");
    let started_at = position.load(Ordering::Relaxed) as f64 / 1000.0;
    assert!(
        (179.9..181.0).contains(&started_at),
        "audible position should start at 180 s, got {started_at:.3} s"
    );

    shutdown.store(true, Ordering::Relaxed);
    let _ = handle.join();
    let _ = std::fs::remove_file(a);
}

/// 116 BPM clicks, sped up to 120, stay on the outgoing 120 BPM grid through
/// the overlap, then settle back to 116 once the post-blend glide ends.
#[test]
fn a_beatmatched_blend_holds_the_grid_then_glides_home() {
    let dir = std::env::temp_dir().join("bitchord-mixer-beats");
    std::fs::create_dir_all(&dir).unwrap();
    let a = dir.join("out.wav");
    let b = dir.join("in.wav");
    click_wav(&a, 10.0, 120.0, true);
    click_wav(&b, 36.0, 116.0, false);

    let events = std::sync::Arc::new(RecordedEvents::default());
    let (tx, rx) = crossbeam_channel::unbounded::<Command>();
    let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2);
    let buffered = std::sync::Arc::new(AtomicU64::new(0));
    let position = std::sync::Arc::new(AtomicU64::new(0));
    let duration = std::sync::Arc::new(AtomicU64::new(0));
    let shutdown = std::sync::Arc::new(AtomicBool::new(false));
    let handle = std::thread::spawn({
        let events = events.clone();
        let buffered = buffered.clone();
        let position = position.clone();
        let duration = duration.clone();
        let shutdown = shutdown.clone();
        move || {
            run_mixer(
                rx,
                consumer_side,
                buffered,
                position,
                duration,
                44_100,
                events,
                shutdown,
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
            )
        }
    });

    let rate = 44_100usize;
    // Eight seconds of blend ending one second before the outgoing file,
    // so the bed (before the bass swap) is long enough to compare grids.
    let fade = 8.0;
    let end = 9.0;
    tx.send(Command::Load {
        request: TrackSource {
            source: a.display().to_string(),
            title: "A".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan::default(),
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 10.0,
        },
        reply: crossbeam_channel::bounded(1).0,
    })
    .unwrap();
    tx.send(Command::QueueNext {
        request: TrackSource {
            source: b.display().to_string(),
            title: "B".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan {
                style: TransitionStyle::DjBlend,
                bass_swap: true,
                bass_swap_fraction: 0.6,
                fade_seconds: fade,
                effect_seconds: 0.0,
                effect_start_seconds: 0.0,
                transition_end_seconds: end,
                playback_rate: 120.0 / 116.0,
                bed_fraction: 0.45,
                bed_gain_db: -14.0,
                dip_depth: 0.0,
                dip_width: 0.05,
                // 32 beats of the matched 120 BPM grid.
                post_glide_seconds: 32.0 * 0.5,
                ..TransitionPlan::default()
            },
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 36.0,
        },
    })
    .unwrap();

    let want = rate * 28;
    let mut samples = Vec::with_capacity(want * 2);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
    while samples.len() / 2 < want && std::time::Instant::now() < deadline {
        match consumer.pop() {
            Ok(sample) => {
                samples.push(sample);
                if samples.len() % 2 == 0 {
                    let mut current = buffered.load(Ordering::Relaxed);
                    while current > 0 {
                        match buffered.compare_exchange_weak(
                            current,
                            current - 1,
                            Ordering::Relaxed,
                            Ordering::Relaxed,
                        ) {
                            Ok(_) => break,
                            Err(v) => current = v,
                        }
                    }
                }
            }
            Err(_) => std::thread::sleep(std::time::Duration::from_millis(2)),
        }
    }
    shutdown.store(true, Ordering::Relaxed);
    tx.send(Command::Shutdown).ok();
    let _ = handle.join();
    assert!(
        samples.len() / 2 > rate * 27,
        "only captured {:.1}s",
        samples.len() as f64 / 2.0 / rate as f64
    );

    let onsets = |channel: usize, from_s: f64, until_s: f64| -> Vec<usize> {
        let frames = samples.len() / 2;
        let start = ((from_s * rate as f64) as usize).min(frames);
        let end = ((until_s * rate as f64) as usize).min(frames);
        let mut peaks = Vec::new();
        let mut i = start.max(1);
        while i + 1 < end {
            let level = samples[i * 2 + channel].abs();
            if level > 0.05
                && level >= samples[(i - 1) * 2 + channel].abs()
                && level >= samples[(i + 1) * 2 + channel].abs()
            {
                peaks.push(i);
                i += rate / 10;
            } else {
                i += 1;
            }
        }
        peaks
    };

    // Fade runs 1s..9s; the bass swap is at 0.6 of that, so 1.4s..5.4s is
    // still the bed — both records full-band, the incoming underneath.
    let left = onsets(0, 1.4, 5.4);
    let right = onsets(1, 1.4, 5.4);
    assert!(
        left.len() >= 4,
        "outgoing clicks in the overlap: {}",
        left.len()
    );
    assert!(
        right.len() >= 4,
        "incoming clicks in the overlap: {}",
        right.len()
    );
    let mut worst = 0.0f64;
    for beat in &left {
        let nearest = right
            .iter()
            .map(|other| (*other as isize - *beat as isize).unsigned_abs())
            .min()
            .unwrap_or(usize::MAX);
        let ms = nearest as f64 / rate as f64 * 1000.0;
        worst = worst.max(ms);
    }
    assert!(
        worst < 15.0,
        "beats drifted by {worst:.1} ms during the blend"
    );

    // The glide is 16 s from the end of the blend (t = 9), so past t = 25
    // the incoming record is back at its own 116 BPM.
    let home = onsets(1, 25.4, 27.6);
    assert!(
        home.len() >= 3,
        "not enough clicks after the glide: {}",
        home.len()
    );
    let expected = rate as f64 * 60.0 / 116.0;
    for pair in home.windows(2) {
        let gap = (pair[1] - pair[0]) as f64;
        let error = (gap - expected).abs() / expected;
        assert!(
            error < 0.02,
            "after the glide the spacing was {gap:.0} samples, {error:.3} off 116 BPM"
        );
    }
}

#[test]
fn outgoing_eof_does_not_finish_an_incoming_fade_early() {
    let dir = std::env::temp_dir().join("bitchord-mixer-outgoing-eof");
    std::fs::create_dir_all(&dir).unwrap();
    let a = dir.join("outgoing.wav");
    let b = dir.join("incoming.wav");
    test_wav(&a, 8.0, 440.0);
    test_wav(&b, 8.0, 660.0);

    let request = |path: &std::path::Path, title: &str| TrackSource {
        source: path.display().to_string(),
        title: title.into(),
        artist: String::new(),
        start_seconds: 0.0,
        plan: TransitionPlan::default(),
        headers: std::collections::HashMap::new(),
        claimed_kbps: 0,
        loudness_db: None,
        duration_seconds: 8.0,
    };
    let mut current =
        Voice::open(&request(&a, "A"), false, 0.0, 44_100, 1.0, false, false).unwrap();
    current.finished = true;
    let mut incoming =
        Voice::open(&request(&b, "B"), false, 0.0, 44_100, 1.0, false, false).unwrap();
    incoming.emitted_dev_frames = 2 * 44_100;

    let mut state = MixerState {
        current: Some(current),
        incoming: Some(incoming),
        pending_next: None,
        warned_no_duration: false,
        transition: Some(TransitionState {
            phase: Phase::Fading,
            fade_frames: 4 * 44_100,
            handed_off: true,
            plan: TransitionPlan::default(),
            arm_deadline: Instant::now(),
            swap: false,
            fx: None,
            effect_start_frame: 0,
            effect_input_gain: None,
        }),
        retiring: Vec::new(),
        render_scratch: Vec::new(),
        voice_output_scratch: Vec::new(),
        effect_dry_scratch: Vec::new(),
        retiring_scratch: Vec::new(),
        playing: true,
        bit_perfect: false,
        volume: 1.0,
        sleep_gain: 1.0,
        hold_end: false,
        crossfade_window_s: 4.0,
        spatial_enabled: false,
        head_yaw: 0.0,
        device_rate: 44_100,
        buffered_frames: Arc::new(AtomicU64::new(0)),
        position_ms: Arc::new(AtomicU64::new(0)),
        duration_ms: Arc::new(AtomicU64::new(0)),
        events: Arc::new(RecordedEvents::default()),
        state: crate::PlaybackState::Playing,
        flush_ring: Arc::new(AtomicBool::new(false)),
        bail_flush: Arc::new(AtomicBool::new(false)),
        playback_speed: 1.0,
        skip_silence: false,
        eq: EqualizerProcessor::new(44_100, 2),
        sound_mode: SoundMode::Transparent,
        clarity_tuning: ClarityTuning::default(),
        clarity: Clarity::new(44_100),
        protector: Protector::new(44_100),
        pipeline_tail_frames: 0,
        output_generation: 0,
        queue_target_ms: 250,
        underrun_counter: None,
        observed_underruns: 0,
        nerd: Arc::new(Mutex::new(NerdSnapshot::default())),
        last_diagnostic_signature: None,
        last_diagnostic_publish: None,
        loudness_enabled: false,
        loudness_mode: LoudnessMode::Off,
        swap_probe: SwapProbe::default(),
    };

    assert!(
        !state.drive_fade(),
        "outgoing EOF must not promote the incoming track before the fade completes"
    );
    let incoming_gain = state.incoming.as_ref().unwrap().gain;
    assert!(incoming_gain > 0.0 && incoming_gain < 1.0);

    state.incoming.as_mut().unwrap().emitted_dev_frames = 4 * 44_100;
    assert!(
        state.drive_fade(),
        "the fade completes at its planned duration"
    );
}

#[test]
fn crossfade_handoff_playhead_is_incoming_not_outgoing_tail() {
    let dir = std::env::temp_dir().join("bitchord-mixer-xfade-pos");
    std::fs::create_dir_all(&dir).unwrap();
    let a = dir.join("out.wav");
    let b = dir.join("in.wav");
    test_wav(&a, 3.0, 440.0);
    test_wav(&b, 3.0, 660.0);

    let position = std::sync::Arc::new(AtomicU64::new(0));
    let events = std::sync::Arc::new(RecordedEvents {
        position_ms: Some(position.clone()),
        ..RecordedEvents::default()
    });
    let (tx, rx) = crossbeam_channel::unbounded::<Command>();
    let (consumer_side, mut consumer) = rtrb::RingBuffer::<f32>::new(44_100 * 2 * 4);
    let buffered = std::sync::Arc::new(AtomicU64::new(0));
    let duration = std::sync::Arc::new(AtomicU64::new(0));
    let shutdown = std::sync::Arc::new(AtomicBool::new(false));

    let handle = std::thread::spawn({
        let events = events.clone();
        let buffered = buffered.clone();
        let position = position.clone();
        let duration = duration.clone();
        let shutdown = shutdown.clone();
        move || {
            run_mixer(
                rx,
                consumer_side,
                buffered,
                position,
                duration,
                44_100,
                events,
                shutdown,
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(AtomicBool::new(false)),
                std::sync::Arc::new(Mutex::new(NerdSnapshot::default())),
            )
        }
    });

    tx.send(Command::SetCrossfadeWindow(1.0)).unwrap();
    tx.send(Command::Load {
        request: TrackSource {
            source: a.display().to_string(),
            title: "A".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan::default(),
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        },
        reply: crossbeam_channel::bounded(1).0,
    })
    .unwrap();
    tx.send(Command::QueueNext {
        request: TrackSource {
            source: b.display().to_string(),
            title: "B".into(),
            artist: String::new(),
            start_seconds: 0.0,
            plan: TransitionPlan::default(),
            headers: std::collections::HashMap::new(),
            claimed_kbps: 0,
            loudness_db: None,
            duration_seconds: 0.0,
        },
    })
    .unwrap();

    drain_until_handoff(&mut consumer, &buffered, &position, &events, 20);

    let handoffs = events.handoffs.lock().unwrap().clone();
    assert_eq!(handoffs, vec!["B".to_string()], "handoff to B must fire");
    let at = events.position_at_handoff.lock().unwrap().clone();
    assert_eq!(at.len(), 1);
    // Outgoing is 3 s; fade starts with ~1 s left, so the old playhead
    // would be ~2000 ms. Incoming must be at (or very near) its cue.
    assert!(
        at[0] < 1_500,
        "handoff playhead {} ms is the outgoing tail, not the incoming start",
        at[0]
    );

    shutdown.store(true, Ordering::Relaxed);
    let _ = handle.join();
}

/// A handoff stretch that is stepped back to unity at the end of a blend is
/// a pitch step, because the stretch is a resample.
///
/// Regression-shaped: `release_plan_stretch` used to fire at the fade's end
/// and land the rate on 1.0 in a single frame — a 3 % stretch is 51 cents,
/// arriving in one sample. The glide walks there instead, so the release
/// finds unity already reached and changes nothing.
#[test]
fn the_handoff_tempo_glide_lands_on_unity_rather_than_stepping() {
    let base = 1.03f64;
    assert!(
        (base - 1.0).abs() > 1e-4,
        "this test is about a non-unity rate"
    );
    // Monotone, and strictly inside the range the whole way.
    let mut previous = f64::INFINITY;
    for step in 0..=1000 {
        let p = step as f64 / 1000.0;
        let target = glided_plan_rate(base, p);
        assert!(
            target <= previous + 1e-12 && target >= 1.0 - 1e-12,
            "glide at {p} was {target}, outside (1.0, {previous}]"
        );
        previous = target;
    }
    // Exactly unity at the end, so `release_plan_stretch`'s early-out is
    // what actually runs and there is nothing to snap.
    assert_eq!(glided_plan_rate(base, 1.0), 1.0);
    // A unity plan is not glided at all.
    assert_eq!(glided_plan_rate(1.0, 0.5), 1.0);
}

/// A beatmatched handoff stretches the incoming track so the two share a
/// grid for the blend. That stretch must not survive the blend.
///
/// Regression: the port baked `plan_rate` into the voice's speed resampler
/// at `Voice::open` and nothing ever cleared it, so every track that
/// arrived through a beatmatched or phrase-switch blend played ~3 % fast for
/// its entire length — +51 cents, with the published position running at the
/// stretched rate too. Upstream resets the player's speed in both
/// `finish()` and `retire()`.
///
/// The stretch is a WSOLA stage now rather than a rate change, so the
/// assertion is on the stage: engaged at the plan's rate while the blend
/// runs, gone and drained once it ends.
#[test]
fn a_promoted_voice_drops_the_handoff_tempo_stretch() {
    let dir = std::env::temp_dir().join("bitchord-mixer-stretch");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("a.wav");
    test_wav(&path, 4.0, 440.0);

    let request = TrackSource {
        source: path.display().to_string(),
        title: "A".into(),
        artist: String::new(),
        start_seconds: 0.0,
        // What the planner hands a beatmatched handoff.
        plan: TransitionPlan {
            playback_rate: 1.03,
            ..TransitionPlan::default()
        },
        headers: std::collections::HashMap::new(),
        claimed_kbps: 0,
        loudness_db: None,
        duration_seconds: 0.0,
    };
    let mut voice = Voice::open(&request, false, 0.0, 44_100, 1.0, false, false).unwrap();
    // The listener's own speed is untouched by the handoff — that is the
    // point of routing the stretch through its own stage. It used to be
    // multiplied by the plan rate, which is the bug in its other form.
    assert!(
        (voice.effective_speed - 1.0).abs() < 1e-6,
        "the handoff must not touch the speed control, got {}",
        voice.effective_speed
    );
    // And nothing is running yet: the stage is for a blend, and this voice
    // has not entered one. A `Load` — a tap on the queue, a skip — carries
    // the same plan record, and engaging here would leave the track playing
    // 3 % slow for its whole length with nothing to release it.
    assert!(
        voice.stretch.is_none(),
        "a fresh open must not engage the handoff stretch"
    );
    assert_eq!(
        voice.base_plan_rate, 1.03,
        "but the plan's ratio is remembered"
    );

    // The blend engages it...
    voice.set_plan_rate(voice.base_plan_rate);
    assert!(voice.stretch.is_some());
    assert!((voice.stretch.as_ref().unwrap().rate() - 1.03).abs() < 1e-9);

    // The blend holds the rate. Walking it during the fade is the flam.
    assert!((voice.plan_rate - 1.03).abs() < 1e-9);
    // With no post-blend glide requested, release is immediate and arms
    // the drain. The stage is still holding a frame; dropping it there
    // would punch a hole. It goes on the next pull.
    voice.release_plan_stretch(1.0, 44_100);
    assert!(
        voice.stretch_draining,
        "release must drain the stage rather than drop it"
    );
    assert!(
        (voice.effective_speed - 1.0).abs() < 1e-6,
        "the stretch outlived the blend: {}",
        voice.effective_speed
    );
    assert!((voice.plan_rate - 1.0).abs() < 1e-9);
    let _ = voice.pull(512, 44_100);
    assert!(!voice.stretch_draining);
    assert!(voice.stretch.is_none(), "the stretch outlived the blend");

    // A later user speed change must not resurrect it.
    voice.set_playback_speed(1.25, 44_100);
    assert!(
        (voice.effective_speed - 1.25).abs() < 1e-6,
        "a speed change re-stacked the stretch: {}",
        voice.effective_speed
    );
    assert!(
        voice.stretch.is_none(),
        "a speed change must not bring the handoff stage back"
    );
}

/// Retiring the stretch must not swallow the samples it was still holding.
///
/// The stage buffers roughly a frame of input it has not placed. Dropping it
/// on release would punch a ~12 ms hole in the track at the exact moment the
/// blend hands it over and its gain reaches unity — the worst possible place
/// for a discontinuity, and one no level assertion on the blend would catch
/// because the blend is already over.
#[test]
fn retiring_the_stretch_drains_rather_than_drops() {
    let dir = std::env::temp_dir().join("bitchord-mixer-stretch");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("drain.wav");
    test_wav(&path, 3.0, 440.0);

    let request = TrackSource {
        source: path.display().to_string(),
        title: "A".into(),
        artist: String::new(),
        start_seconds: 0.0,
        plan: TransitionPlan {
            playback_rate: 1.03,
            ..TransitionPlan::default()
        },
        headers: std::collections::HashMap::new(),
        claimed_kbps: 0,
        loudness_db: None,
        duration_seconds: 0.0,
    };
    let mut voice = Voice::open(&request, false, 0.0, 44_100, 1.0, false, false).unwrap();
    // Run the blend part of the way so the stage has something buffered.
    for _ in 0..40 {
        let frames = voice.pull(512, 44_100);
        assert!(!frames.is_empty(), "the voice stopped producing audio");
    }
    voice.set_plan_rate(voice.base_plan_rate);
    voice.release_plan_stretch(1.0, 44_100);
    let before = voice.emitted_dev_frames;
    let frames = voice.pull(512, 44_100);
    assert!(
        !frames.is_empty(),
        "the drain must hand over what the stage was holding, not return nothing"
    );
    assert!(
        voice.emitted_dev_frames > before,
        "the drained samples were never emitted"
    );
    assert!(
        voice.stretch.is_none(),
        "the stage should be gone after the drain"
    );
}
