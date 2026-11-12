//! Analysis caching by file identity, the disk cache, overlays and energy dips.

use super::*;

#[test]
fn changed_overlay_cannot_reuse_an_old_disk_analysis() {
    let dir = std::env::temp_dir().join(format!("bitchord-overlay-disk-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    analysis_cache::set_test_disk_dir(dir.clone());
    let source = dir.join("audio");
    std::fs::write(&source, b"unchanged audio bytes").unwrap();
    let path = source.to_string_lossy().to_string();
    let calls = AtomicUsize::new(0);
    let overlay = super::super::cache::AnalysisOverlay { bpm: Some(110.0), ..Default::default() };
    assert!(seed_analysis_overlay(&path, overlay.clone()));
    let first = analysis_cache::get_or_compute(&path, false, 90.0, || {
        calls.fetch_add(1, Ordering::SeqCst);
        Analysis { bpm: 110.0, ..Default::default() }
    });
    assert_eq!(first.bpm, 110.0);
    assert!(seed_analysis_overlay(&path, overlay.clone()));
    let same = analysis_cache::get_or_compute(&path, false, 90.0, || panic!("unchanged overlay recomputed analysis"));
    assert_eq!(same.bpm, 110.0);
    assert!(seed_analysis_overlay(&path, super::super::cache::AnalysisOverlay { bpm: Some(120.0), ..overlay }));
    let changed = analysis_cache::get_or_compute(&path, false, 90.0, || {
        calls.fetch_add(1, Ordering::SeqCst);
        Analysis { bpm: 120.0, ..Default::default() }
    });
    assert_eq!(changed.bpm, 120.0, "changed overlay read the prior disk entry");
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    analysis_cache::invalidate(&path);
    let disk = analysis_cache::get_or_compute(&path, false, 90.0, || panic!("new overlay disk entry was not reusable"));
    assert_eq!(disk.bpm, 120.0);
    std::fs::remove_dir_all(dir).unwrap();
}

/// The cache is what stops a transport command from re-decoding both tracks.
/// It must key on the file's *content identity*, not just its path: a
/// streamed download is appended to under a stable name, and serving a
/// half-downloaded file's analysis forever would misplace every cue.
#[test]
fn analysis_cache_hits_by_identity_and_misses_when_the_file_grows() {
    let dir = std::env::temp_dir().join("bitchord-plan-cache");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("growing.bin");
    std::fs::write(&path, vec![0u8; 1024]).unwrap();
    let key = path.to_string_lossy().to_string();

    let computed = AtomicUsize::new(0);
    let mut compute = || {
        computed.fetch_add(1, Ordering::SeqCst);
        Analysis::default()
    };

    let first = analysis_cache::get_or_compute(&key, false, 90.0, &mut compute);
    let second = analysis_cache::get_or_compute(&key, false, 90.0, &mut compute);
    assert_eq!(computed.load(Ordering::SeqCst), 1, "a repeat must be a hit");
    assert!(
        Arc::ptr_eq(&first, &second),
        "a hit returns the same analysis"
    );

    // A second's disagreement is the catalogue's whole seconds against the
    // decoder's exact length for the same file: still a hit.
    let _ = analysis_cache::get_or_compute(&key, false, 90.6, &mut compute);
    assert_eq!(computed.load(Ordering::SeqCst), 1, "the same file under a rounded length is a hit");

    let _ = analysis_cache::get_or_compute(&key, false, 120.0, &mut compute);
    assert_eq!(
        computed.load(Ordering::SeqCst),
        2,
        "a materially different duration must be analysed again"
    );

    // The same path with more bytes is a different file as far as planning
    // is concerned.
    std::fs::write(&path, vec![0u8; 2048]).unwrap();
    let _ = analysis_cache::get_or_compute(&key, false, 90.0, &mut compute);
    assert_eq!(
        computed.load(Ordering::SeqCst),
        3,
        "a grown file must be analysed again, not served from the cache"
    );

    // The vocal-model switch is part of the identity too.
    let _ = analysis_cache::get_or_compute(&key, true, 90.0, &mut compute);
    assert_eq!(computed.load(Ordering::SeqCst), 4);
}

#[test]
fn disk_cache_hit_skips_compute_and_corrupt_entry_is_rewritten() {
    let dir = std::env::temp_dir().join(format!("bitchord-analysis-disk-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    analysis_cache::set_test_disk_dir(dir.clone());
    let source = dir.join("source-audio");
    std::fs::write(&source, b"audio identity").unwrap();
    let path = source.to_string_lossy().to_string();
    let calls = AtomicUsize::new(0);
    let first = analysis_cache::get_or_compute(&path, false, 120.0, || {
        calls.fetch_add(1, Ordering::SeqCst);
        Analysis {
            bpm: 123.0,
            ..Analysis::default()
        }
    });
    analysis_cache::clear();
    let second = analysis_cache::get_or_compute(&path, false, 120.0, || {
        calls.fetch_add(1, Ordering::SeqCst);
        Analysis::default()
    });
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "disk hit skips analysis/decode"
    );
    assert_eq!(second.bpm, first.bpm);

    analysis_cache::clear();
    let after_model_change = analysis_cache::get_or_compute_for_identity(
        &path,
        false,
        120.0,
        "changed-model".into(),
        || {
            calls.fetch_add(1, Ordering::SeqCst);
            Analysis {
                bpm: 125.0,
                ..Analysis::default()
            }
        },
    );
    assert_eq!(
        calls.load(Ordering::SeqCst),
        2,
        "model digest change must miss"
    );
    assert_eq!(after_model_change.bpm, 125.0);

    let (size, modified) = analysis_cache::file_identity(&path);
    let key = (
        path.clone(),
        size,
        modified,
        120.0f64.to_bits(),
        crate::analyzer::models::analysis_identity(),
        false,
    );
    std::fs::write(
        dir.join(format!("{}.json", analysis_cache::disk_key(&key))),
        b"{",
    )
    .unwrap();
    analysis_cache::clear();
    let repaired = analysis_cache::get_or_compute(&path, false, 120.0, || {
        calls.fetch_add(1, Ordering::SeqCst);
        Analysis {
            bpm: 124.0,
            ..Analysis::default()
        }
    });
    assert_eq!(
        calls.load(Ordering::SeqCst),
        3,
        "corruption must miss and recompute"
    );
    assert_eq!(repaired.bpm, 124.0);
    assert!(serde_json::from_slice::<Analysis>(
        &std::fs::read(dir.join(format!("{}.json", analysis_cache::disk_key(&key)))).unwrap()
    )
    .is_ok());

    let degraded_source = dir.join("degraded-source");
    std::fs::write(&degraded_source, b"temporary short read").unwrap();
    let degraded_path = degraded_source.to_string_lossy().to_string();
    analysis_cache::clear();
    let degraded = analysis_cache::get_or_compute(&degraded_path, false, 120.0, || {
        calls.fetch_add(1, Ordering::SeqCst);
        Analysis::default()
    });
    assert_eq!(degraded.bpm, 0.0);
    let (size, modified) = analysis_cache::file_identity(&degraded_path);
    let degraded_key = (
        degraded_path.clone(),
        size,
        modified,
        120.0f64.to_bits(),
        crate::analyzer::models::analysis_identity(),
        false,
    );
    assert!(
        !dir.join(format!("{}.json", analysis_cache::disk_key(&degraded_key)))
            .exists(),
        "degraded results are memory-only"
    );
    analysis_cache::clear();
    let retried = analysis_cache::get_or_compute(&degraded_path, false, 120.0, || {
        calls.fetch_add(1, Ordering::SeqCst);
        Analysis {
            bpm: 127.0,
            ..Analysis::default()
        }
    });
    assert_eq!(
        calls.load(Ordering::SeqCst),
        5,
        "a degraded result must be recomputed next time"
    );
    assert_eq!(retried.bpm, 127.0);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn analysis_cache_coalesces_same_key_while_distinct_keys_compute_concurrently() {
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let prefix = format!(
        "cache-single-flight-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let path_a = format!("{prefix}-a");
    let path_b = format!("{prefix}-b");
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_a_tx, release_a_rx) = mpsc::channel();
    let (release_b_tx, release_b_rx) = mpsc::channel();
    let duplicate_calls = Arc::new(AtomicUsize::new(0));

    let entered_a = entered_tx.clone();
    let a = thread::spawn(move || {
        analysis_cache::get_or_compute_for_identity(
            &path_a,
            false,
            0.0,
            "flight-test".into(),
            || {
                entered_a.send("a").unwrap();
                release_a_rx.recv().unwrap();
                Analysis {
                    bpm: 101.0,
                    ..Analysis::default()
                }
            },
        )
    });
    assert_eq!(
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        "a"
    );

    let duplicate_path = format!("{prefix}-a");
    let duplicate_calls_in_thread = duplicate_calls.clone();
    let duplicate = thread::spawn(move || {
        analysis_cache::get_or_compute_for_identity(
            &duplicate_path,
            false,
            0.0,
            "flight-test".into(),
            || {
                duplicate_calls_in_thread.fetch_add(1, Ordering::SeqCst);
                Analysis {
                    bpm: 202.0,
                    ..Analysis::default()
                }
            },
        )
    });

    let entered_b = entered_tx.clone();
    let b = thread::spawn(move || {
        analysis_cache::get_or_compute_for_identity(
            &path_b,
            false,
            0.0,
            "flight-test".into(),
            || {
                entered_b.send("b").unwrap();
                release_b_rx.recv().unwrap();
                Analysis {
                    bpm: 303.0,
                    ..Analysis::default()
                }
            },
        )
    });
    let distinct_key_started = entered_rx.recv_timeout(Duration::from_secs(2)) == Ok("b");

    // Always unblock the compute closures before asserting, including when a
    // regression serializes independent keys behind the global cache mutex.
    let _ = release_a_tx.send(());
    let _ = release_b_tx.send(());
    let a_result = a.join().unwrap();
    let duplicate_result = duplicate.join().unwrap();
    let b_result = b.join().unwrap();

    assert!(
        distinct_key_started,
        "different keys should compute concurrently"
    );
    assert_eq!(
        duplicate_calls.load(Ordering::SeqCst),
        0,
        "same-key work should coalesce"
    );
    assert!(Arc::ptr_eq(&a_result, &duplicate_result));
    assert_eq!(a_result.bpm, 101.0);
    assert_eq!(b_result.bpm, 303.0);
}

#[test]
fn partial_whole_track_decode_is_not_published_as_a_silent_tail() {
    let rate = audio_analysis::ANALYSIS_RATE as u32;
    // 96% is above the broad coverage ratio but still leaves 0.4 s of a
    // short track undecoded; it must not be interpreted as terminal silence.
    let partial = vec![0.2f32; rate as usize * 96 / 10];
    let analyzed = analyze(
        "growing-source",
        true,
        &|_, _, _, _| Some((partial.clone(), rate, 0.0)),
        10.0,
    );

    assert_eq!(analyzed.duration, 10.0);
    assert_eq!(analyzed.content_end, 0.0);
    assert!(analyzed.analysis_source.is_empty());
}

#[test]
fn supplied_stream_duration_beats_local_tag_probe_fallback() {
    let outgoing = "https://audio.example.test/outgoing.m4a";
    let incoming = "https://audio.example.test/incoming.m4a";
    let plan = plan_pair(
        outgoing,
        incoming,
        "spoken podcast episode",
        "",
        false,
        8.0,
        83.0,
        91.0,
        true,
        "test",
        true,
        |_, _, _, _| None,
        |_| 0.0,
    );

    // The caller knows the stream's duration even though a local tag probe
    // cannot open its URL. Keeping that duration anchors the safety fade
    // and lets non-blocked stream pairs run whole-track analysis.
    assert_eq!(plan.outgoing_duration_seconds, 83.0);
    assert_eq!(plan.transition_end_seconds, 83.0);
}

/// The model windows override only their own ranges: the head and the tail
/// are merged independently, and the DSP heuristic stands between them.
#[test]
fn a_model_window_overrides_only_its_own_range() {
    let mut a = analysis(0.0, 10.0, vec![0.0, 2.0, 4.0]);
    with_energy(&mut a, 10.0, |_| 0.8);
    for value in a.vocal_activity_mask.iter_mut() {
        *value = 0.8; // the DSP heuristic this test stands in for
    }
    let head = vec![0.05f32; 50]; // ≈ 1.16 s at the model's hop
    merge_open_unmix_window(&mut a, &head, 0.0);
    let tail = vec![0.9f32; 50];
    merge_open_unmix_window(&mut a, &tail, 8.0);
    let at = |time: f64| a.vocal_activity_mask[(time / 0.1) as usize];
    assert!(at(0.5) < 0.1, "head {}", at(0.5));
    assert!((at(5.0) - 0.8).abs() < 1e-9, "middle {}", at(5.0));
    assert!(at(8.5) > 0.8, "tail {}", at(8.5));
}

#[test]
fn overlay_skips_half_tempo_when_beat_this_grid_is_trusted() {
    let mut analysis = matched(0.5, 200.0);
    analysis.bpm = 148.7;
    analysis.beat_interval = 60.0 / 148.7;
    analysis.beat_confidence = 0.75;
    analysis.downbeats = vec![0.0, 1.615, 3.23];
    analysis.analysis_source = "beat_this".into();
    analysis.key = "C minor".into();
    apply_overlay(
        &mut analysis,
        &AnalysisOverlay {
            bpm: Some(74.5),
            beat_confidence: Some(0.85),
            beat_interval: Some(60.0 / 74.5),
            beats: None,
            downbeats: Some(vec![0.0, 3.23]),
            key: Some("C minor".into()),
            key_confidence: Some(0.8),
            phrase_boundaries: Some(vec![8.0, 16.0]),
            vocal_probability: None,
            content_end: None,
            audible_start: None,
            outro_start: None,
            mix_in_time: None,
            source: "music_understanding".into(),
        },
    );
    assert!(
        (analysis.bpm - 148.7).abs() < 0.01,
        "kept Beat This tempo, got {}",
        analysis.bpm
    );
    assert_eq!(analysis.phrase_boundaries, vec![8.0, 16.0]);
    assert!(analysis.analysis_source.contains("music_understanding"));
}

#[test]
fn next_energy_dip_detects_local_valley_in_window() {
    let curve = vec![
        super::audio_analysis::EnergyPoint {
            time: 0.0,
            energy: 0.9,
        },
        super::audio_analysis::EnergyPoint {
            time: 0.5,
            energy: 0.8,
        },
        super::audio_analysis::EnergyPoint {
            time: 1.0,
            energy: 0.25,
        }, // dip
        super::audio_analysis::EnergyPoint {
            time: 1.5,
            energy: 0.75,
        },
        super::audio_analysis::EnergyPoint {
            time: 2.0,
            energy: 0.85,
        },
    ];
    // At position 0.0, window is [0.1, 2.0]. Local minimum at 1.0s.
    let dip = find_next_energy_dip(&curve, 0.0);
    assert_eq!(dip, Some(1.0));

    // When flat: no dip found
    let flat_curve = vec![
        super::audio_analysis::EnergyPoint {
            time: 0.0,
            energy: 0.9,
        },
        super::audio_analysis::EnergyPoint {
            time: 0.5,
            energy: 0.91,
        },
        super::audio_analysis::EnergyPoint {
            time: 1.0,
            energy: 0.92,
        },
        super::audio_analysis::EnergyPoint {
            time: 1.5,
            energy: 0.90,
        },
    ];
    assert_eq!(find_next_energy_dip(&flat_curve, 0.0), None);
}
