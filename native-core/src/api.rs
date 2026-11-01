//! The exported free functions: metadata and tags, version alignment,
//! automix analysis and planning, and region decoding.

use crate::mixer::{TrackInfo, TrackSource};
use crate::records::{
    AlignmentSegmentRec, AutomixAnalysisOverlayRec, AutomixTier, DecodedRegion, EngineError,
    LoadRequest, TrackInfoRec, TrackMetadata, TransitionPlanRec, VersionAlignmentRec,
};
use crate::PlaybackRegions;

pub(super) fn to_track_source(request: LoadRequest) -> TrackSource {
    TrackSource {
        source: request.source,
        title: request.title,
        artist: request.artist,
        start_seconds: request.start_seconds,
        plan: request.plan.map(Into::into).unwrap_or_default(),
        headers: request.headers.unwrap_or_default(),
        claimed_kbps: request.claimed_kbps.unwrap_or(0),
        loudness_db: request.loudness_db.filter(|db| db.is_finite()),
        duration_seconds: request
            .duration_seconds
            .filter(|d| d.is_finite() && *d > 0.0)
            .unwrap_or(0.0),
    }
}

pub(super) fn info_to_rec(info: TrackInfo) -> TrackInfoRec {
    TrackInfoRec {
        title: info.title,
        artist: info.artist,
        source: info.source,
        duration_seconds: info.duration_seconds,
        codec: info.codec,
        sample_rate: info.sample_rate,
        bit_depth: info.bit_depth,
        channels: info.channels,
        kbps: info.kbps,
    }
}

#[cfg(test)]
pub(super) fn plan_automix_impl_with_tier(
    outgoing: &str,
    incoming: &str,
    outgoing_text: &str,
    incoming_text: &str,
    album_sequential: bool,
    crossfade_seconds: f64,
    outgoing_duration_seconds: f64,
    incoming_duration_seconds: f64,
    outgoing_headers: &std::collections::HashMap<String, String>,
    incoming_headers: &std::collections::HashMap<String, String>,
    tier: AutomixTier,
    allow_effects: bool,
) -> TransitionPlanRec {
    plan_automix_impl_with_tier_and_phrase_bars(
        outgoing,
        incoming,
        outgoing_text,
        incoming_text,
        album_sequential,
        crossfade_seconds,
        outgoing_duration_seconds,
        incoming_duration_seconds,
        outgoing_headers,
        incoming_headers,
        tier,
        allow_effects,
        0,
    )
}

pub(super) fn plan_automix_impl_with_tier_and_phrase_bars(
    outgoing: &str,
    incoming: &str,
    outgoing_text: &str,
    incoming_text: &str,
    album_sequential: bool,
    crossfade_seconds: f64,
    outgoing_duration_seconds: f64,
    incoming_duration_seconds: f64,
    outgoing_headers: &std::collections::HashMap<String, String>,
    incoming_headers: &std::collections::HashMap<String, String>,
    tier: AutomixTier,
    allow_effects: bool,
    phrase_bars: u32,
) -> TransitionPlanRec {
    let _inference_budget = crate::analyzer::InferenceBudget::new(tier.inference_threads());
    let skip_vocals = !tier.runs_vocal_model();
    let empty_headers = std::collections::HashMap::new();
    if skip_vocals {
        log::info!("automix: EFFICIENT tier — beat grid + energy, vocal model skipped");
    }
    let plan = crate::analyzer::plan_pair_with_phrase_bars(
        outgoing,
        incoming,
        outgoing_text,
        incoming_text,
        album_sequential,
        crossfade_seconds,
        outgoing_duration_seconds,
        incoming_duration_seconds,
        skip_vocals,
        tier.name(),
        allow_effects,
        phrase_bars,
        |path, start, dur, mono| {
            let headers = if path == outgoing {
                outgoing_headers
            } else if path == incoming {
                incoming_headers
            } else {
                &empty_headers
            };
            decode_region_at_rate(path, start, dur, mono, headers,
                mono.then_some(crate::analyzer::BEAT_SPECTROGRAM_SAMPLE_RATE as u32))
                .ok()
                .map(|r| (r.samples, r.sample_rate, r.start_seconds))
        },
        |path| {
            let tagged_duration = crate::metadata::read_track_metadata(path)
                .map(|m| m.duration_seconds)
                .filter(|duration| duration.is_finite() && *duration > 0.0)
                .unwrap_or(0.0);
            if tagged_duration > 0.0 {
                return tagged_duration;
            }
            let headers = if path == outgoing {
                outgoing_headers
            } else if path == incoming {
                incoming_headers
            } else {
                &empty_headers
            };
            crate::decode::SymphoniaDecoder::open_available(
                &crate::decode::SourceKind::parse(path),
                headers,
            )
            .ok()
            .and_then(|decoder| decoder.duration_seconds())
            .filter(|duration| duration.is_finite() && *duration > 0.0)
            .unwrap_or(0.0)
        },
    );
    TransitionPlanRec::from(plan)
}

/// lofty-backed metadata read for the local library scanner (spec §4).
#[uniffi::export]
pub fn read_track_metadata(path: String) -> Option<TrackMetadata> {
    crate::metadata::read_track_metadata(&path)
}

/// Library scans need text and timing, without copying embedded covers over FFI.
#[uniffi::export]
pub fn read_track_metadata_summary(path: String) -> Option<TrackMetadata> {
    crate::metadata::read_track_metadata_summary(&path)
}

/// Write title/artist/album/artwork onto a downloaded file.
#[uniffi::export]
pub fn write_track_tags(
    path: String,
    title: String,
    artist: String,
    album: String,
    artwork: Vec<u8>,
) -> bool {
    crate::metadata::write_track_tags(&path, &title, &artist, &album, &artwork)
}

/// Locates the next local energy dip in the audio curve for the given source
/// within [position_seconds + 0.1, position_seconds + 2.0].
#[uniffi::export]
pub fn next_energy_dip(source: String, position_seconds: f64) -> Option<f64> {
    crate::analyzer::next_energy_dip(&source, position_seconds)
}

/// Align two complete local files. Blocking and CPU-bound (a second or two for
/// a pair of four-minute tracks): call it off the main thread.
#[uniffi::export]
pub fn align_versions(song_path: String, other_path: String) -> Option<VersionAlignmentRec> {
    let alignment = crate::align::align_files(&song_path, &other_path)?;
    log::info!(
        "version alignment: {} segment(s), similarity {:.2} vs baseline {:.2}, coverage {:.2}",
        alignment.segments.len(),
        alignment.similarity,
        alignment.baseline,
        alignment.coverage
    );
    Some(VersionAlignmentRec {
        confident: alignment.is_confident(),
        segments: alignment
            .segments
            .iter()
            .map(|s| AlignmentSegmentRec {
                song_start: s.song_start,
                song_end: s.song_end,
                offset: s.offset,
            })
            .collect(),
        similarity: alignment.similarity,
        baseline: alignment.baseline,
        minimum_window_similarity: alignment.minimum_window_similarity,
        coverage: alignment.coverage,
    })
}

/// Seed an external analysis overlay (e.g. Music Understanding) for `path`.
/// The next Automix plan for that file merges the overlay onto DSP/ONNX results.
#[uniffi::export]
pub fn seed_automix_analysis(path: String, overlay: AutomixAnalysisOverlayRec) -> bool {
    crate::analyzer::seed_analysis_overlay(
        &path,
        crate::analyzer::AnalysisOverlay {
            bpm: overlay.bpm,
            beat_confidence: overlay.beat_confidence,
            beat_interval: overlay.beat_interval,
            beats: overlay.beats,
            downbeats: overlay.downbeats,
            key: overlay.key,
            key_confidence: overlay.key_confidence,
            phrase_boundaries: overlay.phrase_boundaries,
            vocal_probability: overlay.vocal_probability,
            content_end: overlay.content_end,
            audible_start: overlay.audible_start,
            outro_start: overlay.outro_start,
            mix_in_time: overlay.mix_in_time,
            source: overlay.source,
        },
    )
}

/// Sources used by the most recent Automix plan: `(outgoing, incoming)`.
/// Values are `music_understanding`, `beat_this`, `dsp`, or `disk_cache`.
#[uniffi::export]
pub fn last_automix_analysis_sources() -> Vec<String> {
    let (out, inc) = crate::analyzer::last_analysis_sources();
    vec![out, inc]
}

/// Rank Autoplay/shuffle candidates for mixing after `current_path`.
/// Returns candidate indices in preferred order (best first).
#[uniffi::export]
pub fn rank_automix_candidates(
    current_path: String,
    candidate_paths: Vec<String>,
    current_text: String,
    candidate_texts: Vec<String>,
    crossfade_seconds: f64,
    skip_vocals: bool,
) -> Vec<u32> {
    crate::analyzer::rank_candidate_indices(
        &current_path,
        &candidate_paths,
        &current_text,
        &candidate_texts,
        crossfade_seconds,
        skip_vocals,
        |path, start, dur, mono| {
            decode_region_impl(path, start, dur, mono)
                .ok()
                .map(|r| (r.samples, r.sample_rate, r.start_seconds))
        },
        |path| {
            crate::metadata::read_track_metadata(path)
                .map(|m| m.duration_seconds)
                .unwrap_or(0.0)
        },
    )
}

/// Load Automix ONNX graphs. Paths are bundle-resolved by Swift; empty unloads.
#[uniffi::export]
pub fn configure_analyzer(beat_model_path: String, vocal_model_path: String) -> bool {
    crate::analyzer::configure(&beat_model_path, &vocal_model_path)
}

/// Register or clear the host's accelerated beat backend. `identity` is the
/// digest of the verified archive the compiled model came from; it joins the
/// analysis cache key, so an accelerated analysis never aliases an rten one.
#[uniffi::export]
pub fn set_beat_accelerator(
    accelerator: Option<Box<dyn crate::analyzer::BeatAccelerator>>,
    identity: String,
) {
    crate::analyzer::set_beat_accelerator(accelerator, identity)
}

/// Engine version for the About pane.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

pub(super) fn decode_region_impl(
    source: &str,
    start_seconds: f64,
    duration_seconds: f64,
    mono: bool,
) -> Result<DecodedRegion, String> {
    decode_region_impl_with_headers(
        source,
        start_seconds,
        duration_seconds,
        mono,
        &std::collections::HashMap::new(),
    )
}

pub(super) fn decode_region_impl_with_headers(
    source: &str,
    start_seconds: f64,
    duration_seconds: f64,
    mono: bool,
    headers: &std::collections::HashMap<String, String>,
) -> Result<DecodedRegion, String> {
    decode_region_at_rate(source, start_seconds, duration_seconds, mono, headers, None)
}

// Planner-only downsampling keeps full-resolution PCM out of whole-track
// analysis. Public region decoding retains the source rate for lyrics/alignment.
fn decode_region_at_rate(
    source: &str,
    start_seconds: f64,
    duration_seconds: f64,
    mono: bool,
    headers: &std::collections::HashMap<String, String>,
    analysis_rate: Option<u32>,
) -> Result<DecodedRegion, String> {
    if !duration_seconds.is_finite() {
        return Err("non-finite decode duration".into());
    }
    let kind = crate::decode::SourceKind::parse(source);
    // Analysis must not wait out a download. Playback still does: a plan that
    // blocks until the file is complete is a plan that arrives after the blend.
    let mut decoder = crate::decode::SymphoniaDecoder::open_available(&kind, headers)
        .map_err(|e| e.to_string())?;
    if start_seconds > 0.0 {
        decoder
            .seek_seconds(start_seconds)
            .map_err(|e| e.to_string())?;
    }
    let actual_start = decoder.position_seconds();
    let rate = decoder.sample_rate();
    let output_rate = analysis_rate.map_or(rate, |target| target.min(rate));
    let want_frames = (duration_seconds.max(0.0) * rate as f64) as usize;
    let channels = if mono { 1 } else { 2 };
    let output_frames = (duration_seconds.max(0.0) * output_rate as f64).ceil() as usize;
    // Oversized/incorrect duration hints must degrade to the planner's head
    // window fallback instead of allocating until the process runs out of RAM.
    const MAX_ANALYSIS_SAMPLES: usize = 32 * 1024 * 1024;
    if analysis_rate.is_some() && output_frames > MAX_ANALYSIS_SAMPLES {
        return Err("whole-track analysis exceeds PCM memory budget".into());
    }
    let capacity = output_frames.checked_add(4096)
        .and_then(|n| n.checked_mul(channels)).ok_or("decode duration too large")?;
    let mut samples: Vec<f32> = Vec::new();
    samples.try_reserve_exact(capacity).map_err(|_| "cannot allocate decoded region")?;
    let mut resampler = analysis_rate.map(|_| crate::decode::resampler::StreamResampler::new(rate, output_rate));
    let mut read_frames = 0usize;
    while read_frames < want_frames {
        let chunk = decoder.read_stereo(4096).map_err(|e| e.to_string())?;
        if chunk.is_empty() {
            break;
        }
        read_frames += chunk.len() / 2;
        if let Some(resampler) = resampler.as_mut() {
            let mono: Vec<f32> = chunk.chunks_exact(2).map(|pair| (pair[0] + pair[1]) * 0.5).collect();
            samples.extend(resampler.process(&mono));
        } else if mono {
            samples.extend(chunk.chunks_exact(2).map(|pair| (pair[0] + pair[1]) * 0.5));
        } else {
            samples.extend_from_slice(&chunk);
        }
    }
    if let Some(resampler) = resampler.as_mut() {
        samples.extend(resampler.flush());
    }
    Ok(DecodedRegion {
        samples,
        sample_rate: output_rate,
        start_seconds: actual_start,
    })
}

#[cfg(test)]
mod memory_tests {
    use super::*;

    fn fixture() -> String { format!("{}/tests/fixtures/seek-tone.m4a", env!("CARGO_MANIFEST_DIR")) }

    #[test]
    fn mono_region_matches_stereo_downmix_without_changing_public_rate() {
        let stereo = decode_region_impl(&fixture(), 0.0, 1.0, false).unwrap();
        let mono = decode_region_impl(&fixture(), 0.0, 1.0, true).unwrap();
        assert_eq!(mono.sample_rate, stereo.sample_rate);
        assert_eq!(mono.start_seconds, stereo.start_seconds);
        let expected: Vec<f32> = stereo.samples.chunks_exact(2).map(|p| (p[0] + p[1]) * 0.5).collect();
        assert_eq!(mono.samples, expected);
    }

    #[test]
    fn analysis_streaming_resample_matches_whole_buffer_and_bounds_duration_hints() {
        let original = decode_region_impl(&fixture(), 0.0, 1.0, true).unwrap();
        let reduced = decode_region_at_rate(&fixture(), 0.0, 1.0, true, &Default::default(), Some(22050)).unwrap();
        let mut resampler = crate::decode::resampler::StreamResampler::new(original.sample_rate, reduced.sample_rate);
        let mut expected = resampler.process(&original.samples);
        expected.extend(resampler.flush());
        assert_eq!(reduced.samples.len(), expected.len());
        assert!(reduced.samples.iter().zip(&expected).all(|(a,b)| (a-b).abs() < 1e-5));
        assert!(reduced.sample_rate <= 22050);
        assert!(decode_region_at_rate(&fixture(), 0.0, 86400.0, true, &Default::default(), Some(22050))
            .unwrap_err().contains("memory budget"));
        assert!(decode_region_impl(&fixture(), 0.0, f64::INFINITY, true).is_err());
    }
}

#[uniffi::export]
pub fn detect_playback_regions(
    source: String,
    complete: bool,
) -> Result<PlaybackRegions, EngineError> {
    crate::playback_regions::detect(&source, complete)
        .map_err(|message| EngineError::LoadFailed(message))
}
#[uniffi::export]
pub fn constrain_automix_plan(
    plan: TransitionPlanRec,
    outgoing: PlaybackRegions,
    incoming: PlaybackRegions,
    outgoing_duration: f64,
    incoming_duration: f64,
) -> TransitionPlanRec {
    crate::playback_regions::constrain(
        plan,
        outgoing,
        incoming,
        outgoing_duration,
        incoming_duration,
    )
}

#[uniffi::export]
pub fn constrain_automix_plan_for_sources(
    plan: TransitionPlanRec,
    outgoing_source: String,
    incoming_source: String,
    outgoing_duration: f64,
    incoming_duration: f64,
) -> TransitionPlanRec {
    crate::playback_regions::constrain(
        plan,
        crate::playback_regions::get(&outgoing_source),
        crate::playback_regions::get(&incoming_source),
        outgoing_duration,
        incoming_duration,
    )
}
