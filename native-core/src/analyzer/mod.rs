//! Analyzer (spec §2): Rust port of upstream `native/analyzer` C++.
//!
//! This module carries the DSP half of the analyzer — the resampler and the
//! Slaney-mel beat spectrogram — ported from `resampler.cpp` and
//! `mel_spectrogram.cpp`, plus the ONNX inference half (Beat This! and
//! open-unmix vocals) via `rten`. Missing models fall back to the energy
//! envelope planner, matching upstream's unanalysed-pair behaviour.
//!
//! Ported from Orchard (https://github.com/SFG5453/Orchard) via BitChord's
//! `native/analyzer` — Copyright (C) 2026 SFG545, Copyright (C) 2026 Kushagra
//! Singh. The original is AGPLv3-or-later; this port keeps that status as
//! part of the same GPL-3 combined work.

mod audio_analysis;
mod beat;
mod models;
mod plan;
mod sequencer;
mod smoothness;
mod tempo;
mod vocal;

pub use beat::Grid;
pub use models::analyzer_ready;
pub(crate) use models::InferenceBudget;
pub use plan::{
    last_analysis_sources, last_transition_edges, next_energy_dip, plan_pair,
    plan_pair_with_phrase_bars,
    seed_analysis_overlay, AnalysisOverlay, TransitionEdges,
};
pub use sequencer::{rank_candidate_indices, rank_candidates, CandidateScore};
pub use smoothness::{score_plan, SmoothnessReport};

/// Beat and downbeat logits for one 1500-frame window, in the order the beat
/// tracker consumes them, each as little-endian `f32` bytes.
///
/// Bytes rather than `Vec<f32>` for the same reason as the mel window going
/// the other way: UniFFI moves a float sequence one element at a time through
/// generic Swift readers and writers, about 3 µs a value. The 192 000-value
/// window cost ~70 ms of CPU per chunk that way — some 0.6 s a track, three
/// hundred times the Neural Engine prediction it fed. Bytes cross as one copy.
#[derive(uniffi::Record, Debug, Clone)]
pub struct BeatLogits {
    pub beat: Vec<u8>,
    pub downbeat: Vec<u8>,
}

/// `values` as little-endian `f32` bytes, the accelerator bridge's layout.
pub(crate) fn f32_le_bytes(values: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(values.len() * 4);
    for value in values {
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    bytes
}

/// The inverse of [`f32_le_bytes`]; `None` for a length that is not whole floats.
pub(crate) fn f32_from_le_bytes(bytes: &[u8]) -> Option<Vec<f32>> {
    if bytes.len() % 4 != 0 {
        return None;
    }
    Some(
        bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect(),
    )
}

/// A host-side accelerated beat backend.
///
/// The native planner feeds the same 1500-frame log-mel window it would give
/// rten and receives the two logit heads back. Any failure is `None`: the
/// planner then discards the partial track and recomputes the whole pass on
/// rten, so one analysis never mixes backends.
#[uniffi::export(callback_interface)]
pub trait BeatAccelerator: Send + Sync {
    /// `mel` is the window's `1500 × 128` values as little-endian `f32` bytes,
    /// frame-major, exactly as rten reads them.
    fn infer(&self, mel: Vec<u8>) -> Option<BeatLogits>;
}

/// Refresh both graphs and discard analyses made with the previous model set.
/// A track analyzed before a first-run download must get a new beat grid when
/// the model arrives during the same listening session.
pub fn configure(beat_path: &str, vocal_path: &str) -> bool {
    let ready = models::configure(beat_path, vocal_path);
    // A reconfigured graph set must not serve stale in-memory results. Disk
    // entries remain and are naturally separated by their model digests.
    plan::clear_analysis_cache();
    ready
}

/// Register or clear the accelerated beat backend. `identity` is the digest of
/// the downloaded archive the compiled model came from, and is part of the
/// analysis cache key; an empty identity means "no accelerator".
pub fn set_beat_accelerator(accelerator: Option<Box<dyn BeatAccelerator>>, identity: String) {
    if models::set_beat_accelerator(accelerator, identity) {
        plan::clear_analysis_cache();
    }
}

const PI: f64 = core::f64::consts::PI;

pub const BEAT_SPECTROGRAM_SAMPLE_RATE: f64 = 22_050.0;
pub const BEAT_SPECTROGRAM_MELS: usize = 128;
pub const BEAT_SPECTROGRAM_FFT: usize = 1024;
pub const BEAT_SPECTROGRAM_HOP: usize = 441;
const RESAMPLER_ZERO_CROSSINGS: f64 = 32.0;
const MIN_HZ: f64 = 30.0;
const MAX_HZ: f64 = 11_000.0;
const LOG_MULTIPLIER: f64 = 1000.0;
const AMPLITUDE_FLOOR: f64 = 1e-10;

/// Offline windowed-sinc resampler — port of `Resample()` from
/// `resampler.cpp`. Used by the analysis path; the playback path uses the
/// streaming variant in `decode::resampler`.
pub fn resample(input: &[f32], input_rate: f64, output_rate: f64) -> Vec<f32> {
    resample_with(input, input_rate, output_rate, RESAMPLER_ZERO_CROSSINGS)
}

/// [`resample`] with a narrower or wider kernel: the cost is proportional to
/// `zero_crossings`, and a caller that needs no studio-grade stopband (the
/// version aligner's chroma) can trade it for speed.
pub fn resample_with(input: &[f32], input_rate: f64, output_rate: f64, zero_crossings: f64) -> Vec<f32> {
    if input.is_empty() || input_rate <= 0.0 || output_rate <= 0.0 {
        return Vec::new();
    }
    if (input_rate - output_rate).abs() < 1e-6 {
        return input.to_vec();
    }

    let ratio = output_rate / input_rate;
    let cutoff = 0.5 * ratio.min(1.0);
    let half_width = zero_crossings / (2.0 * cutoff);

    let output_count = (input.len() as f64 * ratio).floor() as usize;
    if output_count == 0 {
        return Vec::new();
    }

    let table_size = (half_width * 512.0).ceil() as usize + 2;
    let mut kernel = vec![0.0f64; table_size];
    for (index, k) in kernel.iter_mut().enumerate() {
        let offset = index as f64 / 512.0;
        let window = blackman((offset + half_width) / (2.0 * half_width));
        *k = 2.0 * cutoff * sinc(2.0 * cutoff * offset) * window;
    }

    let mut output = vec![0.0f32; output_count];
    let last = input.len() as i64 - 1;

    if let Some((phases, advance)) = rational_phases(input_rate, output_rate) {
        resample_phased(input, &mut output, &kernel, half_width, phases, advance, input_rate / output_rate);
        return output;
    }

    for (index, out) in output.iter_mut().enumerate() {
        let centre = index as f64 / ratio;
        let first_tap = (centre - half_width).ceil() as i64;
        let last_tap = (centre + half_width).floor() as i64;

        let mut sum = 0.0;
        let mut weight_sum = 0.0;
        for tap in first_tap..=last_tap {
            let offset = (centre - tap as f64).abs();
            let scaled = offset * 512.0;
            let slot = scaled as usize;
            if slot + 1 >= table_size {
                continue;
            }
            let fraction = scaled - slot as f64;
            let weight = kernel[slot] + fraction * (kernel[slot + 1] - kernel[slot]);
            let clamped = tap.clamp(0, last) as usize;
            sum += weight * input[clamped] as f64;
            weight_sum += weight;
        }
        *out = if weight_sum != 0.0 {
            (sum / weight_sum) as f32
        } else {
            0.0
        };
    }
    output
}

/// Phase count and per-cycle input advance for integer rates whose output
/// grid repeats against the input: 44.1k → 22.05k is one phase, 48k → 22.05k
/// is 147 phases advancing 320 input samples per cycle.
///
/// The interpolated kernel lookups depend only on where an output sample falls
/// between input samples, so within one phase every output uses the same taps
/// at the same weights. The generic loop rebuilt those weights (an interpolated
/// table lookup per tap, ~140 taps) for every output sample, which made this
/// function most of the analysis thread's time.
fn rational_phases(input_rate: f64, output_rate: f64) -> Option<(usize, i64)> {
    const MAX_PHASES: u64 = 4096;
    if input_rate.fract() != 0.0 || output_rate.fract() != 0.0 || input_rate > 1e7 || output_rate > 1e7 {
        return None;
    }
    let (input, output) = (input_rate as u64, output_rate as u64);
    let divisor = gcd(input, output);
    let phases = output / divisor;
    (phases <= MAX_PHASES).then(|| (phases as usize, (input / divisor) as i64))
}

fn gcd(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

/// The generic loop's arithmetic with the weights computed once per phase.
/// Same kernel and taps. Two things differ from it in the last bits only: the
/// accumulation runs in lanes ([`dot`]), and the output's position comes from
/// an exact integer phase rather than from `index / ratio` in floating point.
fn resample_phased(
    input: &[f32],
    output: &mut [f32],
    kernel: &[f64],
    half_width: f64,
    phases: usize,
    advance: i64,
    step: f64,
) {
    let table_size = kernel.len();
    let last = input.len() as i64 - 1;
    struct Phase {
        first_tap: i64,
        weights: Vec<f64>,
        weight_sum: f64,
    }
    let table: Vec<Phase> = (0..phases)
        .map(|phase| {
            let centre = phase as f64 * step;
            let first_tap = (centre - half_width).ceil() as i64;
            let last_tap = (centre + half_width).floor() as i64;
            let mut weights = Vec::with_capacity((last_tap - first_tap + 1).max(0) as usize);
            let mut weight_sum = 0.0;
            for tap in first_tap..=last_tap {
                let scaled = (centre - tap as f64).abs() * 512.0;
                let slot = scaled as usize;
                let weight = if slot + 1 >= table_size {
                    0.0
                } else {
                    let fraction = scaled - slot as f64;
                    kernel[slot] + fraction * (kernel[slot + 1] - kernel[slot])
                };
                weights.push(weight);
                weight_sum += weight;
            }
            Phase { first_tap, weights, weight_sum }
        })
        .collect();

    for (index, out) in output.iter_mut().enumerate() {
        if index & 0x3fff == 0 {
            crate::pace::tick();
        }
        let phase = &table[index % phases];
        let first = phase.first_tap + (index / phases) as i64 * advance;
        let end = first + phase.weights.len() as i64 - 1;
        let mut sum = 0.0;
        if first >= 0 && end <= last {
            sum = dot(&phase.weights, &input[first as usize..=end as usize]);
        } else {
            for (offset, weight) in phase.weights.iter().enumerate() {
                let clamped = (first + offset as i64).clamp(0, last) as usize;
                sum += weight * input[clamped] as f64;
            }
        }
        *out = if phase.weight_sum != 0.0 {
            (sum / phase.weight_sum) as f32
        } else {
            0.0
        };
    }
}

/// `Σ weight × sample` in eight independent f64 lanes.
///
/// One running sum makes every tap wait for the previous add, and with ~140
/// taps per output sample that chain was the resampler's whole cost: about
/// 350 ms for a three-minute track, twice per track (the beat model's rate and
/// the DSP pass's). Eight sums run side by side and vectorise. The result
/// differs from the single sum only in f64 rounding, far below the f32 the
/// sample is stored as.
#[inline]
fn dot(weights: &[f64], samples: &[f32]) -> f64 {
    const LANES: usize = 8;
    let mut lanes = [0f64; LANES];
    let mut weight_chunks = weights.chunks_exact(LANES);
    let mut sample_chunks = samples.chunks_exact(LANES);
    for (w, x) in (&mut weight_chunks).zip(&mut sample_chunks) {
        for lane in 0..LANES {
            lanes[lane] += w[lane] * x[lane] as f64;
        }
    }
    let mut tail = 0f64;
    for (w, x) in weight_chunks.remainder().iter().zip(sample_chunks.remainder()) {
        tail += w * *x as f64;
    }
    ((lanes[0] + lanes[4]) + (lanes[1] + lanes[5])) + ((lanes[2] + lanes[6]) + (lanes[3] + lanes[7])) + tail
}

fn sinc(x: f64) -> f64 {
    if x.abs() < 1e-12 {
        return 1.0;
    }
    let scaled = PI * x;
    scaled.sin() / scaled
}

fn blackman(position: f64) -> f64 {
    0.42 - 0.5 * (2.0 * PI * position).cos() + 0.08 * (4.0 * PI * position).cos()
}

// ---- Mel spectrogram --------------------------------------------------------

/// Row-major `[frames][MELS]` flattened result, matching upstream's
/// `BeatSpectrogram`.
pub struct BeatSpectrogram {
    pub frames: usize,
    pub values: Vec<f32>,
}

#[derive(Clone)]
struct MelFilter {
    first_bin: usize,
    weights: Vec<f64>,
}

fn hz_to_mel(hz: f64) -> f64 {
    const F_SP: f64 = 200.0 / 3.0;
    const MIN_LOG_HZ: f64 = 1000.0;
    let min_log_mel = MIN_LOG_HZ / F_SP;
    let logstep = 6.4f64.ln() / 27.0;
    if hz >= MIN_LOG_HZ {
        min_log_mel + (hz / MIN_LOG_HZ).ln() / logstep
    } else {
        hz / F_SP
    }
}

fn mel_to_hz(mel: f64) -> f64 {
    const F_SP: f64 = 200.0 / 3.0;
    const MIN_LOG_HZ: f64 = 1000.0;
    let min_log_mel = MIN_LOG_HZ / F_SP;
    let logstep = 6.4f64.ln() / 27.0;
    if mel >= min_log_mel {
        MIN_LOG_HZ * (logstep * (mel - min_log_mel)).exp()
    } else {
        F_SP * mel
    }
}

/// Triangular filters, deliberately *not* area-normalized (torchaudio's
/// `norm=None` default, which the model was trained on).
fn mel_filterbank(sample_rate: f64) -> Vec<MelFilter> {
    let bins = BEAT_SPECTROGRAM_FFT / 2 + 1;
    let mel_min = hz_to_mel(MIN_HZ);
    let mel_max = hz_to_mel(MAX_HZ);

    let mut edges = vec![0.0; BEAT_SPECTROGRAM_MELS + 2];
    for (index, edge) in edges.iter_mut().enumerate() {
        *edge = mel_to_hz(
            mel_min + (mel_max - mel_min) * index as f64 / (BEAT_SPECTROGRAM_MELS + 1) as f64,
        );
    }

    let mut filters = vec![
        MelFilter {
            first_bin: 0,
            weights: Vec::new(),
        };
        BEAT_SPECTROGRAM_MELS
    ];
    for (mel, filter) in filters.iter_mut().enumerate() {
        let left = edges[mel];
        let centre = edges[mel + 1];
        let right = edges[mel + 2];
        let to_bin = |hz: f64| hz * BEAT_SPECTROGRAM_FFT as f64 / sample_rate;
        let first = to_bin(left).floor().max(0.0) as usize;
        let last = (to_bin(right).ceil() as usize).min(bins - 1);
        if last < first {
            continue;
        }
        filter.first_bin = first;
        filter.weights.reserve(last - first + 1);
        for bin in first..=last {
            let hz = bin as f64 * sample_rate / BEAT_SPECTROGRAM_FFT as f64;
            let rising = if centre > left {
                (hz - left) / (centre - left)
            } else {
                0.0
            };
            let falling = if right > centre {
                (right - hz) / (right - centre)
            } else {
                0.0
            };
            filter.weights.push(rising.min(falling).max(0.0));
        }
    }
    filters
}

/// Unnormalized in-place radix-2 FFT (size must be a power of two).
pub(crate) fn fft(values: &mut [Complex]) {
    // Every spectrogram the planner computes passes here, frame by frame.
    crate::pace::tick();
    let size = values.len();
    let mut swapped = 0usize;
    for index in 1..size {
        let mut bit = size >> 1;
        while swapped & bit != 0 {
            swapped ^= bit;
            bit >>= 1;
        }
        swapped ^= bit;
        if index < swapped {
            values.swap(index, swapped);
        }
    }
    let mut length = 2usize;
    while length <= size {
        let root = Complex::from_polar(1.0, -2.0 * PI / length as f64);
        for start in (0..size).step_by(length) {
            let mut weight = Complex { re: 1.0, im: 0.0 };
            for offset in 0..length / 2 {
                let even = values[start + offset];
                let odd = values[start + offset + length / 2].mul(weight);
                values[start + offset] = even.add(odd);
                values[start + offset + length / 2] = even.sub(odd);
                weight = weight.mul(root);
            }
        }
        length <<= 1;
    }
}

#[derive(Clone, Copy)]
pub(crate) struct Complex {
    re: f64,
    im: f64,
}

impl Complex {
    fn from_polar(r: f64, theta: f64) -> Self {
        Self {
            re: r * theta.cos(),
            im: r * theta.sin(),
        }
    }
    fn add(self, o: Self) -> Self {
        Self {
            re: self.re + o.re,
            im: self.im + o.im,
        }
    }
    fn sub(self, o: Self) -> Self {
        Self {
            re: self.re - o.re,
            im: self.im - o.im,
        }
    }
    fn mul(self, o: Self) -> Self {
        Self {
            re: self.re * o.re - self.im * o.im,
            im: self.re * o.im + self.im * o.re,
        }
    }
    fn abs(self) -> f64 {
        (self.re * self.re + self.im * self.im).sqrt()
    }
}

pub(crate) fn hann_window(size: usize) -> Vec<f64> {
    // Periodic Hann, matching torch.hann_window(periodic=True).
    (0..size)
        .map(|index| 0.5 - 0.5 * (2.0 * PI * index as f64 / size as f64).cos())
        .collect()
}

/// Port of `ComputeBeatSpectrogram` — Slaney mel, reflect-padded centred
/// frames, `log1p(1000·magnitude)`. Returns an empty spectrogram when the
/// input rate is not the model's rate or the input is too short.
pub fn compute_beat_spectrogram(samples: &[f32], sample_rate: f64) -> BeatSpectrogram {
    let mut result = BeatSpectrogram {
        frames: 0,
        values: Vec::new(),
    };
    if (sample_rate - BEAT_SPECTROGRAM_SAMPLE_RATE).abs() > 1.0 {
        return result;
    }

    let pad = BEAT_SPECTROGRAM_FFT / 2;
    if samples.len() <= pad + 1 {
        return result;
    }

    // torchaudio's stft(center=True, pad_mode="reflect").
    let mut padded = Vec::with_capacity(samples.len() + 2 * pad);
    for index in (1..=pad).rev() {
        padded.push(samples[index]);
    }
    padded.extend_from_slice(samples);
    for index in 1..=pad {
        padded.push(samples[samples.len() - 1 - index]);
    }

    if padded.len() < BEAT_SPECTROGRAM_FFT {
        return result;
    }
    let frames = (padded.len() - BEAT_SPECTROGRAM_FFT) / BEAT_SPECTROGRAM_HOP + 1;

    let window = hann_window(BEAT_SPECTROGRAM_FFT);
    let filters = mel_filterbank(sample_rate);
    let bins = BEAT_SPECTROGRAM_FFT / 2 + 1;
    let normalization = (BEAT_SPECTROGRAM_FFT as f64).sqrt();

    result.frames = frames;
    result.values = vec![0.0f32; frames * BEAT_SPECTROGRAM_MELS];

    let mut spectrum = vec![Complex { re: 0.0, im: 0.0 }; BEAT_SPECTROGRAM_FFT];
    let mut magnitude = vec![0.0f64; bins];

    for frame in 0..frames {
        let start = frame * BEAT_SPECTROGRAM_HOP;
        for (index, value) in spectrum.iter_mut().enumerate() {
            *value = Complex {
                re: padded[start + index] as f64 * window[index],
                im: 0.0,
            };
        }
        fft(&mut spectrum);
        for (bin, mag) in magnitude.iter_mut().take(bins).enumerate() {
            *mag = spectrum[bin].abs() / normalization;
        }
        let row =
            &mut result.values[frame * BEAT_SPECTROGRAM_MELS..(frame + 1) * BEAT_SPECTROGRAM_MELS];
        for (mel, cell) in row.iter_mut().enumerate() {
            let filter = &filters[mel];
            let mut energy = 0.0;
            for (offset, weight) in filter.weights.iter().enumerate() {
                energy += magnitude[filter.first_bin + offset] * weight;
            }
            *cell = (LOG_MULTIPLIER * energy.max(AMPLITUDE_FLOOR)).ln_1p() as f32;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resample_passthrough_on_equal_rates() {
        let input: Vec<f32> = (0..1000).map(|i| i as f32 / 1000.0).collect();
        let out = resample(&input, 44_100.0, 44_100.0);
        assert_eq!(out, input);
    }

    #[test]
    fn resample_dc_stays_dc_and_length_matches_ratio() {
        let input = vec![0.5f32; 44_100];
        let out = resample(&input, 44_100.0, 22_050.0);
        assert_eq!(out.len(), 22_050);
        for v in &out[100..out.len() - 100] {
            assert!((v - 0.5).abs() < 1e-3, "dc drift {v}");
        }
    }

    /// The phase-table path against the generic loop it replaces: a rate a
    /// hair off an integer takes the generic loop, and the two must agree to
    /// well under anything a spectrogram can see.
    #[test]
    fn phased_resampler_matches_the_generic_loop() {
        let input: Vec<f32> = (0..48_000)
            .map(|i| {
                let t = i as f64;
                ((t * 0.0371).sin() * 0.6 + (t * 0.113).sin() * 0.3 + ((i * 7919 % 101) as f64 / 101.0 - 0.5) * 0.1) as f32
            })
            .collect();
        for (from, to) in [(48_000.0, 22_050.0), (44_100.0, 22_050.0), (32_000.0, 22_050.0), (96_000.0, 22_050.0)] {
            assert!(rational_phases(from, to).is_some(), "{from} → {to} should be phased");
            let fast = resample(&input, from, to);
            let generic = resample(&input, from + 1e-7, to);
            // The nudged rate can floor one sample shorter; compare the overlap.
            assert!(fast.len().abs_diff(generic.len()) <= 1, "{from} → {to}");
            let worst = fast.iter().zip(&generic).map(|(a, b)| (a - b).abs()).fold(0.0f32, f32::max);
            assert!(worst < 1e-5, "{from} → {to}: worst difference {worst}");
        }
    }

    #[test]
    fn resample_tone_keeps_frequency() {
        // 1 kHz tone at 48k resampled to 24k must still peak ~1 kHz.
        let rate = 48_000.0;
        let input: Vec<f32> = (0..48_000)
            .map(|i| (2.0 * PI * 1000.0 * i as f64 / rate).sin() as f32)
            .collect();
        let out = resample(&input, rate, 24_000.0);
        // Count zero crossings of the tail: 2 per cycle → freq ≈ crossings/2 per second.
        let tail = &out[out.len() - 12_000..];
        let crossings = tail
            .windows(2)
            .filter(|w| w[0].signum() != w[1].signum())
            .count();
        let freq = crossings as f64 / 2.0 * (24_000.0 / 12_000.0);
        assert!((freq - 1000.0).abs() < 25.0, "freq {freq}");
    }

    #[test]
    fn mel_spectrogram_shape_and_rate_gate() {
        // Wrong rate → empty.
        let noise: Vec<f32> = (0..44_100)
            .map(|i| (((i as u32).wrapping_mul(2654435761) % 97) as i32) as f32 / 97.0 - 0.5)
            .collect();
        assert_eq!(compute_beat_spectrogram(&noise, 44_100.0).frames, 0);

        // Right rate → frames = (padded - fft)/hop + 1.
        let result = compute_beat_spectrogram(&noise, 22_050.0);
        let pad = BEAT_SPECTROGRAM_FFT / 2;
        let padded_len = noise.len() + 2 * pad;
        let expected = (padded_len - BEAT_SPECTROGRAM_FFT) / BEAT_SPECTROGRAM_HOP + 1;
        assert_eq!(result.frames, expected);
        assert_eq!(result.values.len(), expected * BEAT_SPECTROGRAM_MELS);
        // log1p(1000·floor) at silence ≈ log1p(1e-7) ≈ 1e-7, so values are finite.
        assert!(result.values.iter().all(|v| v.is_finite() && *v >= 0.0));
    }

    #[test]
    fn fft_matches_dft_on_a_known_sine() {
        let n = 64;
        let mut values: Vec<Complex> = (0..n)
            .map(|i| Complex {
                re: (2.0 * PI * 4.0 * i as f64 / n as f64).sin(),
                im: 0.0,
            })
            .collect();
        fft(&mut values);
        // Bin 4 and bin n-4 carry the energy for a real sine.
        let bin4 = values[4].abs();
        let bin0 = values[0].abs();
        assert!(bin4 > (n as f64) / 2.0 * 0.9, "bin4 {bin4}");
        assert!(bin0 < 1e-6);
    }
}
