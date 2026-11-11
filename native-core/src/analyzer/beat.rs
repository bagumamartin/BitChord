//! Port of upstream `BeatTracker.kt` — Beat This! over the Slaney mel spectrogram.

use super::models;
use super::{
    compute_beat_spectrogram, resample, BeatAccelerator,
    BEAT_SPECTROGRAM_MELS, BEAT_SPECTROGRAM_SAMPLE_RATE,
};

use rten_tensor::NdTensor;

pub const CHUNK_FRAMES: usize = 1500;
pub const BORDER_FRAMES: usize = 6;
pub const WINDOW_SECONDS: f64 = (CHUNK_FRAMES - 2 * BORDER_FRAMES) as f64 / 50.0;
/// The head window when the accelerator is registered: a few frames past one
/// whole chunk. [`WINDOW_SECONDS`] spectrograms to 1489 frames, eleven short of
/// the accelerator's fixed 1500, so every head-window pass fell back to rten
/// and ran the transformer on the CPU as one uninterruptible 1.7 s step — the
/// tallest spike in a transition. The extra 0.3 s of audio is inside the
/// model's own training window; rten still gets [`WINDOW_SECONDS`] so its
/// variable-length pass costs what it always did.
pub const ACCELERATED_WINDOW_SECONDS: f64 = (CHUNK_FRAMES + 4) as f64 / FRAME_RATE;

/// The head window for the backend that will read it.
pub fn head_window_seconds() -> f64 {
    if models::accelerator().is_some() {
        ACCELERATED_WINDOW_SECONDS
    } else {
        WINDOW_SECONDS
    }
}
const PEAK_WINDOW: i32 = 7;
/// Frames two accepted peaks must be apart; see [`pick_peaks`].
const PEAK_MIN_SPACING: i32 = 6;
const MIN_BEATS: usize = 8;
const MIN_TEMPO: f64 = 40.0;
const MAX_TEMPO: f64 = 220.0;
const FRAME_RATE: f64 = 50.0;

/// The graph that produced a grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BeatBackend {
    Rten,
    CoreML,
}

impl BeatBackend {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rten => "rten",
            Self::CoreML => "coreml",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Grid {
    pub beats: Vec<f64>,
    pub downbeats: Vec<f64>,
    pub bpm: f64,
    pub beat_interval: f64,
    pub first_beat: f64,
    pub beat_confidence: f64,
    pub backend: BeatBackend,
}

/// One inference window and the frames of its output the caller keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Chunk {
    start: usize,
    length: usize,
    keep_from: usize,
    keep_to: usize,
}

struct Inference {
    beat: Vec<f32>,
    downbeat: Vec<f32>,
    backend: BeatBackend,
}

/// Track [pcm] already at any rate; resampled to the model's 22.05 kHz mono.
///
/// The whole buffer is tried first, because the end of the outgoing record is
/// where a blend is decided and a head-only grid leaves it on the DSP
/// estimator. When that pass yields nothing usable, the head window is tried
/// before giving up: over a whole track the assembled beat set can go dense
/// (one busy or spoken section is enough), and the model read the same audio
/// as a single chunk of [`WINDOW_SECONDS`] just fine. Discarding that grid
/// because the longer read failed is how nine of the thirteen cached tracks
/// in the corpus ended up planned from a 0.3-confidence DSP tempo.
pub fn track(pcm: &[f32], sample_rate: f64, offset_seconds: f64) -> Option<Grid> {
    if !models::analyzer_ready() { return None; }
    best_grid(
        grid_from_pcm(pcm, sample_rate, offset_seconds),
        || {
            let head_samples = (head_window_seconds() * sample_rate).round() as usize;
            // Already the head window (or shorter): there is nothing to retry.
            (head_samples > 0 && head_samples < pcm.len())
                .then(|| grid_from_pcm(&pcm[..head_samples], sample_rate, offset_seconds))
                .flatten()
        },
    )
}

/// The whole-track grid when it is usable, otherwise the head window's.
fn best_grid(whole: Option<Grid>, head: impl FnOnce() -> Option<Grid>) -> Option<Grid> {
    if whole.is_some() {
        return whole;
    }
    let head = head();
    if head.is_some() {
        log::info!(
            "automix analysis: the whole-track beat pass yielded no usable grid; \
             the head window's grid is used instead"
        );
    }
    head
}

fn grid_from_pcm(pcm: &[f32], sample_rate: f64, offset_seconds: f64) -> Option<Grid> {
    if pcm.is_empty() {
        return None;
    }
    let mono = if (sample_rate - BEAT_SPECTROGRAM_SAMPLE_RATE).abs() > 1.0 {
        std::borrow::Cow::Owned(resample(pcm, sample_rate, BEAT_SPECTROGRAM_SAMPLE_RATE))
    } else {
        std::borrow::Cow::Borrowed(pcm)
    };
    let spectrogram = compute_beat_spectrogram(&mono, BEAT_SPECTROGRAM_SAMPLE_RATE);
    if spectrogram.frames == 0 {
        return None;
    }
    let inference = infer(&spectrogram.values, spectrogram.frames)?;
    let beat_logits = inference.beat;
    let downbeat_logits = inference.downbeat;
    let beat_frames = pick_peaks(&beat_logits);
    let beats: Vec<f64> = beat_frames
        .iter()
        .map(|f| f / FRAME_RATE + offset_seconds)
        .collect();
    if beats.len() < MIN_BEATS {
        return None;
    }
    let bpm = tempo_from_beats(&beats);
    if bpm <= 0.0 {
        return None;
    }
    let mut downbeats: Vec<f64> = pick_peaks(&downbeat_logits)
        .into_iter()
        .map(|f| f / FRAME_RATE + offset_seconds)
        .map(|time| {
            beats
                .iter()
                .min_by(|a, b| (*a - time).abs().total_cmp(&(*b - time).abs()))
                .copied()
                .unwrap_or(beats[0])
        })
        .collect();
    downbeats.sort_by(|a, b| a.total_cmp(b));
    downbeats.dedup_by(|a, b| (*a - *b).abs() < 1e-4);

    // F-2: the Beat This! downbeat head is conservative — 23 bars over a
    // 188 s track at 93 BPM is about a third of the bars that exist — so the
    // missing bars are derived from the **measured beats**: each trusted model
    // downbeat anchors a chain that walks four beats at a time (each step
    // within 15 ms of the grid) and stops at the first gap it cannot measure.
    // That is measured bar counting, not bpm × 4: the bar times come from the
    // beat timestamps. Over-dense model heads are left alone.
    let interval = 60.0 / bpm;
    let span_bars = if beats.len() >= 5 && interval > 0.0 {
        ((beats[beats.len() - 1] - beats[0]) / (4.0 * interval)).round() as usize + 1
    } else {
        0
    };
    let model_bars = downbeats.len();
    if span_bars >= 4 && model_bars * 4 < span_bars * 3 {
        let derived = derive_bars(&beats, interval, &downbeats);
        let mut merged: Vec<f64> = downbeats.iter().copied().chain(derived).collect();
        merged.sort_by(|a, b| a.total_cmp(b));
        merged.dedup_by(|a, b| (*a - *b).abs() < 0.05);
        log::debug!(
            "downbeat grid: beats={} model bars={} derived bars={} of ~{} expected",
            beats.len(),
            model_bars,
            merged.len().saturating_sub(model_bars),
            span_bars
        );
        downbeats = merged;
    }

    let peak_logits: Vec<f64> = beat_frames
        .iter()
        .map(|frame| {
            let i = frame.round() as isize;
            if i >= 0 && (i as usize) < beat_logits.len() {
                beat_logits[i as usize] as f64
            } else {
                0.0
            }
        })
        .collect();

    Some(Grid {
        bpm,
        beat_interval: 60.0 / bpm,
        first_beat: beats[0],
        beat_confidence: grid_confidence(&beats, &peak_logits),
        beats,
        downbeats,
        backend: inference.backend,
    })
}

fn infer(values: &[f32], frames: usize) -> Option<Inference> {
    let accelerator = models::accelerator();
    if let Some(inference) = try_accelerated(values, frames, accelerator.as_deref()) {
        return Some(inference);
    }
    // The rten pass keeps its model lock for the whole track, as before: a
    // reconfiguration mid-pass must not hand one analysis two different graphs.
    models::with_beat(|model| infer_chunks(model, values, frames))
        .flatten()
        .map(|(beat, downbeat)| Inference {
            beat,
            downbeat,
            backend: BeatBackend::Rten,
        })
}

/// Run the whole beat pass on the host backend, or `None` when it cannot run.
///
/// The accelerator needs a fixed 1500-frame window, so a shorter track never
/// reaches it; rten handles those with a variable-length input. A `None` here is
/// final for the call: the caller discards any logits already produced and
/// recomputes the track from frame zero on rten.
fn try_accelerated(
    values: &[f32],
    frames: usize,
    accelerator: Option<&dyn BeatAccelerator>,
) -> Option<Inference> {
    if frames < CHUNK_FRAMES {
        return None;
    }
    let accelerator = accelerator?;
    let inference = infer_accelerated(accelerator, values, frames);
    if inference.is_none() {
        log::warn!(
            "automix: accelerated beat pass failed; the whole track is recomputed on rten"
        );
    }
    inference
}

fn infer_accelerated(
    accelerator: &dyn BeatAccelerator,
    values: &[f32],
    frames: usize,
) -> Option<Inference> {
    let mels = BEAT_SPECTROGRAM_MELS;
    let plan = accelerator_chunk_plan(frames);
    if plan.is_empty() {
        return None;
    }
    let mut beat_logits = vec![0.0f32; frames];
    let mut downbeat_logits = vec![0.0f32; frames];
    for chunk in plan {
        let window = super::f32_le_bytes(
            values.get(chunk.start * mels..(chunk.start + chunk.length) * mels)?,
        );
        let logits = accelerator.infer(window)?;
        crate::pace::tick();
        let beats = super::f32_from_le_bytes(&logits.beat)?;
        let downbeats = super::f32_from_le_bytes(&logits.downbeat)?;
        if beats.len() < chunk.length || downbeats.len() < chunk.length {
            return None;
        }
        for index in chunk.keep_from..chunk.keep_to {
            let target = chunk.start + index;
            if target >= frames {
                break;
            }
            let beat = beats[index];
            let downbeat = downbeats[index];
            if !beat.is_finite() || !downbeat.is_finite() {
                return None;
            }
            beat_logits[target] = beat;
            downbeat_logits[target] = downbeat;
        }
    }
    Some(Inference {
        beat: beat_logits,
        downbeat: downbeat_logits,
        backend: BeatBackend::CoreML,
    })
}

/// The accelerated chunk plan: as many full windows as rten would use, then one
/// window right-aligned to the track end.
///
/// The final window starts at `frames - CHUNK_FRAMES` instead of running off the
/// end, because the transformer attends to the whole window and zero-padding the
/// tail would change what it reads. Its first frames are already covered by the
/// previous window, so only the uncovered tail is kept; the border stays the
/// same six frames as everywhere else.
fn accelerator_chunk_plan(frames: usize) -> Vec<Chunk> {
    if frames < CHUNK_FRAMES {
        return Vec::new();
    }
    let stride = CHUNK_FRAMES - 2 * BORDER_FRAMES;
    let mut plan = Vec::new();
    let mut covered = 0usize;
    let mut start = 0usize;
    while start + CHUNK_FRAMES < frames {
        plan.push(Chunk {
            start,
            length: CHUNK_FRAMES,
            keep_from: if start == 0 { 0 } else { BORDER_FRAMES },
            keep_to: CHUNK_FRAMES - BORDER_FRAMES,
        });
        covered = start + CHUNK_FRAMES - BORDER_FRAMES;
        start += stride;
    }
    let start = frames - CHUNK_FRAMES;
    let keep_from = if covered == 0 {
        0
    } else {
        BORDER_FRAMES.max(covered.saturating_sub(start))
    };
    plan.push(Chunk {
        start,
        length: CHUNK_FRAMES,
        keep_from,
        keep_to: CHUNK_FRAMES,
    });
    plan
}

/// The rten chunk plan, unchanged: a window every 1488 frames, with the last one
/// as short as the track needs, and six frames of context trimmed at each
/// interior edge.
fn rten_chunk_plan(frames: usize) -> Vec<Chunk> {
    let stride = CHUNK_FRAMES - 2 * BORDER_FRAMES;
    let mut plan = Vec::new();
    let mut start = 0usize;
    while start < frames {
        let length = CHUNK_FRAMES.min(frames - start);
        if length <= 2 * BORDER_FRAMES && start > 0 {
            break;
        }
        let last = start + length >= frames;
        plan.push(Chunk {
            start,
            length,
            keep_from: if start == 0 { 0 } else { BORDER_FRAMES },
            keep_to: if last { length } else { length.saturating_sub(BORDER_FRAMES) },
        });
        if last {
            break;
        }
        start += stride;
    }
    plan
}

fn infer_chunks(
    model: &rten::Model,
    values: &[f32],
    frames: usize,
) -> Option<(Vec<f32>, Vec<f32>)> {
    let input_id = *model.input_ids().first()?;
    infer_rten_chunks(frames, |start, length| {
        run_chunk(model, input_id, values, start, length)
    })
}

fn run_chunk(
    model: &rten::Model,
    input_id: rten::NodeId,
    values: &[f32],
    start: usize,
    length: usize,
) -> Option<(Vec<f32>, Vec<f32>)> {
    let mels = BEAT_SPECTROGRAM_MELS;
    let chunk = values.get(start * mels..(start + length) * mels)?.to_vec();
    let tensor = NdTensor::from_data([1, length, mels], chunk);
    let outputs = model
        .run(vec![(input_id, tensor.into())], model.output_ids(), Some(models::run_options()))
        .ok()?;
    if outputs.len() < 2 {
        return None;
    }
    Some((flatten_f32(&outputs[0])?, flatten_f32(&outputs[1])?))
}

fn infer_rten_chunks(
    frames: usize,
    mut run: impl FnMut(usize, usize) -> Option<(Vec<f32>, Vec<f32>)>,
) -> Option<(Vec<f32>, Vec<f32>)> {
    let mut beat_logits = vec![0.0f32; frames];
    let mut downbeat_logits = vec![0.0f32; frames];
    for chunk in rten_chunk_plan(frames) {
        let (beat, downbeat) = run(chunk.start, chunk.length)?;
        for index in chunk.keep_from..chunk.keep_to {
            let target = chunk.start + index;
            if target >= frames {
                break;
            }
            if index < beat.len() {
                beat_logits[target] = beat[index];
            }
            if index < downbeat.len() {
                downbeat_logits[target] = downbeat[index];
            }
        }
    }
    Some((beat_logits, downbeat_logits))
}

fn flatten_f32(value: &rten::Value) -> Option<Vec<f32>> {
    super::models::flatten_f32(value)
}

/// Frame indices that are local maxima over [PEAK_WINDOW] and positive.
pub fn pick_peaks(logits: &[f32]) -> Vec<f64> {
    let half = PEAK_WINDOW / 2;
    let mut peaks = Vec::new();
    for index in 0..logits.len() {
        if logits[index] <= 0.0 {
            continue;
        }
        let mut is_maximum = true;
        for offset in -half..=half {
            let neighbour = index as i32 + offset;
            if neighbour < 0 || neighbour as usize >= logits.len() {
                continue;
            }
            if logits[neighbour as usize] > logits[index] {
                is_maximum = false;
                break;
            }
        }
        if is_maximum {
            peaks.push(index as i32);
        }
    }

    let mut deduped = Vec::new();
    let mut index = 0usize;
    while index < peaks.len() {
        let mut mean = peaks[index] as f64;
        let mut count = 1.0;
        while index + 1 < peaks.len() && (peaks[index + 1] as f64 - mean) <= 1.0 {
            index += 1;
            count += 1.0;
            mean += (peaks[index] as f64 - mean) / count;
        }
        deduped.push(mean.round() as usize);
        index += 1;
    }

    // A busy section can make almost every frame a local maximum, which halves
    // the median gap below and reads as an octave error or as a tempo out of
    // range. Two beats of any tempo the planner accepts are 13 frames apart at
    // the fastest (220 BPM), so anything closer than six frames is either one
    // beat counted twice or a spurious maximum — keep the stronger of the pair.
    let mut spaced: Vec<usize> = Vec::with_capacity(deduped.len());
    for frame in deduped {
        match spaced.last().copied() {
            Some(previous) if (frame as i32 - previous as i32) < PEAK_MIN_SPACING => {
                if logits[frame] > logits[previous] {
                    spaced.pop();
                    spaced.push(frame);
                }
            }
            _ => spaced.push(frame),
        }
    }

    spaced
        .into_iter()
        .map(|frame| {
            if frame == 0 || frame + 1 >= logits.len() {
                return frame as f64;
            }
            let left = logits[frame - 1] as f64;
            let centre = logits[frame] as f64;
            let right = logits[frame + 1] as f64;
            let denominator = left - 2.0 * centre + right;
            if denominator.abs() <= 1e-9 {
                return frame as f64;
            }
            frame as f64 + (0.5 * (left - right) / denominator).clamp(-0.5, 0.5)
        })
        .collect()
}

pub fn tempo_from_beats(beats: &[f64]) -> f64 {
    if beats.len() < MIN_BEATS {
        return 0.0;
    }
    let gaps: Vec<f64> = beats.windows(2).map(|w| w[1] - w[0]).collect();
    let rough = median(&gaps);
    if rough <= 0.0 {
        return 0.0;
    }
    let kept: Vec<f64> = gaps
        .iter()
        .copied()
        .filter(|g| (g - rough).abs() <= rough * 0.2)
        .collect();
    let interval = median(if kept.len() >= 4 { &kept } else { &gaps });
    if interval <= 0.0 {
        return 0.0;
    }
    let bpm = 60.0 / interval;
    if (MIN_TEMPO..=MAX_TEMPO).contains(&bpm) {
        bpm
    } else {
        0.0
    }
}

pub fn grid_confidence(beats: &[f64], peak_logits: &[f64]) -> f64 {
    if beats.len() < MIN_BEATS {
        return 0.0;
    }
    let gaps: Vec<f64> = beats.windows(2).map(|w| w[1] - w[0]).collect();
    let interval = median(&gaps);
    if interval <= 0.0 {
        return 0.0;
    }
    let regular = gaps
        .iter()
        .filter(|g| (*g - interval).abs() <= interval * 0.1)
        .count() as f64
        / gaps.len() as f64;
    let strength = 1.0 / (1.0 + (-(median(peak_logits) - 0.5)).exp());
    (0.35 + 0.4 * regular + 0.25 * strength).clamp(0.0, 0.95)
}

/// F-2's missing-bar derivation.
///
/// Each trusted model downbeat anchors a chain: four measured beats later is
/// the next bar, and so on. A step is only accepted when all four gaps in the
/// group are within 15 ms of the grid (the model's own beat interval), so a
/// missing or smeared beat stops the chain instead of inventing a bar; the
/// next trusted model downbeat starts a new one. Both directions are walked so
/// the bars before an anchor are filled too.
fn derive_bars(beats: &[f64], interval: f64, trusted: &[f64]) -> Vec<f64> {
    if beats.len() < 5 || interval <= 0.0 {
        return Vec::new();
    }
    let regular = |start: usize| -> bool {
        if start + 4 >= beats.len() {
            return false;
        }
        (0..4).all(|k| ((beats[start + k + 1] - beats[start + k]) - interval).abs() <= 0.015)
    };
    let nearest = |time: f64| -> Option<usize> {
        beats
            .iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| (*a - time).abs().total_cmp(&(*b - time).abs()))
            .and_then(|(index, beat)| ((beat - time).abs() <= 0.03).then_some(index))
    };
    let mut bars = Vec::new();
    for &anchor in trusted {
        let Some(anchor_index) = nearest(anchor) else {
            continue;
        };
        bars.push(beats[anchor_index]);
        let mut forward = anchor_index;
        while regular(forward) {
            forward += 4;
            bars.push(beats[forward]);
        }
        let mut back = anchor_index;
        while back >= 4 && regular(back - 4) {
            back -= 4;
            bars.push(beats[back]);
        }
    }
    bars.sort_by(|a, b| a.total_cmp(b));
    bars.dedup_by(|a, b| (*a - *b).abs() < 0.05);
    bars
}

fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    sorted[sorted.len() / 2]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analyzer::BeatLogits;

    #[test]
    fn accelerated_head_window_fills_a_whole_chunk_at_any_source_rate() {
        for rate in [22_050.0, 44_100.0, 48_000.0] {
            let frames_for = |seconds: f64| {
                let pcm: Vec<f32> = (0..(seconds * rate).round() as usize)
                    .map(|i| (i as f32 * 0.01).sin() * 0.3)
                    .collect();
                let mono = resample(&pcm, rate, BEAT_SPECTROGRAM_SAMPLE_RATE);
                compute_beat_spectrogram(&mono, BEAT_SPECTROGRAM_SAMPLE_RATE).frames
            };
            let accelerated = frames_for(ACCELERATED_WINDOW_SECONDS);
            assert!(!accelerator_chunk_plan(accelerated).is_empty(), "{rate}: {accelerated} frames");
            assert!(accelerated < CHUNK_FRAMES + 2 * BORDER_FRAMES, "{rate}: {accelerated} frames");
            // The reason for the constant: the rten window never reached it.
            assert!(frames_for(WINDOW_SECONDS) < CHUNK_FRAMES);
        }
    }

    #[test]
    fn sparse_model_downbeats_are_filled_from_measured_beats() {
        // 120 BPM, a beat every 0.5 s for 40 bars; the model found only two
        // bars (0 s and 16 s). The chain should fill every 2 s bar.
        let beats: Vec<f64> = (0..161).map(|i| i as f64 * 0.5).collect();
        let trusted = vec![0.0, 16.0];
        let bars = derive_bars(&beats, 0.5, &trusted);
        assert!(bars.len() >= 40, "derived {} bars", bars.len());
        assert!((bars[20] - 40.0).abs() < 1e-6, "bar 20 at {}", bars[20]);
        assert!(bars.windows(2).all(|w| (w[1] - w[0] - 2.0).abs() < 1e-6));
    }

    #[test]
    fn a_missing_beat_stops_the_chain() {
        let mut beats: Vec<f64> = (0..81).map(|i| i as f64 * 0.5).collect();
        // Remove the beat at 10.0 s: the bars around it cannot be measured.
        beats.retain(|b| (*b - 10.0).abs() > 1e-6);
        let bars = derive_bars(&beats, 0.5, &[0.0]);
        assert!(bars.iter().all(|b| *b < 9.0 || *b > 11.0), "{bars:?}");
        assert!(bars.len() < 40, "the chain should stop at the gap");
    }

    #[test]
    fn a_drifting_beat_stops_the_chain() {
        let mut beats: Vec<f64> = (0..81).map(|i| i as f64 * 0.5).collect();
        // A 30 ms displacement at 20 s breaks the 15 ms step check.
        for beat in beats.iter_mut() {
            if *beat >= 20.0 {
                *beat += 0.03;
            }
        }
        let bars = derive_bars(&beats, 0.5, &[0.0, 40.0]);
        assert!(bars.iter().all(|b| (*b - 20.0).abs() > 1e-6), "{bars:?}");
    }

    #[test]
    fn tempo_from_regular_120_bpm_grid() {
        let beats: Vec<f64> = (0..16).map(|i| i as f64 * 0.5).collect();
        let bpm = tempo_from_beats(&beats);
        assert!((bpm - 120.0).abs() < 0.5, "bpm {bpm}");
        let conf = grid_confidence(&beats, &vec![2.0; beats.len()]);
        assert!(conf > 0.7, "conf {conf}");
    }

    fn grid_at(bpm: f64, beats: usize) -> Grid {
        let interval = 60.0 / bpm;
        Grid {
            beats: (0..beats).map(|i| i as f64 * interval).collect(),
            downbeats: (0..beats / 4).map(|i| i as f64 * interval * 4.0).collect(),
            bpm,
            beat_interval: interval,
            first_beat: 0.0,
            beat_confidence: 0.8,
            backend: BeatBackend::Rten,
        }
    }

    #[test]
    fn a_dense_beat_set_keeps_at_most_one_peak_per_six_frames() {
        // Every frame positive is the pathological shape the whole-track pass
        // produced on a busy section: without a spacing rule every frame is a
        // "peak", the median gap collapses and the tempo reads far too fast.
        let logits = vec![1.0f32; 300];
        let peaks = pick_peaks(&logits);
        assert!(peaks.len() <= 300 / 6 + 1, "{} peaks", peaks.len());
        for pair in peaks.windows(2) {
            assert!(
                pair[1] - pair[0] >= 6.0,
                "peaks {} and {} are closer than the spacing rule allows",
                pair[0],
                pair[1]
            );
        }
        let seconds: Vec<f64> = peaks.iter().map(|f| f / FRAME_RATE).collect();
        assert_eq!(tempo_from_beats(&seconds), 0.0, "a dense set is not a tempo");
    }

    #[test]
    fn a_clean_grid_keeps_every_beat() {
        // 120 BPM is 25 frames apart at 50 fps, so the spacing rule must not
        // touch a real grid.
        let mut logits = vec![0.0f32; 400];
        for index in (0..400).step_by(25) {
            logits[index] = 2.0;
        }
        let peaks: Vec<f64> = pick_peaks(&logits).iter().map(|f| f / FRAME_RATE).collect();
        assert_eq!(peaks.len(), 16);
        assert!((tempo_from_beats(&peaks) - 120.0).abs() < 1.0);
    }

    #[test]
    fn an_unusable_whole_grid_falls_back_to_the_head_window() {
        let head = grid_at(128.0, 8);
        let chosen = best_grid(None, || Some(head.clone()));
        assert!(chosen.is_some(), "the head grid must be kept");
        assert!((chosen.unwrap().bpm - 128.0).abs() < 1e-9);
    }

    #[test]
    fn a_usable_whole_grid_is_not_second_guessed() {
        let whole = grid_at(93.4, 16);
        let chosen = best_grid(Some(whole), || panic!("the head must not be consulted"));
        assert!((chosen.unwrap().bpm - 93.4).abs() < 1e-9);
    }

    // ---- Accelerated backend ------------------------------------------------

    struct FakeAccelerator {
        calls: std::sync::atomic::AtomicUsize,
        fail_at: Option<usize>,
    }

    impl FakeAccelerator {
        fn new(fail_at: Option<usize>) -> Self {
            Self {
                calls: std::sync::atomic::AtomicUsize::new(0),
                fail_at,
            }
        }

        fn calls(&self) -> usize {
            self.calls.load(std::sync::atomic::Ordering::SeqCst)
        }
    }

    impl BeatAccelerator for FakeAccelerator {
        fn infer(&self, mel: Vec<u8>) -> Option<BeatLogits> {
            let call = self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            assert_eq!(mel.len(), CHUNK_FRAMES * BEAT_SPECTROGRAM_MELS * 4);
            if self.fail_at == Some(call) {
                return None;
            }
            Some(BeatLogits {
                beat: crate::analyzer::f32_le_bytes(&vec![1.0; CHUNK_FRAMES]),
                downbeat: crate::analyzer::f32_le_bytes(&vec![0.5; CHUNK_FRAMES]),
            })
        }
    }

    #[test]
    fn accelerated_chunks_cover_every_frame_once_and_match_rten_but_for_the_tail() {
        for frames in [
            CHUNK_FRAMES,
            CHUNK_FRAMES + 1,
            1600,
            2976,
            3000,
            3400,
            5000,
        ] {
            let plan = accelerator_chunk_plan(frames);
            assert!(!plan.is_empty(), "frames {frames}");
            assert!(
                plan.iter().all(|chunk| chunk.length == CHUNK_FRAMES),
                "frames {frames}: every accelerated window is full length: {plan:?}"
            );
            let last = plan.last().unwrap();
            assert_eq!(
                last.start + CHUNK_FRAMES,
                frames,
                "frames {frames}: the last window is right-aligned"
            );

            let mut covered = vec![0u8; frames];
            for chunk in &plan {
                for frame in chunk.start + chunk.keep_from..chunk.start + chunk.keep_to {
                    covered[frame] += 1;
                }
            }
            assert!(
                covered.iter().all(|count| *count == 1),
                "frames {frames}: every frame is kept exactly once: {plan:?}"
            );

            let rten = rten_chunk_plan(frames);
            for (accelerated, regular) in plan.iter().zip(&rten).take(plan.len() - 1) {
                assert_eq!(
                    accelerated, regular,
                    "frames {frames}: everything but the tail matches rten"
                );
            }
        }
    }

    #[test]
    fn a_none_mid_track_restarts_the_whole_pass_on_rten() {
        let frames = 4000;
        let values = vec![0.0f32; frames * BEAT_SPECTROGRAM_MELS];
        // The second window fails after the first one produced logits. The
        // partial result must not survive: the rten retry starts at frame 0.
        let fake = FakeAccelerator::new(Some(1));
        assert!(try_accelerated(&values, frames, Some(&fake)).is_none());
        assert_eq!(fake.calls(), 2, "the failure is mid-track");

        let expected: Vec<(usize, usize)> = rten_chunk_plan(frames)
            .iter()
            .map(|chunk| (chunk.start, chunk.length))
            .collect();
        let mut starts = Vec::new();
        let (beat, downbeat) = infer_rten_chunks(frames, |start, length| {
            starts.push((start, length));
            Some((vec![1.0f32; length], vec![0.5f32; length]))
        })
        .unwrap();
        assert_eq!(starts, expected, "the fallback is the full rten chunk plan");
        assert_eq!(starts.first().unwrap().0, 0, "the retry starts at the beginning");
        assert_eq!(beat.len(), frames);
        assert_eq!(downbeat.len(), frames);
    }

    #[test]
    fn a_short_track_never_reaches_the_accelerator() {
        let frames = CHUNK_FRAMES - 1;
        let values = vec![0.0f32; frames * BEAT_SPECTROGRAM_MELS];
        let fake = FakeAccelerator::new(None);
        assert!(try_accelerated(&values, frames, Some(&fake)).is_none());
        assert_eq!(fake.calls(), 0, "a variable-length track stays on rten");
    }

    #[test]
    fn coreml_and_rten_analyses_have_different_cache_identities() {
        let base = "beat=aaaa;vocal=bbbb";
        let rten = models::compose_identity(base, None);
        let coreml = models::compose_identity(base, Some("cccc"));
        assert_eq!(rten, base, "no accelerator keeps the pre-Core ML cache key");
        assert_ne!(coreml, base, "a Core ML grid must not alias an rten one");
        assert!(coreml.ends_with("beat_accel=cccc"), "{coreml}");
    }
}
