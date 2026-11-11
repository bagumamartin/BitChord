//! Port of upstream `VocalSpectrogram` + `VocalTracker.kt`, reading the
//! open-unmix **umxhq** vocals graph downloaded from the project's GitHub
//! releases (`vocals_umxhq_int8.onnx`). No model graph is bundled.
//!
//! The graph is an ONNX export of the official sigsep umxhq vocals checkpoint
//! (MIT), fixed at `[1, 2, 2049, 960]` magnitude spectrogram → vocals magnitude
//! in the same shape. The three BiLSTM layers are float; only the MatMul/Gemm
//! layers are int8. `plan.rs` trims the decoder's chunk overshoot to the window
//! asked for so the 960-frame input is exact.

use super::models;
use super::resample;
use super::{fft, hann_window, Complex};

pub const SAMPLE_RATE: f64 = 44_100.0;
pub const CHANNELS: usize = 2;
pub const FFT: usize = 4096;
pub const BINS: usize = FFT / 2 + 1;
pub const HOP: usize = 1024;
pub const FIXED_FRAMES: usize = 960;
/// Longest source window the fixed-length STFT can ingest without exceeding
/// [`FIXED_FRAMES`]. Upstream trims the decode to
/// `(FIXED_FRAMES - 2) · hop / rate` (TrackAnalyzer), which lands at 958
/// frames; the previous 22.8 s window decoded to 982 frames and made
/// [`track`] reject every normal track, so no vocal mask was ever produced.
pub const MAX_WINDOW_SECONDS: f64 = (FIXED_FRAMES as f64 - 2.0) * HOP as f64 / SAMPLE_RATE;
const LOW_HZ: f64 = 200.0;
const HIGH_HZ: f64 = 4000.0;

use rten_tensor::NdTensorView;
use rten_tensor::prelude::*;

/// One vocal-presence value per STFT frame in [0, 1].
pub fn track(left: &[f32], right: &[f32], rate: f64) -> Option<Vec<f32>> {
    if !models::vocal_ready() || left.is_empty() || left.len() != right.len() {
        return None;
    }
    let left = if (rate - SAMPLE_RATE).abs() > 1.0 {
        resample(left, rate, SAMPLE_RATE)
    } else {
        left.to_vec()
    };
    let right = if (rate - SAMPLE_RATE).abs() > 1.0 {
        resample(right, rate, SAMPLE_RATE)
    } else {
        right.to_vec()
    };
    let spec = compute(&left, &right, SAMPLE_RATE)?;
    if spec.frames > FIXED_FRAMES {
        log::debug!(
            "automix: vocal window of {} frames exceeds {}",
            spec.frames,
            FIXED_FRAMES
        );
        return None;
    }
    let mask = models::with_vocal(|model| infer(model, &spec)).flatten();
    drop(spec);
    // After the model lock is released: one window is the longest single step.
    crate::pace::tick();
    mask
}

struct Spectrogram {
    values: Vec<f32>,
    frames: usize,
}

fn compute(left: &[f32], right: &[f32], sample_rate: f64) -> Option<Spectrogram> {
    if (sample_rate - SAMPLE_RATE).abs() > 1.0 {
        return None;
    }
    let pad = FFT / 2;
    if left.len() <= pad + 1 {
        return None;
    }
    let window = hann_window(FFT);
    let mut padded = [Vec::new(), Vec::new()];
    for (channel, source) in [left, right].into_iter().enumerate() {
        let out = &mut padded[channel];
        out.reserve(source.len() + 2 * pad);
        for index in (1..=pad).rev() {
            out.push(source[index]);
        }
        out.extend_from_slice(source);
        for index in 1..=pad {
            out.push(source[source.len() - 1 - index]);
        }
    }
    let padded_len = padded[0].len();
    if padded_len < FFT {
        return None;
    }
    let frames = (padded_len - FFT) / HOP + 1;
    // The graph wants bins major and frames minor, the transpose of the order
    // frames come out of the STFT. Written a frame at a time, every frame
    // touched a cache line per bin, 2049 of them; a block of frames is
    // gathered first so each bin's row is written in one run.
    const BLOCK: usize = 16;
    let mut values = vec![0.0f32; CHANNELS * BINS * frames];
    let mut spectrum = vec![Complex { re: 0.0, im: 0.0 }; FFT];
    let mut block = vec![0.0f32; BLOCK * BINS];
    for channel in 0..CHANNELS {
        let source = &padded[channel];
        let channel_base = channel * BINS * frames;
        for first in (0..frames).step_by(BLOCK) {
            let count = BLOCK.min(frames - first);
            for offset in 0..count {
                let start = (first + offset) * HOP;
                for (index, bin) in spectrum.iter_mut().enumerate() {
                    *bin = Complex {
                        re: source[start + index] as f64 * window[index],
                        im: 0.0,
                    };
                }
                fft(&mut spectrum);
                for bin in 0..BINS {
                    block[bin * BLOCK + offset] = spectrum[bin].abs() as f32;
                }
            }
            for bin in 0..BINS {
                let row = channel_base + bin * frames + first;
                values[row..row + count].copy_from_slice(&block[bin * BLOCK..bin * BLOCK + count]);
            }
        }
    }
    Some(Spectrogram { values, frames })
}

fn infer(model: &rten::Model, spec: &Spectrogram) -> Option<Vec<f32>> {
    let input_id = *model.input_ids().first()?;
    let mix = fill_fixed_frames(&spec.values, spec.frames);
    let tensor = NdTensorView::from_data([1, CHANNELS, BINS, FIXED_FRAMES], mix.as_slice());
    let outputs = match model.run(vec![(input_id, tensor.into())], model.output_ids(), Some(models::run_options())) {
        Ok(outputs) => outputs,
        Err(error) => {
            // Silence here is how the analyser ends up on the DSP heuristic while
            // everyone believes the 113 MB graph is doing the work.
            log::warn!("automix: vocal inference failed: {error}");
            return None;
        }
    };
    let output = outputs.first()?.as_tensor_view::<f32>()?;
    let target = match output.data() {
        Some(data) => std::borrow::Cow::Borrowed(data),
        None => std::borrow::Cow::Owned(output.to_vec()),
    };
    if target.len() < CHANNELS * BINS * FIXED_FRAMES {
        return None;
    }
    Some(reduce_to_band_curve(&mix, &target, spec.frames))
}

fn fill_fixed_frames(values: &[f32], frames: usize) -> Vec<f32> {
    let mut into = vec![0.0f32; CHANNELS * BINS * FIXED_FRAMES];
    if frames == FIXED_FRAMES {
        into.copy_from_slice(values);
        return into;
    }
    for channel in 0..CHANNELS {
        for bin in 0..BINS {
            let src = (channel * BINS + bin) * frames;
            let dst = (channel * BINS + bin) * FIXED_FRAMES;
            let n = frames.min(FIXED_FRAMES);
            into[dst..dst + n].copy_from_slice(&values[src..src + n]);
        }
    }
    into
}

fn reduce_to_band_curve(mix: &[f32], target: &[f32], usable_frames: usize) -> Vec<f32> {
    let low_bin = ((LOW_HZ * FFT as f64 / SAMPLE_RATE).floor() as usize).max(0);
    let high_bin = ((HIGH_HZ * FFT as f64 / SAMPLE_RATE).ceil() as usize).min(BINS - 1);
    if high_bin <= low_bin || usable_frames == 0 {
        return Vec::new();
    }
    // Row by row (each bin's frames are contiguous) rather than frame by
    // frame across rows. Every frame still adds its ratios in channel-then-bin
    // order, so the sums are the same to the bit.
    let mut sums = vec![0.0f64; usable_frames];
    let mut counts = vec![0u32; usable_frames];
    for channel in 0..CHANNELS {
        for bin in low_bin..=high_bin {
            let row = (channel * BINS + bin) * FIXED_FRAMES;
            let mix_row = &mix[row..row + usable_frames];
            let target_row = &target[row..row + usable_frames];
            for frame in 0..usable_frames {
                let mix_value = mix_row[frame];
                if mix_value <= 1e-6 {
                    continue;
                }
                let ratio = (target_row[frame] / mix_value).clamp(0.0, 1.0);
                sums[frame] += ratio as f64;
                counts[frame] += 1;
            }
        }
    }
    sums.iter()
        .zip(&counts)
        .map(|(sum, count)| if *count > 0 { (sum / *count as f64) as f32 } else { 0.0 })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signal(len: usize, seed: u32) -> Vec<f32> {
        let mut state = seed;
        (0..len)
            .map(|i| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let noise = (state >> 8) as f32 / (1u32 << 24) as f32 - 0.5;
                (0.4 * (i as f32 * 0.031).sin() + 0.2 * (i as f32 * 0.0071).sin() + 0.1 * noise) as f32
            })
            .collect()
    }

    /// The layout before frames were gathered in blocks: one frame at a time,
    /// written straight down each bin's row.
    fn reference_values(left: &[f32], right: &[f32]) -> Vec<f32> {
        let pad = FFT / 2;
        let window = hann_window(FFT);
        let padded: Vec<Vec<f32>> = [left, right]
            .iter()
            .map(|source| {
                let mut out: Vec<f32> = (1..=pad).rev().map(|i| source[i]).collect();
                out.extend_from_slice(source);
                out.extend((1..=pad).map(|i| source[source.len() - 1 - i]));
                out
            })
            .collect();
        let frames = (padded[0].len() - FFT) / HOP + 1;
        let mut values = vec![0.0f32; CHANNELS * BINS * frames];
        let mut spectrum = vec![Complex { re: 0.0, im: 0.0 }; FFT];
        for channel in 0..CHANNELS {
            for frame in 0..frames {
                for (index, bin) in spectrum.iter_mut().enumerate() {
                    *bin = Complex { re: padded[channel][frame * HOP + index] as f64 * window[index], im: 0.0 };
                }
                fft(&mut spectrum);
                for bin in 0..BINS {
                    values[channel * BINS * frames + bin * frames + frame] = spectrum[bin].abs() as f32;
                }
            }
        }
        values
    }

    fn reference_curve(mix: &[f32], target: &[f32], usable_frames: usize) -> Vec<f32> {
        let low_bin = (LOW_HZ * FFT as f64 / SAMPLE_RATE).floor() as usize;
        let high_bin = ((HIGH_HZ * FFT as f64 / SAMPLE_RATE).ceil() as usize).min(BINS - 1);
        (0..usable_frames)
            .map(|frame| {
                let mut sum = 0.0f64;
                let mut count = 0;
                for channel in 0..CHANNELS {
                    for bin in low_bin..=high_bin {
                        let index = (channel * BINS + bin) * FIXED_FRAMES + frame;
                        if mix[index] <= 1e-6 {
                            continue;
                        }
                        sum += (target[index] / mix[index]).clamp(0.0, 1.0) as f64;
                        count += 1;
                    }
                }
                if count > 0 { (sum / count as f64) as f32 } else { 0.0 }
            })
            .collect()
    }

    #[test]
    fn blocked_spectrogram_and_row_order_reduction_match_bit_for_bit() {
        // 37 frames: two whole blocks and a ragged one.
        let len = 36 * HOP + 10;
        let (left, right) = (signal(len, 1), signal(len, 2));
        let spec = compute(&left, &right, SAMPLE_RATE).expect("a spectrogram");
        assert_eq!(spec.frames, 37);
        let reference = reference_values(&left, &right);
        assert!(spec.values.iter().zip(&reference).all(|(a, b)| a.to_bits() == b.to_bits()));

        let mix = fill_fixed_frames(&spec.values, spec.frames);
        let target: Vec<f32> = mix.iter().enumerate().map(|(i, v)| v * ((i % 7) as f32 / 6.0)).collect();
        let curve = reduce_to_band_curve(&mix, &target, spec.frames);
        let expected = reference_curve(&mix, &target, spec.frames);
        assert_eq!(curve.len(), expected.len());
        assert!(curve.iter().zip(&expected).all(|(a, b)| a.to_bits() == b.to_bits()));
    }
}
