//! Process-wide caches: analyses by source, external overlays merged onto
//! them, the sources last used, and the energy curves for swap timing.

use super::analysis::{analyze, Analysis};
use super::audio_analysis;
use std::sync::Arc;

/// Analysis cache — the difference between planning as a decision and planning
/// as a workload.
///
/// One [`analyze`] is three decodes of the same file (whole track, head window,
/// vocal window), a resample, and two ONNX passes, which for a four-minute
/// track is seconds of CPU. The app asks for the same pair over and over:
/// `syncEngineQueueNext` alone is reached from nine call sites, and each one
/// re-plans the track that follows the current one. Uncached, that is the whole
/// analysis re-run for every transport command — and it runs at the same
/// priority band as the audio decoder, which is why opening a page could be
/// heard as a stutter.
///
/// The plan itself is *not* cached: it also depends on the crossfade setting,
/// the caller's text and the album flag, all of which are cheap to re-apply.
/// Only the analysis — the expensive, file-derived half plus its duration
/// hint — is kept.
///
/// One in-flight marker per key coalesces duplicate analyses. The map lock is
/// held only for lookup/insertion/eviction; independent keys can decode at the
/// same time without allowing duplicate work for the same key.
pub(super) mod analysis_cache {
    use super::Analysis;
    use std::collections::{HashMap, VecDeque};
    use std::io::Write;
    use std::sync::{Arc, Condvar, Mutex, OnceLock};
    use std::time::UNIX_EPOCH;

    /// Enough for the head and tail of a queue; beyond that, re-decoding costs
    /// less than holding it. Each entry is tens to hundreds of kilobytes.
    const CAPACITY: usize = 6;
    const DISK_LIMIT_BYTES: u64 = 50 * 1024 * 1024;
    const SCHEMA_VERSION: u32 = 3;
    /// Seconds two reported lengths of one file may differ by.
    const DURATION_SLACK: f64 = 2.0;

    pub(crate) type Key = (String, u64, u64, u64, String, bool);

    #[derive(Default)]
    struct Cache {
        entries: HashMap<Key, Arc<Analysis>>,
        /// Insertion order, for eviction. A key never appears twice: it is only
        /// pushed on a miss, and a hit returns before that.
        order: VecDeque<Key>,
        in_flight: HashMap<Key, Arc<InFlight>>,
    }

    #[derive(Default)]
    struct InFlight {
        complete: Mutex<bool>,
        ready: Condvar,
    }

    struct InFlightOwner {
        key: Key,
        flight: Arc<InFlight>,
    }

    impl Drop for InFlightOwner {
        fn drop(&mut self) {
            let mut guard = cache()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if guard
                .in_flight
                .get(&self.key)
                .is_some_and(|current| Arc::ptr_eq(current, &self.flight))
            {
                guard.in_flight.remove(&self.key);
            }
            drop(guard);
            *self
                .flight
                .complete
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = true;
            self.flight.ready.notify_all();
        }
    }

    fn cache() -> &'static Mutex<Cache> {
        static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
        CACHE.get_or_init(|| Mutex::new(Cache::default()))
    }

    pub(crate) fn clear() {
        let mut guard = cache()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.entries.clear();
        guard.order.clear();
    }

    /// File length is part of the key because a streamed download is appended
    /// to under a stable path. Duration is part too: URL sources can start with
    /// no usable duration and acquire one from the playback/catalogue metadata
    /// later, which changes whether whole-track analysis can run.
    pub(crate) fn file_identity(path: &str) -> (u64, u64) {
        std::fs::metadata(path)
            .map(|meta| {
                let modified = meta
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                    .map(|duration| duration.as_nanos() as u64)
                    .unwrap_or(0);
                (meta.len(), modified)
            })
            .unwrap_or((0, 0))
    }

    fn disk_dir() -> Option<std::path::PathBuf> {
        #[cfg(test)]
        {
            // Unit tests must opt into an isolated directory; never fall back
            // to the developer's real application cache.
            return TEST_DISK_DIR.with(|value| value.borrow().clone());
        }
        #[cfg(not(test))]
        std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .map(|home| home.join("Library/Caches/BitChord/Analysis"))
    }

    #[cfg(test)]
    thread_local! {
        #[cfg(test)]
        static TEST_DISK_DIR: std::cell::RefCell<Option<std::path::PathBuf>> = const { std::cell::RefCell::new(None) };
    }

    #[cfg(test)]
    pub(crate) fn set_test_disk_dir(dir: std::path::PathBuf) {
        TEST_DISK_DIR.with(|value| *value.borrow_mut() = Some(dir));
    }

    pub(crate) fn disk_key(key: &Key) -> String {
        let mut hasher = sha2::Sha256::new();
        use sha2::Digest;
        hasher.update(SCHEMA_VERSION.to_le_bytes());
        hasher.update(serde_json::to_vec(key).unwrap_or_default());
        format!("{:x}", hasher.finalize())
    }

    fn read_disk(key: &Key) -> Option<Analysis> {
        let path = disk_dir()?.join(format!("{}.json", disk_key(key)));
        let bytes = std::fs::read(path).ok()?;
        let value = serde_json::from_slice(&bytes).ok()?;
        // Updating the access time makes filesystem modification time the LRU
        // signal used by the size cap.
        if let Ok(file) = std::fs::File::options()
            .append(true)
            .open(disk_dir()?.join(format!("{}.json", disk_key(key))))
        {
            let _ = file
                .set_times(std::fs::FileTimes::new().set_modified(std::time::SystemTime::now()));
        }
        Some(value)
    }

    fn write_disk(key: &Key, analysis: &Analysis) {
        let Some(dir) = disk_dir() else { return };
        if std::fs::create_dir_all(&dir).is_err() {
            return;
        }
        let path = dir.join(format!("{}.json", disk_key(key)));
        let temp = dir.join(format!("{}.tmp", disk_key(key)));
        let Ok(bytes) = serde_json::to_vec(analysis) else {
            return;
        };
        if let Ok(mut file) = std::fs::File::create(&temp) {
            if file.write_all(&bytes).is_ok() && std::fs::rename(&temp, &path).is_ok() {
                trim_disk(&dir);
                return;
            }
        }
        let _ = std::fs::remove_file(temp);
    }

    fn trim_disk(dir: &std::path::Path) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let mut files: Vec<_> = entries
            .flatten()
            .filter_map(|entry| {
                let meta = entry.metadata().ok()?;
                meta.is_file()
                    .then(|| (entry.path(), meta.len(), meta.modified().ok()))
            })
            .collect();
        let mut total: u64 = files.iter().map(|(_, size, _)| *size).sum();
        files.sort_by_key(|(_, _, modified)| *modified);
        for (path, size, _) in files {
            if total <= DISK_LIMIT_BYTES {
                break;
            }
            if std::fs::remove_file(path).is_ok() {
                total = total.saturating_sub(size);
            }
        }
    }

    pub(crate) fn get_or_compute(
        path: &str,
        skip_vocals: bool,
        duration: f64,
        compute: impl FnOnce() -> Analysis,
    ) -> Arc<Analysis> {
        let mut identity = crate::analyzer::models::analysis_identity();
        if let Some(overlay) = super::overlays::identity(path) {
            identity.push_str(";overlay=");
            identity.push_str(&overlay);
        }
        get_or_compute_for_identity(
            path,
            skip_vocals,
            duration,
            identity,
            compute,
        )
    }

    pub(crate) fn get_or_compute_for_identity(
        path: &str,
        skip_vocals: bool,
        duration: f64,
        model_identity: String,
        compute: impl FnOnce() -> Analysis,
    ) -> Arc<Analysis> {
        let (size, modified) = file_identity(path);
        // The same file arrives with two lengths: the catalogue's whole
        // seconds while it is the incoming track, the decoder's exact figure
        // once it is playing. Keyed exactly, that was a second full analysis
        // of every track at its own transition. Whole seconds are the key, and
        // a neighbour within `DURATION_SLACK` is the same file.
        let rounded = if duration.is_finite() && duration > 0.0 { duration.round() } else { 0.0 };
        let key: Key = (
            path.to_string(),
            size,
            modified,
            rounded.to_bits(),
            model_identity,
            skip_vocals,
        );
        let mut compute = Some(compute);
        loop {
            let (flight, owner) = {
                let mut guard = cache()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if let Some(hit) = guard.entries.get(&key) {
                    return hit.clone();
                }
                if rounded > 0.0 {
                    let neighbour = guard.entries.iter().find(|(k, _)| {
                        k.0 == key.0 && k.1 == key.1 && k.2 == key.2 && k.4 == key.4 && k.5 == key.5 && {
                            let other = f64::from_bits(k.3);
                            other > 0.0 && (other - rounded).abs() <= DURATION_SLACK
                        }
                    });
                    if let Some((_, hit)) = neighbour {
                        return hit.clone();
                    }
                }
                if let Some(flight) = guard.in_flight.get(&key) {
                    (flight.clone(), false)
                } else {
                    let flight = Arc::new(InFlight::default());
                    guard.in_flight.insert(key.clone(), flight.clone());
                    (flight, true)
                }
            };

            if !owner {
                let mut complete = flight
                    .complete
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                while !*complete {
                    complete = flight
                        .ready
                        .wait(complete)
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                }
                continue;
            }

            // A panic removes the in-flight entry and wakes waiters, which may
            // then retry. Disk I/O and analysis both run outside the map lock.
            let _owner = InFlightOwner {
                key: key.clone(),
                flight,
            };
            let analysis = Arc::new(if let Some(hit) = read_disk(&key) {
                hit
            } else {
                compute.take().expect("only the in-flight owner computes")()
            });
            // A transient decode failure or a short/incomplete file can produce a
            // default analysis. Keep it only in memory so a later call can retry.
            if duration > 0.0 && (analysis.bpm > 0.0 || !analysis.beats.is_empty()) {
                write_disk(&key, &analysis);
            }
            let mut guard = cache()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            guard.entries.insert(key.clone(), analysis.clone());
            guard.order.push_back(key.clone());
            while guard.order.len() > CAPACITY {
                if let Some(evicted) = guard.order.pop_front() {
                    guard.entries.remove(&evicted);
                }
            }
            drop(guard);
            return analysis;
        }
    }

    pub(crate) fn invalidate(path: &str) {
        let norm = path.strip_prefix("file://").unwrap_or(path);
        let mut guard = cache()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let doomed: Vec<Key> = guard
            .entries
            .keys()
            .filter(|(p, _, _, _, _, _)| {
                let p_norm = p.strip_prefix("file://").unwrap_or(p);
                p_norm == norm
            })
            .cloned()
            .collect();
        for key in doomed {
            guard.entries.remove(&key);
            guard.order.retain(|k| k != &key);
        }
    }

    pub(crate) fn get_cached_energy_curve(
        path: &str,
    ) -> Option<Vec<crate::analyzer::audio_analysis::EnergyPoint>> {
        let norm_path = path.strip_prefix("file://").unwrap_or(path);
        let guard = cache()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.order.iter().rev().find_map(|key| {
            let key_path = key.0.strip_prefix("file://").unwrap_or(&key.0);
            if key_path == norm_path {
                guard
                    .entries
                    .get(key)
                    .map(|analysis| analysis.energy_curve.clone())
            } else {
                None
            }
        })
    }
}

pub(crate) fn clear_analysis_cache() {
    analysis_cache::clear();
    overlays::clear();
}

/// External analysis overlay (Music Understanding, disk cache, …) merged onto
/// the DSP/ONNX result after `analyze` finishes. Rhythm/key/structure from a
/// stronger source win; envelope/energy from DSP stay unless the overlay
/// supplies replacements.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize)]
pub struct AnalysisOverlay {
    pub bpm: Option<f64>,
    pub beat_confidence: Option<f64>,
    pub beat_interval: Option<f64>,
    pub beats: Option<Vec<f64>>,
    pub downbeats: Option<Vec<f64>>,
    pub key: Option<String>,
    pub key_confidence: Option<f64>,
    pub phrase_boundaries: Option<Vec<f64>>,
    pub vocal_probability: Option<f64>,
    pub content_end: Option<f64>,
    pub audible_start: Option<f64>,
    pub outro_start: Option<f64>,
    pub mix_in_time: Option<f64>,
    /// `music_understanding` | `disk_cache` | …
    pub source: String,
}

pub(super) mod overlays {
    use super::AnalysisOverlay;
    use std::collections::{HashMap, VecDeque};
    use std::sync::{Mutex, OnceLock};

    const CAPACITY: usize = 32;
    const BYTE_LIMIT: usize = 8 * 1024 * 1024;

    #[derive(Default)]
    struct Cache {
        entries: HashMap<String, (AnalysisOverlay, String)>,
        order: VecDeque<String>,
        bytes: usize,
    }

    fn cost(path: &str, overlay: &AnalysisOverlay) -> usize {
        64 + path.len() + overlay.source.capacity() + overlay.key.as_ref().map_or(0, |s| s.capacity())
            + [&overlay.beats, &overlay.downbeats, &overlay.phrase_boundaries]
                .iter().map(|v| v.as_ref().map_or(0, |v| v.capacity() * std::mem::size_of::<f64>())).sum::<usize>()
    }

    impl Cache {
        fn put(&mut self, path: &str, overlay: AnalysisOverlay) -> bool {
            if self.entries.get(path).map(|entry| &entry.0) == Some(&overlay) {
                self.order.retain(|key| key != path);
                self.order.push_back(path.to_string());
                return false;
            }
            if let Some((old, _)) = self.entries.remove(path) {
                self.bytes -= cost(path, &old);
                self.order.retain(|key| key != path);
            }
            let size = cost(path, &overlay);
            if size > BYTE_LIMIT { return true; }
            while self.entries.len() >= CAPACITY || self.bytes + size > BYTE_LIMIT {
                let Some(key) = self.order.pop_front() else { break };
                if let Some((old, _)) = self.entries.remove(&key) { self.bytes -= cost(&key, &old); }
            }
            self.bytes += size;
            use sha2::{Digest, Sha256};
            let identity = format!("{:x}", Sha256::digest(serde_json::to_vec(&overlay).unwrap_or_default()));
            self.entries.insert(path.to_string(), (overlay, identity));
            self.order.push_back(path.to_string());
            true
        }

        fn get(&mut self, path: &str) -> Option<AnalysisOverlay> {
            let overlay = self.entries.get(path)?.0.clone();
            self.order.retain(|key| key != path);
            self.order.push_back(path.to_string());
            Some(overlay)
        }
    }

    fn map() -> &'static Mutex<Cache> {
        static MAP: OnceLock<Mutex<Cache>> = OnceLock::new();
        MAP.get_or_init(|| Mutex::new(Cache::default()))
    }

    pub(crate) fn clear() {
        *map().lock().unwrap_or_else(|p| p.into_inner()) = Cache::default();
    }

    pub(crate) fn put(path: &str, overlay: AnalysisOverlay) -> bool {
        let key = path.strip_prefix("file://").unwrap_or(path).to_string();
        map()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .put(&key, overlay)
    }

    pub(crate) fn get(path: &str) -> Option<AnalysisOverlay> {
        let key = path.strip_prefix("file://").unwrap_or(path);
        map()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(key)
    }

    pub(crate) fn identity(path: &str) -> Option<String> {
        let key = path.strip_prefix("file://").unwrap_or(path);
        let mut cache = map().lock().unwrap_or_else(|p| p.into_inner());
        let identity = cache.entries.get(key)?.1.clone();
        cache.order.retain(|path| path != key);
        cache.order.push_back(key.to_string());
        Some(identity)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn evicts_cold_overlays_and_bounds_vector_bytes() {
            let mut cache = Cache::default();
            for i in 0..CAPACITY { cache.put(&i.to_string(), AnalysisOverlay::default()); }
            assert!(cache.get("0").is_some());
            cache.put("next", AnalysisOverlay::default());
            assert!(cache.get("1").is_none());
            assert!(cache.get("0").is_some());
            let large = AnalysisOverlay { beats: Some(vec![0.0; BYTE_LIMIT / 16]), ..Default::default() };
            cache.put("large-a", large.clone());
            cache.put("large-b", large);
            assert!(cache.bytes <= BYTE_LIMIT);
            assert!(cache.get("large-a").is_none());
            assert!(cache.get("large-b").is_some());
            cache.put("large-b", AnalysisOverlay::default());
            assert!(cache.bytes < BYTE_LIMIT / 2);
        }

        #[test]
        fn identical_overlay_keeps_analysis_valid_but_updates_recency() {
            let mut cache = Cache::default();
            let overlay = AnalysisOverlay { bpm: Some(120.0), beats: Some(vec![0.0, 0.5]), ..Default::default() };
            assert!(cache.put("track", overlay.clone()));
            let bytes = cache.bytes;
            assert!(!cache.put("track", overlay.clone()));
            assert_eq!(cache.bytes, bytes);
            assert_eq!(cache.order.len(), 1);
            assert!(cache.put("track", AnalysisOverlay { bpm: Some(121.0), ..overlay }));
        }
    }
}

/// Register an external analysis overlay for `path`. The next `plan_pair`
/// analysis of that file merges it on top of DSP/ONNX results. Returns true
/// when stored.
pub fn seed_analysis_overlay(path: &str, overlay: AnalysisOverlay) -> bool {
    if path.is_empty() {
        return false;
    }
    // Re-seeding the same cached overlay must not force another whole-track
    // decode and two model passes on every queue/transport update.
    if overlays::put(path, overlay) {
        analysis_cache::invalidate(path);
    }
    true
}

/// Sources used by the most recent `plan_pair` (outgoing, incoming).
pub fn last_analysis_sources() -> (String, String) {
    last_sources::get()
}

pub(super) mod last_sources {
    use std::sync::{Mutex, OnceLock};

    fn pair() -> &'static Mutex<(String, String)> {
        static PAIR: OnceLock<Mutex<(String, String)>> = OnceLock::new();
        PAIR.get_or_init(|| Mutex::new((String::new(), String::new())))
    }

    pub(crate) fn set(outgoing: &str, incoming: &str) {
        let out = if outgoing.is_empty() { "dsp" } else { outgoing };
        let inc = if incoming.is_empty() { "dsp" } else { incoming };
        *pair().lock().unwrap_or_else(|p| p.into_inner()) = (out.into(), inc.into());
    }

    pub(crate) fn get() -> (String, String) {
        pair().lock().unwrap_or_else(|p| p.into_inner()).clone()
    }
}

pub(super) fn apply_overlay(analysis: &mut Analysis, overlay: &AnalysisOverlay) {
    // Prefer Beat This / DSP tempo when MU reports a clear half/double of an
    // already-trusted grid (common with electronic tracks). Key/structure from
    // MU still apply.
    let trust_existing_tempo =
        analysis.beat_confidence >= 0.55 && !analysis.downbeats.is_empty() && analysis.bpm > 0.0;
    let overlay_bpm = overlay.bpm.filter(|b| *b > 0.0);
    let tempo_octave = overlay_bpm.is_some_and(|bpm| {
        let ratio = bpm / analysis.bpm;
        (ratio - 2.0).abs() < 0.12
            || (ratio - 0.5).abs() < 0.06
            || (ratio - 3.0).abs() < 0.15
            || (ratio - 1.0 / 3.0).abs() < 0.05
    });
    let accept_overlay_tempo = !(trust_existing_tempo && tempo_octave);

    if accept_overlay_tempo {
        if let Some(bpm) = overlay_bpm {
            analysis.bpm = bpm;
        }
        if let Some(c) = overlay.beat_confidence {
            analysis.beat_confidence = c.clamp(0.0, 1.0);
        }
        if let Some(interval) = overlay.beat_interval.filter(|i| *i > 0.0) {
            analysis.beat_interval = interval;
        } else if analysis.bpm > 0.0 {
            analysis.beat_interval = 60.0 / analysis.bpm;
        }
        if let Some(beats) = overlay.beats.as_ref().filter(|b| b.len() >= 2) {
            analysis.beats = beats.clone();
            analysis.first_beat = beats[0];
        }
        if let Some(downbeats) = overlay.downbeats.as_ref().filter(|d| !d.is_empty()) {
            analysis.downbeats = downbeats.clone();
        }
    } else if let Some(bpm) = overlay_bpm {
        log::info!(
            "automix overlay: keeping {:.1} bpm grid; ignoring MU tempo {:.1} (octave)",
            analysis.bpm,
            bpm
        );
    }
    if let Some(key) = overlay.key.as_ref().filter(|k| !k.is_empty()) {
        analysis.key = key.clone();
    }
    if let Some(c) = overlay.key_confidence {
        analysis.key_confidence = c.clamp(0.0, 1.0);
    }
    if let Some(phrases) = overlay.phrase_boundaries.as_ref().filter(|p| !p.is_empty()) {
        analysis.phrase_boundaries = phrases.clone();
        // Treat phrase overlays as section hints when MU provides hierarchy as phrases.
        if analysis.section_boundaries.is_empty() {
            analysis.section_boundaries = phrases.clone();
        }
    }
    if let Some(v) = overlay.vocal_probability {
        analysis.vocal_probability = v.clamp(0.0, 1.0);
    }
    if let Some(end) = overlay.content_end.filter(|e| *e > 0.0) {
        analysis.content_end = end;
    }
    if let Some(start) = overlay.audible_start.filter(|s| s.is_finite() && *s >= 0.0) {
        analysis.audible_start_time = start;
    }
    if let Some(outro) = overlay.outro_start.filter(|s| *s > 0.0) {
        analysis.outro_start = outro;
    }
    if let Some(mix_in) = overlay.mix_in_time.filter(|s| *s > 0.0) {
        analysis.mix_in_time = mix_in;
    }
    if !overlay.source.is_empty() {
        // Keep a blended label when the grid stayed the model's: the MU tempo
        // was refused, or the overlay carried none (key only).
        let overlay_has_rhythm = overlay_bpm.is_some() || overlay.beats.as_ref().is_some_and(|b| b.len() >= 2);
        if (!accept_overlay_tempo || !overlay_has_rhythm) && analysis.analysis_source == "beat_this" {
            analysis.analysis_source = "beat_this+music_understanding".into();
        } else {
            analysis.analysis_source = overlay.source.clone();
        }
        log::info!(
            "automix overlay [{}]: bpm={:.1} conf={:.2} key={} phrases={}",
            analysis.analysis_source,
            analysis.bpm,
            analysis.beat_confidence,
            analysis.key,
            analysis.phrase_boundaries.len()
        );
    }
}

/// Locates the next local energy dip in the audio curve for the given source
/// within [position_seconds + 0.1, position_seconds + 2.0].
/// Used to defer source swap execution so crossfades happen in a valley.
pub fn next_energy_dip(source: &str, position_seconds: f64) -> Option<f64> {
    let curve = analysis_cache::get_cached_energy_curve(source)?;
    find_next_energy_dip(&curve, position_seconds)
}

pub(crate) fn find_next_energy_dip(
    curve: &[audio_analysis::EnergyPoint],
    position_seconds: f64,
) -> Option<f64> {
    if curve.is_empty() {
        return None;
    }
    let window_start = position_seconds + 0.1;
    let window_end = position_seconds + 2.0;

    let current_energy = curve
        .iter()
        .min_by(|a, b| {
            (a.time - position_seconds)
                .abs()
                .total_cmp(&(b.time - position_seconds).abs())
        })
        .map(|p| p.energy)
        .unwrap_or(1.0);

    let candidates: Vec<(usize, &audio_analysis::EnergyPoint)> = curve
        .iter()
        .enumerate()
        .filter(|(_, p)| p.time >= window_start && p.time <= window_end)
        .collect();

    if candidates.is_empty() {
        return None;
    }

    let mut local_minima = Vec::new();
    for (idx, p) in &candidates {
        let left_energy = if *idx > 0 {
            curve[*idx - 1].energy
        } else {
            p.energy
        };
        let right_energy = if *idx + 1 < curve.len() {
            curve[*idx + 1].energy
        } else {
            p.energy
        };
        if p.energy <= left_energy && p.energy <= right_energy {
            local_minima.push(*p);
        }
    }

    if let Some(best) = local_minima
        .iter()
        .filter(|p| p.energy < current_energy * 0.95 || p.energy < 0.7)
        .min_by(|a, b| a.energy.total_cmp(&b.energy))
    {
        return Some(best.time);
    }

    if let Some((_, min_cand)) = candidates
        .iter()
        .min_by(|(_, a), (_, b)| a.energy.total_cmp(&b.energy))
    {
        if min_cand.energy < current_energy * 0.8 && min_cand.energy < 0.6 {
            return Some(min_cand.time);
        }
    }

    None
}

/// [`analyze`], memoised on the file's identity and the vocal-model switch.
pub(super) fn analyze_cached(
    path: &str,
    skip_vocals: bool,
    decode: &impl Fn(&str, f64, f64, bool) -> Option<(Vec<f32>, u32, f64)>,
    duration: f64,
) -> Arc<Analysis> {
    if duration <= 0.0 {
        // A caller that handed us something that is not a readable audio file —
        // a `yt:<videoId>` identifier rather than a path, most likely — lands
        // here, and the degradation is otherwise silent: `analyze` skips its
        // whole-track branch because the window is `duration` seconds long, so
        // `bpm` stays 0 and `assess` can only return `Tier::Plain`. Every
        // transition becomes a plain crossfade and nothing says why. The other
        // side of the pair still analyses normally, which is what made this so
        // hard to see: the plan's cue looked right.
        log::warn!(
            "automix: no duration for {path} — whole-track analysis and tempo verdict \
             skipped, so this pair can only plan a plain crossfade (not a readable audio file?)"
        );
    }
    analysis_cache::get_or_compute(path, skip_vocals, duration, || {
        analyze(path, skip_vocals, decode, duration)
    })
}

#[cfg(test)]
mod duration_slack_tests {
    use super::analysis_cache::get_or_compute_for_identity;

    #[test]
    fn a_track_is_analysed_once_under_its_catalogue_and_decoded_lengths() {
        let path = format!("/nonexistent/slack-{}.m4a", std::process::id());
        let mut runs = 0;
        let _ = get_or_compute_for_identity(&path, true, 213.0, "id".into(), || {
            runs += 1;
            Default::default()
        });
        let _ = get_or_compute_for_identity(&path, true, 212.37, "id".into(), || {
            runs += 1;
            Default::default()
        });
        assert_eq!(runs, 1);
        let _ = get_or_compute_for_identity(&path, true, 180.0, "id".into(), || {
            runs += 1;
            Default::default()
        });
        assert_eq!(runs, 2);
    }
}
