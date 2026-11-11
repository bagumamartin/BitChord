use crate::output::{is_lossless_pcm_codec, select_supported_format, OutputFormat, OutputRange};
use crate::render::{exact_f32_to_i16, exact_f32_to_i24};

/// The real-pair scorecard. Ignored by default because it reads the owner's
/// stream cache; `scripts/check-automix.sh` runs it with `--ignored`.
#[test]
#[ignore = "reads the owner's cached audio pairs"]
fn automix_corpus_scorecard() {
    use crate::api::plan_automix_impl_with_tier;
    use crate::AutomixTier;
    use std::path::PathBuf;

    // The planner's own `log_plan` lines carry the evidence behind each
    // row of the table (bpm, confidence, downbeats, key, content end). They
    // are the only way to tell "this pair has no tempo" from "this file did
    // not decode", which is exactly the distinction the Opus duration bug
    // hid for a whole scorecard run.
    let _ = env_logger::try_init();

    let root = std::env::var("AUTOMIX_CORPUS")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default())
                .join("Library/Caches/BitChord/audio")
        });
    // The app downloads both graphs into its own Application Support store;
    // development builds and this scorecard read the fetched cache instead.
    // `scripts/fetch-automix-models.sh` fills it, and the assertions below make
    // a run without either graph fail rather than silently measure the DSP
    // fallback.
    let models = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/models");
    // A model comparison is a different graph on the same corpus, so the
    // test can be pointed at one without touching the cache.
    let beat = std::env::var("AUTOMIX_BEAT_MODEL")
        .map(PathBuf::from)
        .unwrap_or_else(|_| models.join("beat_this.onnx"));
    let vocals = std::env::var("AUTOMIX_VOCALS_MODEL")
        .map(PathBuf::from)
        .unwrap_or_else(|_| models.join("vocals_umxhq_int8.onnx"));
    assert!(
        beat.exists(),
        "automix corpus: no beat model at {}",
        beat.display()
    );
    assert!(
        vocals.exists(),
        "automix corpus: no vocals model at {}",
        vocals.display()
    );
    println!(
        "automix corpus: models beat={} vocals={}",
        beat.display(),
        vocals.display()
    );
    crate::analyzer::configure(
        beat.to_str().unwrap_or_default(),
        vocals.to_str().unwrap_or_default(),
    );
    let mut files: Vec<PathBuf> = std::fs::read_dir(&root)
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "m4a"))
                .collect()
        })
        .unwrap_or_default();
    files.sort();
    if files.len() < 3 {
        println!(
            "automix corpus: {} audio files under {} — need >= 3 for pairs",
            files.len(),
            root.display()
        );
        return;
    }
    let title = |path: &PathBuf| {
        crate::metadata::read_track_metadata(&path.display().to_string())
            .map(|meta| meta.title)
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| {
                path.file_stem()
                    .map(|stem| stem.to_string_lossy().to_string())
                    .unwrap_or_default()
            })
    };
    let headers = std::collections::HashMap::new();
    let pairs = files.len().saturating_sub(1).min(50);
    let mut fades = Vec::new();
    let mut non_dropcut_fades = Vec::new();
    let mut effects = 0usize;
    let mut unusable = 0usize;
    let mut out_discarded = Vec::new();
    let mut in_discarded = Vec::new();
    let mut cold_endings = 0usize;
    let mut clipped_chords = 0usize;
    let mut bridged = 0usize;
    let style_names = [
        "equal_power", "dj_filter", "dj_blend", "gapless", "echo_out", "loop_roll",
        "reverb_wash", "drop_cut", "texture", "brake",
    ];
    let mut style_histogram = [0usize; 10];
    let mut unclassified = 0usize;
    println!("automix corpus: {pairs} pairs from {} files", files.len());
    // The corpus is one session in a row, paced as the app paces it
    // (`TransitionPacing`): three effects in a row hold the next to a blend.
    let mut recent_effects: std::collections::VecDeque<bool> = std::collections::VecDeque::new();
    for index in 0..pairs {
        let allow_effects =
            !(recent_effects.len() == 3 && recent_effects.iter().all(|effect| *effect));
        let outgoing = &files[index];
        let incoming = &files[index + 1];
        let plan = plan_automix_impl_with_tier(
            &outgoing.display().to_string(),
            &incoming.display().to_string(),
            &title(outgoing),
            &title(incoming),
            false,
            0.0,
            0.0,
            0.0,
            &headers,
            &headers,
            AutomixTier::Balanced,
            allow_effects,
        );
        let style = crate::mixer::TransitionPlan::from(plan.clone());
        // Each corpus pair is one finalized planned transition. The live mixer
        // calls this same record builder at start_fade with its measured snap
        // error; this planner-only harness has no playback clock for that field.
        let winner_record = if plan.fade_seconds > 0.0 {
            crate::mixer::automix_winner_record(&style, None)
        } else {
            None
        };
        if plan.fade_seconds > 0.0 {
            if let Some(record) = &winner_record {
                if let Some(index) = style_names.iter().position(|name| *name == record.style) {
                    style_histogram[index] += 1;
                } else {
                    unclassified += 1;
                }
            } else {
                unclassified += 1;
            }
        }
        recent_effects.push_back(style.style.is_effect());
        if recent_effects.len() > 3 {
            recent_effects.pop_front();
        }
        if plan.fade_seconds <= 0.0 {
            unusable += 1;
        }
        if style.style.is_effect() {
            effects += 1;
        }
        if plan.fade_seconds > 0.0 {
            fades.push(plan.fade_seconds);
            if style.style != crate::mixer::TransitionStyle::DropCut {
                non_dropcut_fades.push(plan.fade_seconds);
            }
        }
        let edges = crate::analyzer::last_transition_edges();
        out_discarded.push(edges.outgoing_discarded_seconds);
        in_discarded.push(edges.incoming_discarded_seconds);
        if edges.cold_ending {
            cold_endings += 1;
        }
        if edges.clipped_final_chord {
            clipped_chords += 1;
        }
        if plan.bridge_repeats > 0 {
            bridged += 1;
        }
        println!(
            "{:>2}. {:?} fade={:.2}s hold={:.2}s bridge={:.2}s×{} effect={:.2}s end={:.2}s \
             beat={:.3}s rate={:.4} | {} → {} | discarded out {:.1}s in {:.1}s{} | {}",
            index + 1,
            plan.style,
            plan.fade_seconds,
            plan.outgoing_hold_seconds,
            plan.bridge_seconds,
            plan.bridge_repeats,
            plan.effect_seconds,
            plan.transition_end_seconds,
            plan.beat_seconds,
            plan.playback_rate,
            title(outgoing),
            title(incoming),
            edges.outgoing_discarded_seconds,
            edges.incoming_discarded_seconds,
            if edges.clipped_final_chord {
                " CLIPPED CHORD"
            } else {
                ""
            },
            plan.reason
        );
    }
    let mut sorted = fades.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = sorted.get(sorted.len() / 2).copied().unwrap_or(0.0);
    let mut sorted_non_dropcut = non_dropcut_fades;
    sorted_non_dropcut.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let min_non_dropcut = sorted_non_dropcut.first().copied().unwrap_or(0.0);
    let median_of = |values: &mut Vec<f64>| {
        values.sort_by(|a, b| a.partial_cmp(b).unwrap());
        values.get(values.len() / 2).copied().unwrap_or(0.0)
    };
    let median_out = median_of(&mut out_discarded);
    let median_in = median_of(&mut in_discarded);
    let max_out = out_discarded.iter().copied().fold(0.0f64, f64::max);
    let max_in = in_discarded.iter().copied().fold(0.0f64, f64::max);
    println!(
        "automix scorecard: usable {}/{}, median fade {:.2}s, effects {}/{}, min fade {:.2}s, \
         min non-DropCut fade {:.2}s, bridged {}/{}",
        fades.len(),
        pairs,
        median,
        effects,
        pairs,
        sorted.first().copied().unwrap_or(0.0),
        min_non_dropcut,
        bridged,
        pairs
    );
    println!(
        "automix edges: discarded out median {median_out:.1}s max {max_out:.1}s, in median \
         {median_in:.1}s max {max_in:.1}s, cold endings {cold_endings}, clipped final chords \
         {clipped_chords}"
    );
    println!(
        "automix scorecard telemetry: winner_records={} unclassified={} styles={}",
        style_histogram.iter().sum::<usize>(),
        unclassified,
        style_names
            .iter()
            .zip(style_histogram.iter())
            .map(|(name, count)| format!("{name}:{count}"))
            .collect::<Vec<_>>()
            .join(",")
    );
    assert_eq!(
        unclassified, 0,
        "automix corpus contains a real transition without a classified winner record"
    );
    assert_eq!(pairs, 50, "automix corpus must contain exactly 50 analyzed pairs");
    {
        let busiest = style_histogram.iter().copied().max().unwrap_or(0);
        assert!(
            busiest * 10 <= pairs * 3,
            "automix style concentration {busiest}/{pairs} exceeds 30%: {style_histogram:?}"
        );
        // The sampled set has almost no energetic-drop pairs; DropCut is
        // covered by its planner and render unit tests instead.
        for technique in [
            "echo_out",
            "loop_roll",
            "reverb_wash",
            "texture",
            "brake",
        ] {
            let count = style_names
                .iter()
                .position(|name| *name == technique)
                .map(|index| style_histogram[index])
                .unwrap_or(0);
            assert!(count > 0, "automix corpus did not exercise {technique}");
        }
    }
    // A′3 turns these into gates; A′2 reports them. The cached files are
    // Opus-in-MP4 and the Rust analyser does not decode every one, so an
    // unusable pair is reported, not asserted.
    println!("automix scorecard: {unusable} pair(s) without a usable analysis");
}

fn range(min_rate: u32, max_rate: u32, channels: usize, pcm16: bool) -> OutputRange {
    OutputRange {
        min_rate,
        max_rate,
        channels,
        pcm16,
    }
}

#[test]
fn no_hint_uses_the_device_default_rate_and_channels() {
    assert_eq!(
        select_supported_format(&[range(44_100, 192_000, 2, false)], 0, 0, 48_000, 2, false),
        Some(OutputFormat {
            sample_rate: 48_000,
            channels: 2,
            pcm16: false,
            bit_perfect_depth: 0,
        })
    );
}

#[test]
fn an_exact_platform_rate_is_used_when_the_device_supports_it() {
    assert_eq!(
        select_supported_format(
            &[range(44_100, 192_000, 2, false)],
            44_100,
            2,
            48_000,
            2,
            false
        ),
        Some(OutputFormat {
            sample_rate: 44_100,
            channels: 2,
            pcm16: false,
            bit_perfect_depth: 0,
        })
    );
}

#[test]
fn unsupported_requested_rate_falls_back_to_device_rate() {
    assert_eq!(
        select_supported_format(
            &[range(44_100, 48_000, 2, false)],
            192_000,
            2,
            48_000,
            2,
            false
        ),
        Some(OutputFormat {
            sample_rate: 48_000,
            channels: 2,
            pcm16: false,
            bit_perfect_depth: 0,
        })
    );
}

#[test]
fn unsupported_requested_encoding_falls_back_to_float() {
    assert_eq!(
        select_supported_format(
            &[range(44_100, 48_000, 2, false)],
            48_000,
            2,
            48_000,
            2,
            true
        ),
        Some(OutputFormat {
            sample_rate: 48_000,
            channels: 2,
            pcm16: false,
            bit_perfect_depth: 0,
        })
    );
}

#[test]
fn empty_device_capabilities_have_no_candidate() {
    assert_eq!(
        select_supported_format(&[], 48_000, 2, 48_000, 2, false),
        None
    );
}

#[test]
fn integer_pcm_survives_the_float_ring_and_integer_pack_exactly() {
    for value in i16::MIN..=i16::MAX {
        let normalized = value as f32 / 32_768.0;
        assert_eq!(exact_f32_to_i16(normalized), value);
    }
    for value in (-(1 << 23)..(1 << 23)).step_by(257) {
        let normalized = value as f32 / 8_388_608.0;
        assert_eq!(exact_f32_to_i24(normalized), value);
    }
    assert_eq!(exact_f32_to_i24(-1.0), -(1 << 23));
    assert_eq!(exact_f32_to_i24(1.0), (1 << 23) - 1);
}

#[test]
fn bitperfect_eligibility_rejects_lossy_codecs() {
    assert!(is_lossless_pcm_codec("FLAC"));
    assert!(is_lossless_pcm_codec("ALAC"));
    assert!(is_lossless_pcm_codec("PCM"));
    assert!(is_lossless_pcm_codec("PCM Float"));
    assert!(!is_lossless_pcm_codec("AAC"));
    assert!(!is_lossless_pcm_codec("Opus"));
    assert!(!is_lossless_pcm_codec("MP3"));
    assert!(!is_lossless_pcm_codec("AIFF"));
    assert!(!is_lossless_pcm_codec("G.711"));
}

#[test]
fn pcm_mode_parses_the_two_upstream_rungs() {
    use crate::{AutomixTier, OutputPcmMode};
    assert_eq!(OutputPcmMode::parse("PCM_16"), OutputPcmMode::Pcm16);
    assert_eq!(OutputPcmMode::parse("FLOAT_32"), OutputPcmMode::Float32);
    // The removed PCM_24 rung and anything unknown fall to the lossless
    // path, never the lossy one.
    assert_eq!(OutputPcmMode::parse("PCM_24"), OutputPcmMode::Float32);
    assert_eq!(OutputPcmMode::parse(""), OutputPcmMode::Pcm16);
    assert_eq!(AutomixTier::parse("EFFICIENT"), AutomixTier::Efficient);
    assert_eq!(AutomixTier::parse("PERFORMANCE"), AutomixTier::Performance);
    assert_eq!(AutomixTier::parse("BALANCED"), AutomixTier::Balanced);
    assert!(!AutomixTier::Efficient.runs_vocal_model());
    assert!(AutomixTier::Balanced.runs_vocal_model());
    assert!(AutomixTier::Performance.runs_vocal_model());
    assert_eq!(AutomixTier::Efficient.inference_threads(), 1);
    assert_eq!(AutomixTier::Balanced.inference_threads(), 1);
    assert_eq!(AutomixTier::Performance.inference_threads(), 4);
}

#[test]
fn loudness_correction_does_not_boost_without_peak_metadata() {
    use crate::mixer::loudness_gain;
    // loudnessDb does not include a true-peak ceiling, so positive gain can
    // push a mastered source over 0 dBFS. Keep normalization attenuation
    // while refusing that unsafe boost.
    let (gain, db) = loudness_gain(Some(-7.0), true);
    assert_eq!(db, Some(0.0));
    assert_eq!(gain, 1.0);
    // A track 20 dB quiet asks for -20 dB, clamped to -15 dB.
    let (gain, db) = loudness_gain(Some(20.0), true);
    assert_eq!(db, Some(-15.0));
    assert!((gain - 10f32.powf(-15.0 / 20.0)).abs() < 1e-6);
    // Unity figure, switch off, missing figure, NaN: all unity, all None.
    assert_eq!(loudness_gain(Some(0.0), true), (1.0, Some(0.0)));
    assert_eq!(loudness_gain(Some(-7.0), false), (1.0, None));
    assert_eq!(loudness_gain(None, true), (1.0, None));
    assert_eq!(loudness_gain(Some(f64::NAN), true), (1.0, None));
}

#[test]
fn bitperfect_output_callback_copies_samples_without_app_gain() {
    use crate::render::render_bitperfect;
    use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
    use std::sync::Arc;

    let source = [-0.75f32, 0.5, -0.125, 0.25];
    let (mut producer, mut consumer) = rtrb::RingBuffer::<f32>::new(8);
    for sample in source {
        producer.push(sample).unwrap();
    }
    let buffered = Arc::new(AtomicU64::new(2));
    let underruns = Arc::new(AtomicU64::new(0));
    let peak = Arc::new(AtomicU32::new(0));
    let flush = Arc::new(AtomicBool::new(false));
    let bail = Arc::new(AtomicBool::new(false));
    let paused = Arc::new(AtomicBool::new(false));
    let mut output = [0.0f32; 4];
    render_bitperfect(
        &mut consumer,
        &buffered,
        &underruns,
        &peak,
        &flush,
        &bail,
        &paused,
        &mut output,
    );
    assert_eq!(output, source);
    assert_eq!(buffered.load(Ordering::Relaxed), 0);
    assert_eq!(underruns.load(Ordering::Relaxed), 0);
}

#[test]
fn integer_callback_keeps_partial_stereo_frame_until_complete() {
    use crate::render::render_bitperfect;
    use std::sync::{
        atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
        Arc,
    };
    let (mut producer, mut consumer) = rtrb::RingBuffer::new(8);
    producer.push(0.25).unwrap();
    let buffered = Arc::new(AtomicU64::new(1));
    let underruns = Arc::new(AtomicU64::new(0));
    let peak = Arc::new(AtomicU32::new(0));
    let flush = Arc::new(AtomicBool::new(false));
    let bail = Arc::new(AtomicBool::new(false));
    let paused = Arc::new(AtomicBool::new(false));
    let mut data = [9.0; 2];
    render_bitperfect(
        &mut consumer,
        &buffered,
        &underruns,
        &peak,
        &flush,
        &bail,
        &paused,
        &mut data,
    );
    assert_eq!(data, [0.0; 2]);
    assert_eq!(buffered.load(Ordering::Relaxed), 1);
    producer.push(-0.75).unwrap();
    render_bitperfect(
        &mut consumer,
        &buffered,
        &underruns,
        &peak,
        &flush,
        &bail,
        &paused,
        &mut data,
    );
    assert_eq!(data, [0.25, -0.75]);
    assert_eq!(buffered.load(Ordering::Relaxed), 0);
}

#[test]
fn bail_flush_ramps_output_down_over_120ms_and_flushes_backlog() {
    use crate::render::{render_f32, BailRamp};
    use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64};
    use std::sync::Arc;

    let rate = 48_000u32;
    let channels = 2usize;
    let total_samples = (rate as usize * 2) * channels;
    let (mut producer, mut consumer) = rtrb::RingBuffer::<f32>::new(total_samples * 2);
    for _ in 0..total_samples {
        producer.push(1.0).unwrap();
    }

    let volume = Arc::new(AtomicU32::new(1.0f32.to_bits()));
    let buffered = Arc::new(AtomicU64::new((total_samples / channels) as u64));
    let underruns = Arc::new(AtomicU64::new(0));
    let peak = Arc::new(AtomicU32::new(0));
    let flush_ring = Arc::new(AtomicBool::new(false));
    let bail_flush = Arc::new(AtomicBool::new(true));
    let paused = Arc::new(AtomicBool::new(false));
    let mut bail_ramp = BailRamp {
        app_gain: 1.0,
        recovery_gain: 1.0,
        last_frame: [0.0; 2],
        primed: true,
        prebuffer: false,
        waited_frames: 0,
        buffer: Vec::with_capacity((rate as usize * 120 / 1000) * 2),
        cursor: 0,
        total_frames: 0,
    };

    let chunk_size = 512;
    let mut output_samples = Vec::new();
    let total_chunks = ((rate as usize * 150 / 1000) * channels) / chunk_size;

    let mut chunk = vec![0.0f32; chunk_size];
    for _ in 0..total_chunks {
        render_f32(
            &mut consumer,
            &volume,
            &buffered,
            &underruns,
            &peak,
            &flush_ring,
            &bail_flush,
            &paused,
            &mut bail_ramp,
            rate,
            channels,
            &mut chunk,
        );
        output_samples.extend_from_slice(&chunk);
    }

    let bail_samples = (rate as usize * 120 / 1000) * 2;
    assert_eq!(bail_ramp.buffer.len(), bail_samples);
    assert!((output_samples[0] - 1.0).abs() < 1e-3);
    let mid_sample = bail_samples / 2;
    let mid_val = output_samples[mid_sample];
    assert!(
        (mid_val - std::f32::consts::FRAC_1_SQRT_2).abs() < 0.05,
        "expected ~0.707 at midpoint, got {mid_val}"
    );

    let end_sample = bail_samples - 2;
    assert!(
        output_samples[end_sample] < 0.05,
        "expected near 0.0 at end of ramp, got {}",
        output_samples[end_sample]
    );

    for (i, &s) in output_samples[bail_samples..].iter().enumerate() {
        assert_eq!(
            s,
            0.0,
            "sample at +{}ms beyond bail should be silent, got {s}",
            (bail_samples + i) / (rate as usize * 2 / 1000)
        );
    }

    assert!(consumer.pop().is_err());
}
#[test]
fn sleep_gain_does_not_replace_user_volume() {
    use std::sync::atomic::Ordering;
    let engine = super::PlayerEngine::new();
    engine.set_volume(0.7);
    let _ = engine.set_sleep_gain(0.5);
    assert!((engine.application_output_gain() - 0.35).abs() < 0.0001);
    engine.set_volume(0.4);
    assert!((engine.application_output_gain() - 0.2).abs() < 0.0001);
    let _ = engine.set_sleep_gain(1.0);
    assert!((engine.application_output_gain() - 0.4).abs() < 0.0001);
    assert_eq!(
        f32::from_bits(engine.user_volume_bits.load(Ordering::Relaxed)),
        0.4
    );
}

#[test]
fn source_verification_decodes_payload_instead_of_trusting_the_extension() {
    let path = std::env::temp_dir().join(format!("bitchord-verified-{}.flac", std::process::id()));
    let rate = 48_000u32;
    let frames = rate / 2;
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + frames * 4).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&rate.to_le_bytes());
    bytes.extend_from_slice(&(rate * 4).to_le_bytes());
    bytes.extend_from_slice(&4u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(frames * 4).to_le_bytes());
    bytes.resize(44 + frames as usize * 4, 0); // Silence is decodable audio, not an empty file.
    std::fs::write(&path, bytes).unwrap();
    let engine = crate::PlayerEngine::new();
    let verified = engine
        .verify_audio_source(path.display().to_string(), None)
        .unwrap();
    assert_eq!(verified.format.codec, "PCM");
    assert_eq!(verified.format.sample_rate, rate);
    assert_eq!(verified.format.bit_depth, 16);
    assert_eq!(verified.estimated_kbps, Some(1536));
    std::fs::write(&path, b"not decodable audio").unwrap();
    assert!(engine
        .verify_audio_source(path.display().to_string(), None)
        .is_err());
    std::fs::remove_file(path).unwrap();
}
