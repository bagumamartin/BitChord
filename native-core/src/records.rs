//! The records, enums and errors the engine exchanges with Swift and Kotlin.

use crate::mixer::{TransitionPlan, TransitionStyle};

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaybackState {
    Stopped,
    Buffering,
    Playing,
    Paused,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackEndReason {
    /// Ran out of track with nothing queued behind it.
    Natural,
    /// Replaced by an explicit load.
    Skipped,
    Error,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransitionStyleRec {
    EqualPower,
    DjFilter,
    DjBlend,
    Gapless,
    EchoOut,
    LoopRoll,
    ReverbWash,
    DropCut,
    Texture,
    Brake,
}

impl From<TransitionStyleRec> for TransitionStyle {
    fn from(value: TransitionStyleRec) -> Self {
        match value {
            TransitionStyleRec::EqualPower => TransitionStyle::EqualPower,
            TransitionStyleRec::DjFilter => TransitionStyle::DjFilter,
            TransitionStyleRec::DjBlend => TransitionStyle::DjBlend,
            TransitionStyleRec::Gapless => TransitionStyle::Gapless,
            TransitionStyleRec::EchoOut => TransitionStyle::EchoOut,
            TransitionStyleRec::LoopRoll => TransitionStyle::LoopRoll,
            TransitionStyleRec::ReverbWash => TransitionStyle::ReverbWash,
            TransitionStyleRec::DropCut => TransitionStyle::DropCut,
            TransitionStyleRec::Texture => TransitionStyle::Texture,
            TransitionStyleRec::Brake => TransitionStyle::Brake,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct TransitionPlanRec {
    pub style: TransitionStyleRec,
    pub bass_swap: bool,
    pub bass_swap_fraction: f64,
    pub filter_sweep: f64,
    pub vocal_overlap: f64,
    /// Explicit fade length for this pair; 0 = engine's crossfade window.
    pub fade_seconds: f64,
    /// Seconds from the blend start during which the outgoing stays at unity
    /// before it begins to fall; 0 = the normal equal-power crossing.
    ///
    /// A cold ending sets this to a phrase so the final chord is struck at
    /// unity and only its decay is faded through; the incoming entered a
    /// phrase earlier and is rising underneath it.
    #[uniffi(default = 0.0)]
    pub outgoing_hold_seconds: f64,
    /// F's loop bridge: where on the outgoing's timeline the measured unit
    /// starts, how long it is (the measured downbeat span), and how many times
    /// it is replayed. 0 = no bridge.
    #[uniffi(default = 0.0)]
    pub bridge_start_seconds: f64,
    #[uniffi(default = 0.0)]
    pub bridge_seconds: f64,
    #[uniffi(default = 0)]
    pub bridge_repeats: u32,
    /// The effect's own window inside the blend; 0 = no effect.
    #[uniffi(default = 0.0)]
    pub effect_seconds: f64,
    /// Where the effect window starts on the outgoing timeline; 0 = no effect.
    #[uniffi(default = 0.0)]
    pub effect_start_seconds: f64,
    /// Where the blend ends, as a position in the outgoing track's timeline;
    /// 0 = the file end. The planner picks it (the ranked mix-out anchor) and
    /// derives the bass swap and vocal overlap from the window it defines, so
    /// the mixer has to arm from it rather than from the file's last byte.
    pub transition_end_seconds: f64,
    /// Where the incoming track is cued (Automix mix-in point). 0 = top.
    ///
    /// Bounded by the planner: a mix-in is the top of the incoming track's own
    /// intro, snapped to a downbeat, and never more than `MAX_CUE_SECONDS` /
    /// `MAX_CUE_BEATS` / `MAX_CUE_FRACTION` into the file. 0 also means "no
    /// usable beat grid", in which case the next record plays from the top
    /// rather than from a guess.
    pub cue_seconds: f64,
    /// Tempo stretch — applied by the mixer. Pitch-preserving: the handoff
    /// stretch runs through WSOLA (`time_stretch`), held for the blend, then
    /// glided back to unity over `post_glide_seconds`.
    pub playback_rate: f64,
    /// See `mixer::TransitionPlan::bed_fraction`.
    pub bed_fraction: f64,
    /// See `mixer::TransitionPlan::bed_gain_db`.
    pub bed_gain_db: f64,
    /// See `mixer::TransitionPlan::dip_depth`.
    pub dip_depth: f64,
    /// See `mixer::TransitionPlan::dip_width`.
    pub dip_width: f64,
    /// See `mixer::TransitionPlan::post_glide_seconds`.
    pub post_glide_seconds: f64,
    /// The outgoing track's length as the planner measured it. See
    /// `mixer::TransitionPlan::outgoing_duration_seconds` — it is what makes a
    /// transition schedulable when the container declares no duration of its
    /// own.
    pub outgoing_duration_seconds: f64,
    /// See `mixer::TransitionPlan::beat_seconds`.
    #[uniffi(default = 0.0)]
    pub beat_seconds: f64,
    /// Why the planner chose this style — for the transition log and the
    /// audio pipeline readout.
    #[uniffi(default = "")]
    pub reason: String,
}

impl From<TransitionPlanRec> for TransitionPlan {
    fn from(rec: TransitionPlanRec) -> Self {
        TransitionPlan {
            style: rec.style.into(),
            bass_swap: rec.bass_swap,
            bass_swap_fraction: rec.bass_swap_fraction,
            filter_sweep: rec.filter_sweep,
            vocal_overlap: rec.vocal_overlap,
            fade_seconds: rec.fade_seconds,
            outgoing_hold_seconds: rec.outgoing_hold_seconds,
            bridge_start_seconds: rec.bridge_start_seconds,
            bridge_seconds: rec.bridge_seconds,
            bridge_repeats: rec.bridge_repeats,
            effect_seconds: rec.effect_seconds,
            effect_start_seconds: rec.effect_start_seconds,
            transition_end_seconds: rec.transition_end_seconds,
            cue_seconds: rec.cue_seconds,
            playback_rate: rec.playback_rate,
            bed_fraction: rec.bed_fraction,
            bed_gain_db: rec.bed_gain_db,
            dip_depth: rec.dip_depth,
            dip_width: rec.dip_width,
            post_glide_seconds: rec.post_glide_seconds,
            outgoing_duration_seconds: rec.outgoing_duration_seconds,
            beat_seconds: rec.beat_seconds,
            reason: rec.reason,
        }
    }
}

impl From<TransitionPlan> for TransitionPlanRec {
    fn from(plan: TransitionPlan) -> Self {
        Self {
            style: match plan.style {
                TransitionStyle::Gapless => TransitionStyleRec::Gapless,
                TransitionStyle::EqualPower => TransitionStyleRec::EqualPower,
                TransitionStyle::DjFilter => TransitionStyleRec::DjFilter,
                TransitionStyle::DjBlend => TransitionStyleRec::DjBlend,
                TransitionStyle::EchoOut => TransitionStyleRec::EchoOut,
                TransitionStyle::LoopRoll => TransitionStyleRec::LoopRoll,
                TransitionStyle::ReverbWash => TransitionStyleRec::ReverbWash,
                TransitionStyle::DropCut => TransitionStyleRec::DropCut,
                TransitionStyle::Texture => TransitionStyleRec::Texture,
                TransitionStyle::Brake => TransitionStyleRec::Brake,
            },
            bass_swap: plan.bass_swap,
            bass_swap_fraction: plan.bass_swap_fraction,
            filter_sweep: plan.filter_sweep,
            vocal_overlap: plan.vocal_overlap,
            fade_seconds: plan.fade_seconds,
            outgoing_hold_seconds: plan.outgoing_hold_seconds,
            bridge_start_seconds: plan.bridge_start_seconds,
            bridge_seconds: plan.bridge_seconds,
            bridge_repeats: plan.bridge_repeats,
            effect_seconds: plan.effect_seconds,
            effect_start_seconds: plan.effect_start_seconds,
            transition_end_seconds: plan.transition_end_seconds,
            cue_seconds: plan.cue_seconds,
            playback_rate: plan.playback_rate,
            bed_fraction: plan.bed_fraction,
            bed_gain_db: plan.bed_gain_db,
            dip_depth: plan.dip_depth,
            dip_width: plan.dip_width,
            post_glide_seconds: plan.post_glide_seconds,
            outgoing_duration_seconds: plan.outgoing_duration_seconds,
            beat_seconds: plan.beat_seconds,
            reason: plan.reason,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct LoadRequest {
    /// Local file path (security-scoped bookmarks resolved Swift-side) or an
    /// http(s) URL for the streaming reader.
    pub source: String,
    pub title: String,
    pub artist: String,
    /// Start offset (Automix cue). 0 = top.
    pub start_seconds: f64,
    pub plan: Option<TransitionPlanRec>,
    /// HTTP headers the streaming reader must present (User-Agent, Origin,
    /// Referer). googlevideo bakes the minting client into the URL and
    /// compares these on the media fetch — a mismatch throttles or 403s.
    pub headers: Option<std::collections::HashMap<String, String>>,
    /// Resolver-claimed bitrate (0 = unknown).
    pub claimed_kbps: Option<u32>,
    /// Per-track loudness from the player response (`None` for local files
    /// and substitutes). Upstream's `StreamResolver.loudnessDbFor`; the mixer
    /// stays at unity gain without one.
    pub loudness_db: Option<f64>,
    /// Track length the caller knows (catalogue response or local metadata).
    ///
    /// Not a convenience field: it is what makes a transition schedulable at
    /// all. Plenty of containers declare no duration — a bare MP3 with no Xing
    /// tag, a progressively-fetched MP4 whose `moov` has not arrived, most WebM
    /// — and with no end to schedule against the mixer cannot arm the incoming
    /// track, so the queue advances by a cut rather than a blend. The
    /// container's own figure still wins where it has one; this is the
    /// fallback.
    pub duration_seconds: Option<f64>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct TrackInfoRec {
    pub title: String,
    pub artist: String,
    pub source: String,
    pub duration_seconds: f64,
    pub codec: String,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub channels: u32,
    pub kbps: u32,
}

/// Identity of the mixer's armed successor, for the skip peek. Title/artist
/// is what the app matches against its queue; the source disambiguates
/// repeats of the same recording.
#[derive(uniffi::Record, Debug, Clone)]
pub struct QueuedTrackRec {
    pub title: String,
    pub artist: String,
    pub source: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct NerdStatsRec {
    pub codec: String,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub channels: u32,
    pub kbps: u32,
    /// Applied loudness correction in dB (`None` = unity: switch off or no
    /// figure). The pipeline panel reads this, not the setting.
    pub loudness_gain_db: Option<f32>,
    /// The level correction the last armed transition applied to its incoming
    /// deck, in dB. `None` when none was armed — no comparable figures, or the
    /// decks were already level.
    pub transition_match_db: Option<f32>,
    /// Pearson correlation between the two encodings of the last source swap,
    /// measured on the samples that were blended. `None` until one has run.
    /// The swap fades a recording into another copy of itself, so this is what
    /// decides whether its linear fade is the level-flat one.
    pub swap_correlation: Option<f64>,
    pub active_stages: Vec<String>,
    pub converter_delay_frames: f64,
    pub protection_reduction_db: f32,
    pub protection_interventions: u64,
    pub build_revision: String,
    pub decoder_implementation: String,
    pub decoded_layout: String,
    pub queued_target_ms: u64,
    pub loudness_origin: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct DecodedRegion {
    /// Interleaved stereo (or mono when `mono` was requested) f32 samples.
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub start_seconds: f64,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct DecodedPcm {
    /// Mono samples as little-endian f32 bytes.
    pub pcm: Vec<u8>,
    pub sample_rate: u32,
    pub start_seconds: f64,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct TrackMetadata {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_seconds: f64,
    /// Encoded artwork bytes (JPEG/PNG as embedded), empty when none.
    pub artwork: Vec<u8>,
    /// The tag's track number within its album, 0 when the tag carries none.
    /// Tag-derived albums sort and display by it instead of by filename
    /// (upstream a6ea0ed1's MediaStore read).
    pub track_number: u32,
}

/// PCM properties discovered before playback. The app uses the source rate to
/// request the matching DAC clock before the first sample is rendered.
#[derive(uniffi::Record, Debug, Clone)]
pub struct AudioSourceFormatRec {
    pub codec: String,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub channels: u32,
    pub lossless_pcm: bool,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct SourceErrorRec {
    pub source: String,
    pub message: String,
}

/// Properties after successfully decoding a bounded PCM window.
#[derive(uniffi::Record, Debug, Clone)]
pub struct VerifiedAudioSourceRec {
    pub format: AudioSourceFormatRec,
    pub estimated_kbps: Option<u32>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct MelSpectrogramResult {
    pub frames: u64,
    pub mels: u64,
    /// Row-major [frames][mels], log1p(1000·magnitude).
    pub values: Vec<f32>,
}

#[derive(uniffi::Error, Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    NoOutputDevice,
    StreamInit(String),
    LoadFailed(String),
    NotStarted,
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::NoOutputDevice => write!(f, "no audio output device"),
            EngineError::StreamInit(e) => write!(f, "stream init failed: {e}"),
            EngineError::LoadFailed(e) => write!(f, "load failed: {e}"),
            EngineError::NotStarted => write!(f, "engine not started"),
        }
    }
}

impl std::error::Error for EngineError {}

/// What the engine actually opened, for the audio pipeline readout.
///
/// A snapshot rather than a live query: the answer changes only when the route
/// does, and the readout is a panel the listener opens to look at, not a
/// dashboard polling a device. `started` is separate from the format because
/// "nothing is open yet" and "something is open" are the two states worth
/// telling apart — the first means the panel is empty for a reason, and the
/// second means every row below it is real.
/// Requested PCM word length at the output boundary.
///
/// Upstream's `OutputPcmMode`, minus the 24-bit rung: Media3's sink chain has
/// no packed-24 path (its own comment says so), and neither does this one —
/// CoreAudio converts whatever the unit is opened as, so a 24-bit request
/// would name a depth that was never written. PCM_16 opens the unit as int16
/// (quantized at the callback); FLOAT_32 is the lossless path and the mix
/// format throughout.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputPcmMode {
    Pcm16,
    Float32,
}

impl OutputPcmMode {
    /// Stored settings predate this enum and one of them names a rung that
    /// never existed here — both fall back to the lossless path rather than
    /// the lossy one, because a wrong default should cost nothing audible.
    pub(super) fn parse(mode: &str) -> Self {
        match mode {
            "FLOAT_32" | "PCM_24" => OutputPcmMode::Float32,
            _ => OutputPcmMode::Pcm16,
        }
    }

    pub(super) fn label(self) -> &'static str {
        match self {
            OutputPcmMode::Pcm16 => "PCM_16",
            OutputPcmMode::Float32 => "FLOAT_32",
        }
    }
}

/// CPU budget for Automix analysis (upstream `AutomixPerformanceMode`).
///
/// Per-run RTen pools cap neural inference at 1 / 1 / 4 workers, limited by
/// available CPUs. EFFICIENT also skips the open-unmix vocal model; BALANCED
/// and PERFORMANCE run the full graphs with different parallelism budgets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AutomixTier {
    Efficient,
    Balanced,
    Performance,
}

impl AutomixTier {
    pub(crate) fn inference_threads(self) -> usize {
        // BALANCED is one worker: the planner's own thread plus two inference
        // workers put a transition's analysis on three cores at once, which is
        // the burst above 100% a listener sees. A plan has the rest of the song
        // to finish in, so taking twice as long on one core costs nothing
        // audible. PERFORMANCE is the opt-in for speed over a quiet machine.
        match self { Self::Efficient => 1, Self::Balanced => 1, Self::Performance => 4 }
    }
    /// The share of one core a transition plan may hold (see `pace`). One
    /// worker still ran flat out for seconds, a core on its own; paced, the
    /// planner leaves room for the interface and the mixer and the plan lands
    /// a few seconds later, long before the transition it is for.
    pub(crate) fn analysis_duty(self) -> Option<f64> {
        match self { Self::Efficient => Some(0.5), Self::Balanced => Some(0.6), Self::Performance => None }
    }
    pub(super) fn parse(mode: &str) -> Self {
        match mode {
            "EFFICIENT" => AutomixTier::Efficient,
            "PERFORMANCE" => AutomixTier::Performance,
            _ => AutomixTier::Balanced,
        }
    }

    /// Whether the vocal-separation model runs for this plan.
    pub(super) fn runs_vocal_model(self) -> bool {
        self != AutomixTier::Efficient
    }

    /// Label for the plan log, so a transition can be traced back to the tier
    /// that produced it.
    pub(super) fn name(self) -> &'static str {
        match self {
            AutomixTier::Efficient => "EFFICIENT",
            AutomixTier::Balanced => "BALANCED",
            AutomixTier::Performance => "PERFORMANCE",
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct OutputDeviceRec {
    pub name: String,
    pub sample_rate: u32,
    pub channels: u32,
    pub started: bool,
    /// Word length the unit was actually opened as (`PCM_16` = int16 stream,
    /// `FLOAT_32` = float). The setting is the request; this is the answer.
    pub sample_format: String,
    /// True only while an eligible lossless track uses exact-rate integer
    /// output, CoreAudio exclusive access, and the mixer bypass path.
    pub bit_perfect_active: bool,
    /// Why the requested bit-perfect path is inactive for this track/route.
    pub bit_perfect_reason: String,
}

/// Monotonic output counters for a device playback trace. Compare deltas while
/// a track is playing. iOS stops rendering during an ordinary pause; other
/// platforms may keep the output callback running while the queue is idle.
#[derive(uniffi::Record, Debug, Clone)]
pub struct OutputHealthRec {
    pub buffered_frames: u64,
    pub callback_underruns: u64,
    pub output_rebuilds: u64,
    pub output_xruns: u64,
    /// Peak absolute sample the device callback last wrote (0.0 = silence).
    pub output_peak: f32,
}

/// Load Automix ONNX graphs. Paths are bundle-resolved by Swift; empty unloads.
#[derive(uniffi::Record, Debug, Clone, Default)]
pub struct AutomixAnalysisOverlayRec {
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

/// One stretch of a version alignment: song time `t` in
/// `[song_start, song_end)` sits at `t + offset` in the other upload.
#[derive(uniffi::Record, Debug, Clone)]
pub struct AlignmentSegmentRec {
    pub song_start: f64,
    pub song_end: f64,
    pub offset: f64,
}

/// Where a song's moments fall in another upload of the same recording (see
/// `align`). `confident` is the gate for laying a picture by it.
#[derive(uniffi::Record, Debug, Clone)]
pub struct VersionAlignmentRec {
    pub segments: Vec<AlignmentSegmentRec>,
    pub similarity: f64,
    pub baseline: f64,
    pub minimum_window_similarity: f64,
    pub coverage: f64,
    pub confident: bool,
}
