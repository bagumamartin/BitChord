//! native-core — BitChord's analyzer + playback engine behind one UniFFI boundary.
//!
//! The FFI surface (spec §2/§3.1): a narrow `PlayerEngine` object for playback
//! control, one callback interface for engine events, and the analyzer's
//! decode/DSP entry points. Swift and Kotlin bindings are generated from this
//! surface — no hand-written C header.

uniffi::setup_scaffolding!();

pub mod align;
pub mod analyzer;
pub mod decode;
pub mod diagnostics;
pub mod eq;
pub mod metadata;
pub mod mixer;
pub mod playback_regions;
pub mod sound;
pub mod spatial;
pub mod time_stretch;
pub mod transition_filter;

mod api;
mod callback;
mod engine;
mod loudness;
mod output;
mod records;
mod render;

#[cfg(test)]
mod tests;

pub use api::{
    align_versions, configure_analyzer, constrain_automix_plan, constrain_automix_plan_for_sources,
    core_version, detect_playback_regions, last_automix_analysis_sources, next_energy_dip,
    rank_automix_candidates, read_track_metadata, read_track_metadata_summary,
    seed_automix_analysis, set_beat_accelerator, write_track_tags,
};
pub use analyzer::{BeatAccelerator, BeatLogits};
pub use callback::EngineCallback;
pub use engine::PlayerEngine;
pub use playback_regions::{PlaybackInterval, PlaybackRegions};
pub use records::{
    AlignmentSegmentRec, AudioSourceFormatRec, AutomixAnalysisOverlayRec, AutomixTier,
    DecodedRegion, EngineError, LoadRequest, MelSpectrogramResult, NerdStatsRec, OutputDeviceRec,
    OutputHealthRec, OutputPcmMode, PlaybackState, QueuedTrackRec, SourceErrorRec, TrackEndReason,
    TrackInfoRec, TrackMetadata, TransitionPlanRec, TransitionStyleRec, VerifiedAudioSourceRec,
    VersionAlignmentRec,
};
pub use sound::{ClarityPreset, ClarityTuning, LoudnessMeasurement, LoudnessMode, SoundMode};

/// The audio render thread's scheduling class.
///
/// Thread Performance Checker named the pairing that started this: a
/// user-interactive thread waiting on a default-QoS mixer. The wait is gone —
/// a seek queues and returns, like every player upstream — but the mixer's own
/// class still decides how it competes with everything else in the app for the
/// CPU. A render thread that gets scheduled late misses a real-time deadline,
/// the ring drains, and the dropout is audible as a stutter.
///
/// This used to be built only for macOS, on the reading that the class was a
/// desktop concern. iOS has the same API and the same problem, and the cost of
/// the omission was worse there: a Darwin thread inherits its creator's class,
/// and the mixer is spawned from the engine-startup task, which is `.utility` —
/// so the decoder ran in the same band as the artwork fetches and the automix
/// analysis it is supposed to outrank, and every page the listener opened took
/// the CPU it needed. That is the "navigation makes the music stutter" report.
mod qos {
    /// Puts the calling thread in the user-interactive class.
    ///
    /// The relative priority argument is 0: the mixer keeps the class that a
    /// gesture runs at rather than claiming a higher band than the UI, so this
    /// cannot outrank the main thread. It only stops the mixer being starved
    /// by it.
    #[cfg(target_vendor = "apple")]
    pub fn raise_current_thread() {
        // SAFETY: `pthread_set_qos_class_self_np` reads the calling thread's
        // QoS and stores a class on it. No pointer argument, nothing to get
        // wrong, and the return value only reports an unavailable class.
        unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
        }
    }

    /// Nothing to raise: only Apple platforms express a scheduling class here,
    /// and on the others the equivalent is the platform's own audio policy.
    #[cfg(not(target_vendor = "apple"))]
    pub fn raise_current_thread() {}
}
