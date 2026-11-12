//! Version alignment: where a song's moments fall in another upload of the
//! same recording.
//!
//! The case it exists for is the player's video toggle. A YouTube Music song is
//! usually an art track, and its music video is a different upload whose cut
//! is not the song's: a cold open, a skit halfway through, a longer ending.
//! Laying that picture over the song's audio by clock time puts the singer's
//! mouth seconds away from the voice. Upstream measures one shift and, when the
//! cuts differ, swaps the listener onto the video's audio. This maps the whole
//! timeline instead — any number of segments, each with its own offset — so the
//! picture can follow the song's own audio through an intro and past a skit,
//! and a swap that is still needed lands on the matching moment.
//!
//! The method is the classic one for recordings of the same piece: chroma
//! features (pitch classes survive a different master, a different mix and a
//! louder video), a subsequence dynamic time warp that lets the other upload
//! carry material the song does not have, then each constant-offset run of the
//! path refined to 10 ms on onset envelopes, which is what lip sync needs.

use std::collections::HashMap;
use std::f64::consts::PI;

use crate::decode::{SourceKind, SymphoniaDecoder};

/// Everything is measured at this rate: chroma below 4 kHz and onsets need
/// nothing higher, and it keeps a five-minute track to a few million samples.
const RATE: f64 = 11_025.0;
/// The resampler's kernel for that rate. Chroma and onset envelopes need no
/// studio-grade stopband; six zero crossings instead of the analysis path's
/// 32 made a pair of five-minute decodes about 2.5 s faster.
const RESAMPLE_ZERO_CROSSINGS: f64 = 6.0;
/// Chroma frame: 2048 samples (186 ms) every 1102 (100 ms, 10 frames a second).
const CHROMA_FFT: usize = 2048;
const CHROMA_HOP: usize = 1102;
const FRAME_SECONDS: f64 = CHROMA_HOP as f64 / RATE;
/// Onset envelope for refinement: 512-sample frames every 110 (10 ms).
const ONSET_FFT: usize = 512;
const ONSET_HOP: usize = 110;
const ONSET_SECONDS: f64 = ONSET_HOP as f64 / RATE;

/// The other upload advancing while the song waits (an intro, a skit, an outro
/// the song lacks), per 100 ms frame. Between a matched frame (~0.05) and a
/// mismatched one (~0.4): a few seconds of extra material is cheaper to skip
/// than to warp through, and a real match is never given up for it.
const INSERT_PENALTY: f32 = 0.22;
/// The song advancing while the other upload waits (a passage the video cut).
const DELETE_PENALTY: f32 = 0.30;
/// Local quality and offset checks use short enough windows to catch a video
/// edit before a whole-song average hides it.
const LOCAL_WINDOW_SECONDS: f64 = 8.0;
const LOCAL_OFFSET_SPLIT_SECONDS: f64 = 0.3;
/// How far refinement may move a segment's offset, either way.
const REFINE_SECONDS: f64 = 0.3;

/// A stretch of the song and where it sits in the other upload: song time `t`
/// in `[song_start, song_end)` is other time `t + offset`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Segment {
    pub song_start: f64,
    pub song_end: f64,
    pub offset: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Alignment {
    pub segments: Vec<Segment>,
    /// Mean chroma similarity along the matched path, 0…1.
    pub similarity: f64,
    /// The same measure between the song and the other upload rolled half its
    /// length: what two unrelated stretches of these recordings score. A true
    /// alignment clears it by a wide margin.
    pub baseline: f64,
    /// Lowest chroma similarity in any non-silent local window.
    pub minimum_window_similarity: f64,
    /// Share of the song's audible frames the segments cover.
    pub coverage: f64,
}

impl Alignment {
    /// Whether the map is trustworthy enough to lay a picture by.
    ///
    /// Calibrated on real pairs, not just the fixtures. A song against its own
    /// music video (Cardi B, "Money": an intro and an 11.6 s interlude) scored
    /// 0.97 against a 0.86 baseline, and against a still-image upload of the
    /// same audio 0.98 against 0.87. The same song against three different
    /// cached songs scored 0.83–0.89 against 0.81–0.87: harmonically similar
    /// pop clears its own baseline by about 0.02, a true match by 0.11. A
    /// tonal genre raises both numbers together, so the margin decides and the
    /// floor only keeps silence-heavy pairs out. A different song also comes
    /// back as a staircase of short segments, which a real cut never is.
    pub fn is_confident(&self) -> bool {
        let song_seconds = self.segments.last().map_or(0.0, |s| s.song_end);
        !self.segments.is_empty()
            && self.similarity - self.baseline >= 0.06
            && self.minimum_window_similarity - self.baseline >= 0.06
            && self.similarity >= 0.9
            && self.coverage >= 0.85
            && self.segments.len() as f64 <= 1.0 + song_seconds / 30.0
    }

    /// Other-upload time for a song time, or None in a gap between segments.
    pub fn map(&self, song_seconds: f64) -> Option<f64> {
        self.segments
            .iter()
            .find(|s| song_seconds >= s.song_start && song_seconds < s.song_end)
            .map(|s| song_seconds + s.offset)
    }
}

/// Align two files. None when either cannot be decoded or is too short.
pub fn align_files(song: &str, other: &str) -> Option<Alignment> {
    // One after the other, on the caller's thread. Side by side they halved
    // the wait, but put the alignment on two cores at once beside the
    // transition planner; it runs ahead of any toggle, so the wait is unseen.
    let a = decode_mono(song)?;
    let b = decode_mono(other)?;
    align(&a, &b)
}

/// Align two mono signals already at [`RATE`].
pub fn align(song: &[f32], other: &[f32]) -> Option<Alignment> {
    let (song_chroma, song_onsets) = (chroma(song), onsets(song));
    let (other_chroma, other_onsets) = (chroma(other), onsets(other));
    if song_chroma.len() < 20 || other_chroma.len() < 20 {
        return None;
    }
    let path = warp(&song_chroma, &other_chroma);
    let (mut segments, minimum_window_similarity) = local_segments(&path, &song_chroma, &other_chroma);
    if segments.is_empty() {
        return None;
    }
    for segment in &mut segments {
        segment.offset = refine(segment, &song_onsets, &other_onsets);
    }

    let similarity = path_similarity(&path, &song_chroma, &other_chroma);
    let baseline = rolled_similarity(&song_chroma, &other_chroma);
    let audible = song_chroma.iter().filter(|f| f.is_some()).count().max(1);
    let covered = song_chroma
        .iter()
        .enumerate()
        .filter(|(i, f)| {
            let t = *i as f64 * FRAME_SECONDS;
            f.is_some() && segments.iter().any(|s| t >= s.song_start && t < s.song_end)
        })
        .count();
    Some(Alignment {
        segments,
        similarity,
        baseline,
        minimum_window_similarity,
        coverage: covered as f64 / audible as f64,
    })
}

fn decode_mono(path: &str) -> Option<Vec<f32>> {
    let mut decoder = SymphoniaDecoder::open_available(&SourceKind::parse(path), &HashMap::new()).ok()?;
    let rate = decoder.sample_rate() as f64;
    let mut mono = Vec::new();
    loop {
        let chunk = decoder.read_stereo(8192).ok()?;
        if chunk.is_empty() {
            break;
        }
        mono.extend(chunk.chunks_exact(2).map(|pair| (pair[0] + pair[1]) * 0.5));
    }
    if mono.is_empty() {
        return None;
    }
    Some(crate::analyzer::resample_with(&mono, rate, RATE, RESAMPLE_ZERO_CROSSINGS))
}

/// One L2-normalised 12-bin pitch-class vector per frame; None for a frame
/// with no tonal energy (silence reads as nothing, not as every key at once).
fn chroma(signal: &[f32]) -> Vec<Option<[f32; 12]>> {
    let mut transform = Spectrum::new(CHROMA_FFT);
    let bins: Vec<Option<usize>> = (0..CHROMA_FFT / 2)
        .map(|k| {
            let hz = k as f64 * RATE / CHROMA_FFT as f64;
            if !(55.0..=4_000.0).contains(&hz) {
                return None;
            }
            let pitch = 69.0 + 12.0 * (hz / 440.0).log2();
            Some((pitch.round() as i64).rem_euclid(12) as usize)
        })
        .collect();
    let mut frames = Vec::new();
    let mut start = 0;
    while start + CHROMA_FFT <= signal.len() {
        let spectrum = transform.magnitudes(&signal[start..start + CHROMA_FFT]);
        let mut chroma = [0f32; 12];
        let mut energy = 0f64;
        for (k, magnitude) in spectrum.iter().enumerate() {
            if let Some(Some(class)) = bins.get(k) {
                chroma[*class] += (1.0 + 100.0 * magnitude).ln() as f32;
                energy += magnitude * magnitude;
            }
        }
        let norm = chroma.iter().map(|v| v * v).sum::<f32>().sqrt();
        frames.push(if energy < 1e-6 || norm <= f32::EPSILON {
            None
        } else {
            for v in &mut chroma {
                *v /= norm;
            }
            Some(chroma)
        });
        start += CHROMA_HOP;
    }
    frames
}

/// Positive spectral flux, one value per 10 ms.
fn onsets(signal: &[f32]) -> Vec<f32> {
    let mut transform = Spectrum::new(ONSET_FFT);
    let mut previous: Vec<f64> = vec![0.0; ONSET_FFT / 2];
    let mut envelope = Vec::new();
    let mut start = 0;
    while start + ONSET_FFT <= signal.len() {
        let spectrum = transform.magnitudes(&signal[start..start + ONSET_FFT]);
        let mut flux = 0f64;
        for (k, magnitude) in spectrum.iter().enumerate() {
            let compressed = (1.0 + 1000.0 * magnitude).ln();
            flux += (compressed - previous[k]).max(0.0);
            previous[k] = compressed;
        }
        envelope.push(flux as f32);
        start += ONSET_HOP;
    }
    envelope
}

fn distance(a: &Option<[f32; 12]>, b: &Option<[f32; 12]>) -> f32 {
    match (a, b) {
        (Some(a), Some(b)) => 1.0 - a.iter().zip(b).map(|(x, y)| x * y).sum::<f32>(),
        (None, None) => 0.0,
        _ => 1.0,
    }
}

/// Subsequence DTW: the song must be walked end to end, the other upload may
/// be entered and left anywhere. Returns the (song, other) frame pairs of the
/// diagonal steps, in order.
fn warp(song: &[Option<[f32; 12]>], other: &[Option<[f32; 12]>]) -> Vec<(usize, usize)> {
    let (n, m) = (song.len(), other.len());
    // 0 = diagonal, 1 = other advanced (insert), 2 = song advanced (delete).
    let mut steps = vec![0u8; n * m];
    let mut previous = vec![0f32; m];
    let mut current = vec![0f32; m];
    for j in 0..m {
        previous[j] = distance(&song[0], &other[j]);
        steps[j] = 1;
    }
    for i in 1..n {
        current[0] = previous[0] + DELETE_PENALTY + distance(&song[i], &other[0]);
        steps[i * m] = 2;
        for j in 1..m {
            let cost = distance(&song[i], &other[j]);
            let diagonal = previous[j - 1];
            let insert = current[j - 1] + INSERT_PENALTY;
            let delete = previous[j] + DELETE_PENALTY;
            let (best, step) = if diagonal <= insert && diagonal <= delete {
                (diagonal, 0)
            } else if insert <= delete {
                (insert, 1)
            } else {
                (delete, 2)
            };
            current[j] = best + cost;
            steps[i * m + j] = step;
        }
        std::mem::swap(&mut previous, &mut current);
    }
    let mut j = (0..m)
        .min_by(|&a, &b| previous[a].total_cmp(&previous[b]))
        .unwrap_or(0);
    let mut i = n - 1;
    let mut path = Vec::new();
    loop {
        let step = steps[i * m + j];
        if i == 0 {
            path.push((0, j));
            break;
        }
        match step {
            0 => {
                path.push((i, j));
                if j == 0 {
                    break;
                }
                i -= 1;
                j -= 1;
            }
            1 => {
                if j == 0 {
                    break;
                }
                j -= 1;
            }
            _ => i -= 1,
        }
    }
    path.reverse();
    path
}

#[derive(Debug)]
struct LocalWindow {
    start: usize,
    end: usize,
    offset_frames: i64,
    similarity: f64,
}

/// Measures the best path's offset and chroma match in consecutive eight
/// second windows. A stable offset becomes one map segment; an offset jump
/// greater than 300 ms starts a new piecewise segment.
fn local_segments(
    path: &[(usize, usize)],
    song: &[Option<[f32; 12]>],
    other: &[Option<[f32; 12]>],
) -> (Vec<Segment>, f64) {
    let window_frames = (LOCAL_WINDOW_SECONDS / FRAME_SECONDS).round().max(1.0) as usize;
    let mut windows = Vec::new();
    for start in (0..song.len()).step_by(window_frames) {
        let end = (start + window_frames).min(song.len());
        let mut offsets = Vec::new();
        let mut similarities = Vec::new();
        for &(i, j) in path {
            if i < start || i >= end || song[i].is_none() || other[j].is_none() {
                continue;
            }
            offsets.push(j as i64 - i as i64);
            similarities.push(1.0 - distance(&song[i], &other[j]) as f64);
        }
        if offsets.is_empty() {
            continue;
        }
        offsets.sort_unstable();
        windows.push(LocalWindow {
            start,
            end,
            offset_frames: offsets[offsets.len() / 2],
            similarity: similarities.iter().sum::<f64>() / similarities.len() as f64,
        });
    }
    let minimum_similarity = windows
        .iter()
        .map(|window| window.similarity)
        .reduce(f64::min)
        .unwrap_or(0.0);
    let Some(first) = windows.first() else {
        return (Vec::new(), minimum_similarity);
    };

    let threshold_frames = (LOCAL_OFFSET_SPLIT_SECONDS / FRAME_SECONDS).round() as i64;
    let mut segments = Vec::new();
    let mut start = 0usize;
    let mut end = first.end;
    let mut offsets = vec![first.offset_frames];
    let mut prior_end = first.end;
    for window in windows.iter().skip(1) {
        let mut sorted = offsets.clone();
        sorted.sort_unstable();
        let representative = sorted[sorted.len() / 2];
        if (window.offset_frames - representative).abs() > threshold_frames {
            let split = (prior_end + window.start) / 2;
            let offset = representative as f64 * FRAME_SECONDS;
            segments.push(Segment {
                song_start: start as f64 * FRAME_SECONDS,
                song_end: split as f64 * FRAME_SECONDS,
                offset,
            });
            start = split;
            offsets.clear();
        }
        offsets.push(window.offset_frames);
        end = window.end;
        prior_end = window.end;
    }
    let mut sorted = offsets;
    sorted.sort_unstable();
    segments.push(Segment {
        song_start: start as f64 * FRAME_SECONDS,
        song_end: end.max(song.len()) as f64 * FRAME_SECONDS,
        offset: sorted[sorted.len() / 2] as f64 * FRAME_SECONDS,
    });
    (segments, minimum_similarity)
}

/// The segment's offset to 10 ms: the lag within ±[`REFINE_SECONDS`] that best
/// correlates the two onset envelopes over (up to a minute of) the segment.
fn refine(segment: &Segment, song: &[f32], other: &[f32]) -> f64 {
    let start = (segment.song_start / ONSET_SECONDS) as usize;
    let end = ((segment.song_end.min(segment.song_start + 60.0)) / ONSET_SECONDS) as usize;
    let end = end.min(song.len());
    if end <= start + 50 {
        return segment.offset;
    }
    let centre = (segment.offset / ONSET_SECONDS).round() as i64;
    let reach = (REFINE_SECONDS / ONSET_SECONDS) as i64;
    let mut best = (f64::MIN, centre);
    for lag in centre - reach..=centre + reach {
        let mut score = 0f64;
        let mut count = 0usize;
        for i in start..end {
            let j = i as i64 + lag;
            if j >= 0 && (j as usize) < other.len() {
                score += song[i] as f64 * other[j as usize] as f64;
                count += 1;
            }
        }
        if count > 0 {
            let score = score / count as f64;
            if score > best.0 {
                best = (score, lag);
            }
        }
    }
    best.1 as f64 * ONSET_SECONDS
}

fn path_similarity(path: &[(usize, usize)], song: &[Option<[f32; 12]>], other: &[Option<[f32; 12]>]) -> f64 {
    let scored: Vec<f32> = path
        .iter()
        .filter(|(i, j)| song[*i].is_some() && other[*j].is_some())
        .map(|(i, j)| 1.0 - distance(&song[*i], &other[*j]))
        .collect();
    if scored.is_empty() {
        return 0.0;
    }
    scored.iter().map(|&v| v as f64).sum::<f64>() / scored.len() as f64
}

fn rolled_similarity(song: &[Option<[f32; 12]>], other: &[Option<[f32; 12]>]) -> f64 {
    let shift = other.len() / 2;
    let scored: Vec<f32> = (0..song.len())
        .map(|i| (i, (i + shift) % other.len()))
        .filter(|(i, j)| song[*i].is_some() && other[*j].is_some())
        .map(|(i, j)| 1.0 - distance(&song[i], &other[j]))
        .collect();
    if scored.is_empty() {
        return 0.0;
    }
    scored.iter().map(|&v| v as f64).sum::<f64>() / scored.len() as f64
}

fn hann(size: usize) -> Vec<f64> {
    (0..size)
        .map(|index| 0.5 - 0.5 * (2.0 * PI * index as f64 / size as f64).cos())
        .collect()
}

/// A radix-2 FFT of one size with its twiddles computed once.
///
/// The butterflies used to call `sin_cos` for every pair: a five-minute pair of
/// uploads ran about 150 million of them, the alignment's largest cost. Each
/// stage's table holds exactly the values that call produced (same angle, same
/// multiplication), so the spectra are bit-for-bit what they were. The frame
/// buffers are kept too, so a frame allocates nothing.
struct Spectrum {
    size: usize,
    window: Vec<f64>,
    /// Stage after stage, `length / 2` (cos, sin) pairs for each `length`.
    twiddles: Vec<(f64, f64)>,
    re: Vec<f64>,
    im: Vec<f64>,
    magnitudes: Vec<f64>,
}

impl Spectrum {
    fn new(size: usize) -> Self {
        let mut twiddles = Vec::with_capacity(size);
        let mut length = 2;
        while length <= size {
            let angle = -2.0 * PI / length as f64;
            for offset in 0..length / 2 {
                let (sin, cos) = (angle * offset as f64).sin_cos();
                twiddles.push((cos, sin));
            }
            length <<= 1;
        }
        Self {
            size,
            window: hann(size),
            twiddles,
            re: vec![0.0; size],
            im: vec![0.0; size],
            magnitudes: vec![0.0; size / 2],
        }
    }

    /// Magnitudes of the first half of a windowed real frame's spectrum.
    fn magnitudes(&mut self, frame: &[f32]) -> &[f64] {
        let size = self.size;
        debug_assert_eq!(frame.len(), size);
        for ((re, sample), weight) in self.re.iter_mut().zip(frame).zip(&self.window) {
            *re = *sample as f64 * weight;
        }
        self.im.fill(0.0);
        fft(&mut self.re, &mut self.im, &self.twiddles);
        for (k, out) in self.magnitudes.iter_mut().enumerate() {
            *out = (self.re[k] * self.re[k] + self.im[k] * self.im[k]).sqrt() / size as f64;
        }
        &self.magnitudes
    }
}

/// In-place radix-2 FFT (size a power of two) over [`Spectrum`]'s twiddles.
fn fft(re: &mut [f64], im: &mut [f64], twiddles: &[(f64, f64)]) {
    let size = re.len();
    let mut swapped = 0usize;
    for index in 1..size {
        let mut bit = size >> 1;
        while swapped & bit != 0 {
            swapped ^= bit;
            bit >>= 1;
        }
        swapped ^= bit;
        if index < swapped {
            re.swap(index, swapped);
            im.swap(index, swapped);
        }
    }
    let mut length = 2;
    let mut stage = 0;
    while length <= size {
        let half = length / 2;
        let table = &twiddles[stage..stage + half];
        for start in (0..size).step_by(length) {
            for (offset, &(cos, sin)) in table.iter().enumerate() {
                let a = start + offset;
                let b = a + half;
                let (tr, ti) = (re[b] * cos - im[b] * sin, re[b] * sin + im[b] * cos);
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
        stage += half;
        length <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A deterministic stand-in for a recording: a chord every half second
    /// (three random pitches from a fixed seed) with a click on each change, so
    /// it has both the pitch structure chroma reads and the onsets refinement
    /// reads.
    fn music(seconds: f64, seed: u64) -> Vec<f32> {
        let mut state = seed;
        let mut next = || {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (state >> 33) as u32
        };
        let total = (seconds * RATE) as usize;
        let chord_len = (0.5 * RATE) as usize;
        let mut out = vec![0f32; total];
        let mut start = 0;
        while start < total {
            let notes: Vec<f64> = (0..3).map(|_| 220.0 * 2f64.powf((next() % 24) as f64 / 12.0)).collect();
            for i in start..(start + chord_len).min(total) {
                let t = i as f64 / RATE;
                let tone: f64 = notes.iter().map(|f| (2.0 * PI * f * t).sin()).sum::<f64>() / 3.0;
                let click = if i - start < 40 { 0.8 * (1.0 - (i - start) as f64 / 40.0) } else { 0.0 };
                out[i] = (0.3 * tone + click * if next() % 2 == 0 { 1.0 } else { -1.0 }) as f32;
            }
            start += chord_len;
        }
        out
    }

    /// The transform before twiddles were tabled: `sin_cos` in every butterfly.
    fn reference_magnitudes(frame: &[f32]) -> Vec<f64> {
        let size = frame.len();
        let window = hann(size);
        let mut re: Vec<f64> = frame.iter().zip(&window).map(|(s, w)| *s as f64 * w).collect();
        let mut im = vec![0f64; size];
        let mut swapped = 0usize;
        for index in 1..size {
            let mut bit = size >> 1;
            while swapped & bit != 0 {
                swapped ^= bit;
                bit >>= 1;
            }
            swapped ^= bit;
            if index < swapped {
                re.swap(index, swapped);
                im.swap(index, swapped);
            }
        }
        let mut length = 2;
        while length <= size {
            let angle = -2.0 * PI / length as f64;
            for start in (0..size).step_by(length) {
                for offset in 0..length / 2 {
                    let (sin, cos) = (angle * offset as f64).sin_cos();
                    let a = start + offset;
                    let b = a + length / 2;
                    let (tr, ti) = (re[b] * cos - im[b] * sin, re[b] * sin + im[b] * cos);
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
            }
            length <<= 1;
        }
        (0..size / 2)
            .map(|k| (re[k] * re[k] + im[k] * im[k]).sqrt() / size as f64)
            .collect()
    }

    #[test]
    fn tabled_twiddles_give_the_same_spectrum_bit_for_bit() {
        let signal = music(3.0, 7);
        for size in [ONSET_FFT, CHROMA_FFT] {
            let mut transform = Spectrum::new(size);
            for start in (0..signal.len() - size).step_by(997) {
                let frame = &signal[start..start + size];
                let tabled = transform.magnitudes(frame).to_vec();
                let reference = reference_magnitudes(frame);
                assert!(
                    tabled.iter().zip(&reference).all(|(a, b)| a.to_bits() == b.to_bits()),
                    "size {size} frame at {start} differs"
                );
            }
        }
    }

    fn at(seconds: f64) -> usize {
        (seconds * RATE) as usize
    }

    #[test]
    fn the_same_recording_maps_onto_itself() {
        let song = music(60.0, 1);
        let alignment = align(&song, &song).expect("an alignment");
        assert!(alignment.is_confident(), "{alignment:?}");
        assert_eq!(alignment.segments.len(), 1, "{alignment:?}");
        assert!(alignment.segments[0].offset.abs() < 0.015, "{alignment:?}");
    }

    #[test]
    fn an_intro_shifts_the_whole_song() {
        let song = music(60.0, 2);
        let mut video = music(7.3, 99);
        video.extend_from_slice(&song);
        let alignment = align(&song, &video).expect("an alignment");
        assert!(alignment.is_confident(), "{alignment:?}");
        assert_eq!(alignment.segments.len(), 1, "{alignment:?}");
        assert!((alignment.segments[0].offset - 7.3).abs() < 0.03, "{alignment:?}");
    }

    #[test]
    fn shayne_ward_down_with_an_inserted_gap_splits_local_windows() {
        let song = music(80.0, 3);
        let mut video = music(5.0, 77);
        video.extend_from_slice(&song[..at(40.0)]);
        video.extend(music(6.5, 55));
        video.extend_from_slice(&song[at(40.0)..]);
        video.extend(music(4.0, 33));
        let alignment = align(&song, &video).expect("an alignment");
        assert!(alignment.is_confident(), "{alignment:?}");
        assert_eq!(alignment.segments.len(), 2, "{alignment:?}");
        let (first, second) = (alignment.segments[0], alignment.segments[1]);
        assert!((first.offset - 5.0).abs() < 0.03, "{alignment:?}");
        assert!((second.offset - 11.5).abs() < 0.03, "{alignment:?}");
        assert!((first.song_end - 40.0).abs() < 1.0, "the split sits at the skit: {alignment:?}");
        assert!((alignment.map(10.0).unwrap() - 15.0).abs() < 0.03);
        assert!((alignment.map(60.0).unwrap() - 71.5).abs() < 0.03);
        assert!(
            alignment.minimum_window_similarity - alignment.baseline >= 0.06,
            "every local window must clear the unrelated-audio baseline: {alignment:?}"
        );
    }

    #[test]
    fn two_different_recordings_are_not_confident() {
        let song = music(60.0, 4);
        let other = music(70.0, 5);
        let alignment = align(&song, &other);
        assert!(alignment.as_ref().map_or(true, |a| !a.is_confident()), "{alignment:?}");
    }
}
