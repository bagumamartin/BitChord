use super::analysis::{
    analyze, fold_tempo, merge_open_unmix_window, reconcile_grid, Analysis, Tier,
};
use super::bridge::apply_bridge;
use super::cache::find_next_energy_dip;
use super::cache::{analysis_cache, apply_overlay};
use super::choose::{effect_earned, plan_from};
use super::cue::{cue_for, incoming_cue, incoming_entry, realized_window, record_transition_edges};
use super::edges::{
    assess, final_chord_attack, normalized_tempo_ratio, respect_music_edges, section_fade_cap,
    tempo_summary, transparent_playback_rate,
};
use super::key::{camelot, harmonically_compatible, key_distance, keys_clash, trusted_key};
use super::mix_out::{bass_swap_fraction_for, resolve_mix_out_anchor};
use super::technique::{
    clean_crossfade, note_technique, recent_techniques, EFFECT_INTRO_BEATS,
    EFFECT_INTRO_KEY_CLASH_DB, EFFECT_INTRO_MIN_SECONDS,
};
use super::vocal_overlap::{is_vocal_clash, vocal_activity_between};
use super::wsola::phrase_switch;
use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

mod bridges;
mod cache;
mod crossfade;
mod cues;
mod edges;
mod grid;
mod keys;
mod mix_out;
mod techniques;
mod tempo;
mod vocals;

/// A track whose music starts at `first_beat`, on a 120 BPM grid. The
/// pickup is reported the way the real analysis reports it — as both the
/// envelope's `audible_start` and the grid's `first_beat` — because the
/// cue is derived from whichever of them is earliest.
fn analysis(first_beat: f64, duration: f64, downbeats: Vec<f64>) -> Analysis {
    Analysis {
        first_beat,
        audible_start_time: first_beat,
        duration,
        downbeats,
        bpm: 120.0,
        beat_interval: 0.5,
        ..Analysis::default()
    }
}

/// An energy curve and a vocal mask at 0.5 s resolution, so the vocal
/// windows a handover reads have something to read.
fn with_vocal_curve(a: &mut Analysis, seconds: f64, mask: f64) {
    let points = (0..((seconds / 0.5) as usize))
        .map(|index| audio_analysis::EnergyPoint {
            time: index as f64 * 0.5,
            energy: 0.8,
        })
        .collect::<Vec<_>>();
    a.vocal_activity_mask = vec![mask; points.len()];
    a.energy_curve = points;
}

/// A curve at one energy, then `tail` seconds of it falling away to 0.05.
fn with_falling_tail(a: &mut Analysis, seconds: f64, tail: f64) {
    let points = (0..((seconds / 0.5) as usize))
        .map(|index| {
            let time = index as f64 * 0.5;
            let energy = if time < seconds - tail {
                0.8
            } else {
                0.8 * (1.0 - (time - (seconds - tail)) / tail).max(0.06)
            };
            audio_analysis::EnergyPoint { time, energy }
        })
        .collect::<Vec<_>>();
    a.energy_curve = points;
    a.vocal_activity_mask = vec![0.5; a.energy_curve.len()];
}

fn flat_out_and_tempo_gap(seconds: f64, bpm: f64, incoming_bpm: f64) -> (Analysis, Analysis) {
    let mut out = analysis(0.0, seconds + 5.0, vec![0.0, 2.0, 4.0]);
    out.bpm = bpm;
    out.beat_interval = 60.0 / bpm;
    out.beat_confidence = 0.8;
    out.content_end = seconds;
    with_vocal_curve(&mut out, seconds + 5.0, 0.5);
    let mut inc = analysis(0.0, seconds, vec![0.0, 2.0, 4.0]);
    inc.bpm = incoming_bpm;
    inc.beat_interval = 60.0 / incoming_bpm;
    inc.beat_confidence = 0.8;
    with_vocal_curve(&mut inc, seconds, 0.5);
    (out, inc)
}

fn matched(first_beat: f64, duration: f64) -> Analysis {
    let step = 0.5;
    let downbeats: Vec<f64> = (0..((duration / step) as usize))
        .map(|i| first_beat + i as f64 * step)
        .filter(|t| *t < duration)
        .collect();
    let mut track = analysis(first_beat, duration, downbeats);
    track.beat_confidence = 0.9;
    track.content_end = duration;
    track.key = "C major".into();
    track.key_confidence = 0.9;
    track
}

/// A 100 ms energy curve, the resolution the E heuristics read.
fn with_energy(a: &mut Analysis, seconds: f64, energy: impl Fn(f64) -> f64) {
    let points = (0..((seconds / 0.1) as usize))
        .map(|index| {
            let time = index as f64 * 0.1;
            super::audio_analysis::EnergyPoint {
                time,
                energy: energy(time),
            }
        })
        .collect::<Vec<_>>();
    a.vocal_activity_mask = vec![0.0; points.len()];
    a.energy_curve = points;
}

fn edge_plan(end: f64, fade: f64, cue: f64) -> TransitionPlan {
    TransitionPlan {
        style: TransitionStyle::EqualPower,
        fade_seconds: fade,
        transition_end_seconds: end,
        cue_seconds: cue,
        ..Default::default()
    }
}

fn test_grid(bpm: f64, bars: Vec<f64>, beats: Vec<f64>) -> crate::analyzer::beat::Grid {
    crate::analyzer::beat::Grid {
        beats,
        downbeats: bars,
        bpm,
        beat_interval: 60.0 / bpm,
        first_beat: 0.0,
        beat_confidence: 0.8,
        backend: crate::analyzer::beat::BeatBackend::Rten,
    }
}
