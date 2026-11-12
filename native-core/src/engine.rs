//! `PlayerEngine`: the object the apps hold, and the methods they call on it.

use crate::analyzer::BeatSpectrogram;
use crate::api::{
    decode_region_impl, decode_region_impl_with_headers, info_to_rec,
    plan_automix_impl_with_tier_and_phrase_bars,
    to_track_source,
};
use crate::callback::{CallbackHolder, EngineCallback, SharedEvents};
use crate::mixer::{Command, TrackInfo};
use crate::output::{
    acquire_output_exclusive, choose_format, is_lossless_pcm_codec, open_output_stream,
    pick_output_device, release_output_exclusive, OutputControl, OutputHold,
};
use crate::records::{
    AudioSourceFormatRec, AutomixTier, DecodedRegion, EngineError, LoadRequest,
    MelSpectrogramResult, NerdStatsRec, OutputDeviceRec, OutputHealthRec, OutputPcmMode,
    QueuedTrackRec, TrackInfoRec, TransitionPlanRec, VerifiedAudioSourceRec,
};
use crate::{ClarityTuning, LoudnessMeasurement, LoudnessMode, PlaybackRegions, SoundMode};
use cpal::traits::StreamTrait;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

#[derive(uniffi::Object)]
pub struct PlayerEngine {
    pub(super) commands: crossbeam_channel::Sender<Command>,
    pub(super) command_rx: Mutex<Option<crossbeam_channel::Receiver<Command>>>,
    pub(super) events: Arc<SharedEvents>,
    pub(super) buffered_frames: Arc<AtomicU64>,
    pub(super) callback_underruns: Arc<AtomicU64>,
    pub(super) output_rebuilds: Arc<AtomicU64>,
    pub(super) output_xruns: Arc<AtomicU64>,
    /// Peak absolute sample the output callback actually wrote, as f32 bits.
    /// `0.0` means the callback is being fed silence — which distinguishes
    /// "the ring is empty/quiet" from "the stream is not reaching the speaker".
    pub(super) output_peak: Arc<AtomicU32>,
    pub(super) position_ms: Arc<AtomicU64>,
    pub(super) duration_ms: Arc<AtomicU64>,
    pub(super) user_volume_bits: AtomicU32,
    pub(super) sleep_gain_bits: Arc<AtomicU32>,
    pub(super) volume_bits: Arc<AtomicU32>,
    pub(super) flush_ring: Arc<AtomicBool>,
    pub(super) bail_flush: Arc<AtomicBool>,
    /// When set, the device callback outputs silence immediately — pause must
    /// not wait for the mixer to drain ~2 s of already-queued samples.
    pub(super) output_paused: Arc<AtomicBool>,
    pub(super) output_holds: Arc<AtomicU32>,
    pub(super) started: AtomicBool,
    pub(super) shutdown: Arc<AtomicBool>,
    pub(super) stream: Arc<Mutex<Option<cpal::Stream>>>,
    pub(super) rebuilding: Arc<AtomicBool>,
    pub(super) output_rate: Arc<AtomicU32>,
    pub(super) output_channels: Arc<AtomicU32>,
    /// The format the host platform asked for, `0` meaning "no opinion". iOS
    /// knows the hardware format because the `AVAudioSession` owns it there, and
    /// cpal's own answer is the RemoteIO unit's opinion of the same thing; when
    /// the two disagree the unit can fail to start without an error worth
    /// reading. macOS has no such owner, so it leaves these at `0` and cpal's
    /// device choice stands.
    pub(super) requested_rate: Arc<AtomicU32>,
    pub(super) requested_channels: Arc<AtomicU32>,
    /// The name of the device the output was last opened on, for the audio
    /// pipeline readout. Empty until a stream is built. `Mutex` rather than an
    /// atomic because a device name is a `String` and there is no reason to
    /// pretend otherwise; the panel reads it, nothing writes it in a loop.
    pub(super) device_name: Arc<Mutex<String>>,
    pub(super) nerd: Arc<Mutex<crate::mixer::NerdSnapshot>>,
    /// Requested PCM word length (0 = PCM_16, 1 = FLOAT_32). Read when a
    /// stream is (re)built; changing it rebuilds the unit.
    pub(super) pcm_mode: Arc<AtomicU32>,
    /// Encoding negotiated with the current output device, separate from the
    /// setting request so the pipeline readout reports what was opened.
    pub(super) active_pcm_mode: Arc<AtomicU32>,
    /// Exact integer depth requested for the current track, or zero when the
    /// ordinary mixed output path is in use.
    pub(super) bit_perfect_depth: Arc<AtomicU32>,
    /// Exact integer depth opened by the callback, or zero when inactive.
    pub(super) active_bit_perfect_depth: Arc<AtomicU32>,
    pub(super) bit_perfect_enabled: AtomicBool,
    /// Whether a manual Next may use a short beat-synced transition. Updated
    /// by the app when AutoMix, the opt-in, party membership or repeat mode changes.
    pub(super) skip_mix_enabled: AtomicBool,
    pub(super) bit_perfect_reason: Arc<Mutex<String>>,
    /// Prefer a USB audio device over the system default (upstream
    /// `preferUsbDac`). Advisory on iOS, where the session owns the route;
    /// a real device choice on macOS.
    pub(super) prefer_usb: Arc<AtomicBool>,
    /// Loudness-normalization master switch (upstream
    /// `loudnessNormalization`, on by default).
    pub(super) loudness_enabled: Arc<AtomicBool>,
    /// Automix analysis tier (EFFICIENT / BALANCED / PERFORMANCE). Read when
    /// a plan is computed; no rebuild involved.
    pub(super) automix_tier: Arc<Mutex<AutomixTier>>,
    /// Requested effect phrase length (0 = adaptive); read when a plan is computed.
    pub(super) automix_phrase_bars: Arc<Mutex<u32>>,
    /// The output control built at `start`, retained so later setting changes
    /// (PCM mode, route preference) can ask for the same rebuild a route
    /// change gets.
    pub(super) control: Mutex<Option<OutputControl>>,
}

#[uniffi::export]
impl PlayerEngine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        let (tx, rx) = crossbeam_channel::unbounded::<Command>();
        Arc::new(Self {
            commands: tx,
            command_rx: Mutex::new(Some(rx)),
            events: Arc::new(SharedEvents::default()),
            buffered_frames: Arc::new(AtomicU64::new(0)),
            callback_underruns: Arc::new(AtomicU64::new(0)),
            output_rebuilds: Arc::new(AtomicU64::new(0)),
            output_xruns: Arc::new(AtomicU64::new(0)),
            output_peak: Arc::new(AtomicU32::new(0.0f32.to_bits())),
            position_ms: Arc::new(AtomicU64::new(0)),
            duration_ms: Arc::new(AtomicU64::new(0)),
            user_volume_bits: AtomicU32::new(1.0f32.to_bits()),
            sleep_gain_bits: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            volume_bits: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            flush_ring: Arc::new(AtomicBool::new(false)),
            bail_flush: Arc::new(AtomicBool::new(false)),
            output_paused: Arc::new(AtomicBool::new(false)),
            output_holds: Arc::new(AtomicU32::new(0)),
            started: AtomicBool::new(false),
            shutdown: Arc::new(AtomicBool::new(false)),
            stream: Arc::new(Mutex::new(None)),
            rebuilding: Arc::new(AtomicBool::new(false)),
            output_rate: Arc::new(AtomicU32::new(0)),
            output_channels: Arc::new(AtomicU32::new(2)),
            requested_rate: Arc::new(AtomicU32::new(0)),
            requested_channels: Arc::new(AtomicU32::new(0)),
            device_name: Arc::new(Mutex::new(String::new())),
            nerd: Arc::new(Mutex::new(crate::mixer::NerdSnapshot::default())),
            pcm_mode: Arc::new(AtomicU32::new(if cfg!(target_os = "ios") { 1 } else { 0 })),
            active_pcm_mode: Arc::new(AtomicU32::new(if cfg!(target_os = "ios") { 1 } else { 0 })),
            bit_perfect_depth: Arc::new(AtomicU32::new(0)),
            active_bit_perfect_depth: Arc::new(AtomicU32::new(0)),
            bit_perfect_enabled: AtomicBool::new(false),
            skip_mix_enabled: AtomicBool::new(false),
            bit_perfect_reason: Arc::new(Mutex::new("Bit-perfect output is off".into())),
            prefer_usb: Arc::new(AtomicBool::new(false)),
            loudness_enabled: Arc::new(AtomicBool::new(false)),
            automix_tier: Arc::new(Mutex::new(AutomixTier::Balanced)),
            automix_phrase_bars: Arc::new(Mutex::new(0)),
            control: Mutex::new(None),
        })
    }

    pub fn register_callback(&self, callback: Box<dyn EngineCallback>) {
        *self.events.inner.lock().unwrap() = Some(CallbackHolder(Arc::from(callback)));
    }

    /// Enable the short beat-synced manual-Next transition, matching upstream
    /// `DesktopAudioEngine.setSkipMixEnabled` / `beginSkipMix`.
    pub fn set_skip_mix_enabled(&self, enabled: bool) {
        self.skip_mix_enabled.store(enabled, Ordering::Release);
    }

    /// Opens the output device and starts the mixer thread.
    ///
    /// `rate` and `channels` are the host platform's own figures when it has
    /// them — iOS reads them off the `AVAudioSession`, which owns the hardware
    /// format there, and passes them in so the audio unit and the session agree
    /// by construction. `None` asks cpal, which is the only answer available
    /// everywhere else.
    pub fn start(&self, rate: Option<f64>, channels: Option<u32>) -> Result<(), EngineError> {
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .format(|buf, record| {
                use std::io::Write;
                crate::diagnostics::technical_event(format!(
                    "{} {}",
                    record.level(),
                    record.args()
                ));
                writeln!(buf, "{} {}", record.level(), record.args())
            })
            .try_init();
        if self.started.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        let host = cpal::default_host();
        let Some(device) = pick_output_device(&host, self.prefer_usb.load(Ordering::Relaxed))
        else {
            self.started.store(false, Ordering::Release);
            return Err(EngineError::NoOutputDevice);
        };
        // Remember the platform's request before asking cpal, so a later
        // rebuild (route change) resolves the same way the first start did.
        if let Some(r) = rate.filter(|r| *r > 0.0) {
            self.requested_rate.store(r as u32, Ordering::Relaxed);
        }
        if let Some(c) = channels.filter(|c| *c > 0) {
            self.requested_channels.store(c, Ordering::Relaxed);
        }
        let selected = match choose_format(
            &device,
            self.requested_rate.load(Ordering::Relaxed),
            self.requested_channels.load(Ordering::Relaxed),
            self.pcm_mode.load(Ordering::Relaxed) == 0,
        ) {
            Ok(selected) => selected,
            Err(error) => {
                self.started.store(false, Ordering::Release);
                return Err(error);
            }
        };
        let sample_rate = selected.sample_rate;
        let channels = selected.channels;
        self.output_rate.store(sample_rate, Ordering::Relaxed);
        self.output_channels
            .store(channels as u32, Ordering::Relaxed);
        // The device's own name, because "no sound" is otherwise indistinguishable
        // from "the wrong output". A machine with no real sink (a VM, a session
        // with nothing plugged in) resolves to a null device that drains as fast
        // as the callback fires, which looks exactly like a mixer running far too
        // fast — so the name is what tells those two apart.
        *self.device_name.lock().unwrap() = device.to_string();
        log::info!("output {device} — {sample_rate} Hz, {channels} ch");

        // Capacity is a one-second recovery ceiling; the mixer fills only 250 ms.
        let ring_cap = sample_rate as usize * 2;
        let (producer, consumer) = rtrb::RingBuffer::<f32>::new(ring_cap);
        let rx = self
            .command_rx
            .lock()
            .unwrap()
            .take()
            .ok_or(EngineError::NotStarted)?;
        let buffered = self.buffered_frames.clone();
        let position = self.position_ms.clone();
        let duration = self.duration_ms.clone();
        let events = self.events.clone();
        let shutdown = self.shutdown.clone();
        let mixer_flush = self.flush_ring.clone();
        let mixer_bail = self.bail_flush.clone();
        let nerd = self.nerd.clone();
        let _ = self
            .commands
            .send(Command::ObserveUnderruns(self.callback_underruns.clone()));

        std::thread::Builder::new()
            .name("native-core-mixer".into())
            .spawn(move || {
                crate::qos::raise_current_thread();
                crate::mixer::run_mixer(
                    rx,
                    producer,
                    buffered,
                    position,
                    duration,
                    sample_rate,
                    events,
                    shutdown,
                    mixer_flush,
                    mixer_bail,
                    nerd,
                )
            })
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;

        let control = OutputControl {
            shutdown: self.shutdown.clone(),
            commands: self.commands.clone(),
            stream: self.stream.clone(),
            rebuilding: self.rebuilding.clone(),
            rebuild_forced: Arc::new(AtomicBool::new(false)),
            output_rate: self.output_rate.clone(),
            output_channels: self.output_channels.clone(),
            requested_rate: self.requested_rate.clone(),
            requested_channels: self.requested_channels.clone(),
            device_name: self.device_name.clone(),
            volume_bits: self.volume_bits.clone(),
            sleep_gain_bits: self.sleep_gain_bits.clone(),
            buffered: self.buffered_frames.clone(),
            callback_underruns: self.callback_underruns.clone(),
            output_rebuilds: self.output_rebuilds.clone(),
            output_xruns: self.output_xruns.clone(),
            output_peak: self.output_peak.clone(),
            flush_ring: self.flush_ring.clone(),
            bail_flush: self.bail_flush.clone(),
            output_paused: self.output_paused.clone(),
            output_holds: self.output_holds.clone(),
            rebuild_lock: Arc::new(Mutex::new(())),
            pcm_mode: self.pcm_mode.clone(),
            active_pcm_mode: self.active_pcm_mode.clone(),
            bit_perfect_depth: self.bit_perfect_depth.clone(),
            active_bit_perfect_depth: self.active_bit_perfect_depth.clone(),
            bit_perfect_reason: self.bit_perfect_reason.clone(),
            prefer_usb: self.prefer_usb.clone(),
        };
        let stream = open_output_stream(
            &device,
            sample_rate,
            channels,
            selected.pcm16,
            selected.bit_perfect_depth,
            consumer,
            &control,
        )?;
        stream
            .play()
            .map_err(|e| EngineError::StreamInit(e.to_string()))?;
        self.active_pcm_mode
            .store(if selected.pcm16 { 0 } else { 1 }, Ordering::Relaxed);
        self.active_bit_perfect_depth
            .store(selected.bit_perfect_depth, Ordering::Relaxed);
        *self.stream.lock().unwrap() = Some(stream);
        *self.control.lock().unwrap() = Some(control);
        Ok(())
    }

    pub fn load_track(&self, request: LoadRequest) -> Result<TrackInfoRec, EngineError> {
        self.output_paused.store(false, Ordering::Release);
        let info = self.load_track_paused(request)?;
        #[cfg(target_os = "ios")]
        self.play()?;
        Ok(info)
    }

    /// Loads without releasing the transport mute. The session owner commits
    /// playback with play() only after checking that this is still its selection.
    pub fn load_track_paused(&self, request: LoadRequest) -> Result<TrackInfoRec, EngineError> {
        let (reply_tx, reply_rx) = crossbeam_channel::bounded::<Result<TrackInfo, String>>(1);
        self.send(Command::Load {
            request: to_track_source(request),
            reply: reply_tx,
        })?;
        match reply_rx.recv_timeout(std::time::Duration::from_secs(30)) {
            Ok(Ok(info)) => Ok(info_to_rec(info)),
            Ok(Err(e)) => Err(EngineError::LoadFailed(e)),
            Err(_) => Err(EngineError::LoadFailed("load timed out".into())),
        }
    }

    /// Probes a source before playback so the platform can request its DAC
    /// clock before the first audible buffer. No decoded audio is retained.
    pub fn probe_audio_source(
        &self,
        source: String,
        headers: Option<std::collections::HashMap<String, String>>,
    ) -> Result<AudioSourceFormatRec, EngineError> {
        let kind = crate::decode::SourceKind::parse(&source);
        let decoder = crate::decode::SymphoniaDecoder::open(&kind, &headers.unwrap_or_default())
            .map_err(|e| EngineError::LoadFailed(e.to_string()))?;
        let codec = decoder.codec().to_string();
        Ok(AudioSourceFormatRec {
            lossless_pcm: is_lossless_pcm_codec(&codec),
            codec,
            sample_rate: decoder.sample_rate(),
            bit_depth: decoder.bit_depth(),
            channels: decoder.channels() as u32,
        })
    }

    /// Source identity prevents a stale/queued decoder failure from reopening the current track.
    pub fn drain_source_errors(&self) -> Vec<crate::SourceErrorRec> {
        std::mem::take(&mut *self.events.source_errors.lock().unwrap())
    }

    /// Decode a quarter-second window before trusting provider format claims.
    pub fn verify_audio_source(
        &self,
        source: String,
        headers: Option<std::collections::HashMap<String, String>>,
    ) -> Result<VerifiedAudioSourceRec, EngineError> {
        let kind = crate::decode::SourceKind::parse(&source);
        let mut decoder =
            crate::decode::SymphoniaDecoder::open_available(&kind, &headers.unwrap_or_default())
                .map_err(|e| EngineError::LoadFailed(e.to_string()))?;
        let samples = decoder
            .read_stereo((decoder.sample_rate() / 4).max(1) as usize)
            .map_err(|e| EngineError::LoadFailed(e.to_string()))?;
        if samples.is_empty() {
            return Err(EngineError::LoadFailed("No decodable audio frames".into()));
        }
        let codec = decoder.codec().to_string();
        Ok(VerifiedAudioSourceRec {
            estimated_kbps: decoder.estimated_kbps(),
            format: AudioSourceFormatRec {
                lossless_pcm: is_lossless_pcm_codec(&codec),
                codec,
                sample_rate: decoder.sample_rate(),
                bit_depth: decoder.bit_depth(),
                channels: decoder.channels() as u32,
            },
        })
    }

    /// Opts in to the macOS exclusive integer-output path. It becomes active
    /// only after `prepare_track_output` verifies the actual track and route.
    pub fn set_bit_perfect_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.bit_perfect_enabled.store(enabled, Ordering::Relaxed);
        if enabled {
            *self.bit_perfect_reason.lock().unwrap() =
                "Waiting for a supported lossless stereo track".into();
            return Ok(());
        }
        self.bit_perfect_depth.store(0, Ordering::Relaxed);
        self.active_bit_perfect_depth.store(0, Ordering::Relaxed);
        *self.bit_perfect_reason.lock().unwrap() = "Bit-perfect output is off".into();
        release_output_exclusive();
        self.send(Command::SetBitPerfect(false))?;
        if let Some(control) = self.control.lock().unwrap().clone() {
            control.request_rebuild(true);
        }
        Ok(())
    }

    /// Selects the per-track DAC clock and, when requested and supported,
    /// opens the source-depth integer stream before the mixer loads that track.
    pub fn prepare_track_output(
        &self,
        source_rate: u32,
        source_channels: u32,
        source_bit_depth: u32,
        codec: String,
        lossless_pcm: bool,
        match_source_rate: bool,
        session_rate: Option<f64>,
        session_channels: Option<u32>,
    ) -> Result<(), EngineError> {
        let control = self
            .control
            .lock()
            .unwrap()
            .clone()
            .ok_or(EngineError::NotStarted)?;
        let session_rate = session_rate
            .filter(|rate| rate.is_finite() && *rate > 0.0)
            .map(|rate| rate.round() as u32)
            .unwrap_or(0);
        let session_channels = session_channels
            .filter(|channels| *channels > 0)
            .unwrap_or(2);
        let target_rate = if cfg!(target_os = "macos") {
            if match_source_rate {
                source_rate
            } else {
                self.output_rate.load(Ordering::Relaxed)
            }
        } else if session_rate > 0 {
            session_rate
        } else {
            self.output_rate.load(Ordering::Relaxed)
        };
        let target_channels = if cfg!(target_os = "macos") {
            2
        } else {
            session_channels
        };
        let requested = self.bit_perfect_enabled.load(Ordering::Relaxed);
        let eligible = requested
            && cfg!(target_os = "macos")
            && match_source_rate
            && lossless_pcm
            && is_lossless_pcm_codec(&codec)
            && matches!(source_bit_depth, 16 | 24)
            && source_channels == 2
            && source_rate > 0
            && target_rate == source_rate;
        let _hold = OutputHold::new(&self.output_holds);
        self.send(Command::SetBitPerfect(false))?;
        self.bit_perfect_depth.store(0, Ordering::Relaxed);
        self.active_bit_perfect_depth.store(0, Ordering::Relaxed);
        self.requested_rate.store(target_rate, Ordering::Relaxed);
        self.requested_channels
            .store(target_channels, Ordering::Relaxed);

        let mut bit_perfect_reason = if !requested {
            "Bit-perfect output is off".to_string()
        } else if !cfg!(target_os = "macos") {
            "This iOS audio route only exposes the system float output path".to_string()
        } else if !lossless_pcm || !is_lossless_pcm_codec(&codec) {
            "The source is lossy or has no exact integer PCM representation".to_string()
        } else if source_channels != 2 {
            "Bit-perfect output currently requires a stereo source".to_string()
        } else if !matches!(source_bit_depth, 16 | 24) {
            "Bit-perfect output supports 16-bit and 24-bit integer PCM".to_string()
        } else if !match_source_rate || target_rate != source_rate {
            "Enable source sample-rate matching to use bit-perfect output".to_string()
        } else {
            "The output device did not grant exclusive access".to_string()
        };

        let mut try_bit_perfect = false;
        if eligible {
            let device = self.device_name.lock().unwrap().clone();
            match acquire_output_exclusive(&device) {
                Ok(()) => {
                    self.bit_perfect_depth
                        .store(source_bit_depth, Ordering::Relaxed);
                    try_bit_perfect = true;
                    bit_perfect_reason.clear();
                }
                Err(error) => {
                    bit_perfect_reason = format!("Exclusive output unavailable: {error}");
                    release_output_exclusive();
                }
            }
        } else {
            release_output_exclusive();
        }

        let result = control.rebuild(true);
        if result.is_err() && try_bit_perfect {
            // A route can advertise a rate yet reject the requested integer
            // client format. Reopen the ordinary stream and keep playback.
            self.bit_perfect_depth.store(0, Ordering::Relaxed);
            release_output_exclusive();
            bit_perfect_reason = "The route rejected the source-depth integer format".into();
            let _ = control.rebuild(true);
        } else if let Err(error) = result {
            return Err(error);
        }

        let active_depth = self.active_bit_perfect_depth.load(Ordering::Relaxed);
        if try_bit_perfect && active_depth != source_bit_depth {
            bit_perfect_reason = "The route could not open the exact source format".into();
            release_output_exclusive();
        }
        let active = try_bit_perfect && active_depth == source_bit_depth;
        *self.bit_perfect_reason.lock().unwrap() = if active {
            "Exclusive integer PCM; DSP and system mixing bypassed".into()
        } else {
            bit_perfect_reason
        };
        self.send(Command::SetBitPerfect(active))?;
        Ok(())
    }

    /// Replaces the playing source with a better one for the same recording,
    /// crossfading into it — upstream `swapCurrentToVersion`. The replacement
    /// opens at the engine's own position rather than `request.start_seconds`:
    /// the caller only knows the audible playhead, which trails the decoder by
    /// the whole output ring, and a crossfade between two copies of the same
    /// audio is only inaudible while they are aligned.
    pub fn swap_source(
        &self,
        request: LoadRequest,
        crossfade_seconds: f64,
    ) -> Result<TrackInfoRec, EngineError> {
        let (reply_tx, reply_rx) = crossbeam_channel::bounded::<Result<TrackInfo, String>>(1);
        self.send(Command::SwapSource {
            request: to_track_source(request),
            crossfade_seconds,
            reply: reply_tx,
        })?;
        match reply_rx.recv_timeout(std::time::Duration::from_secs(30)) {
            Ok(Ok(info)) => Ok(info_to_rec(info)),
            Ok(Err(e)) => Err(EngineError::LoadFailed(e)),
            Err(_) => Err(EngineError::LoadFailed("swap timed out".into())),
        }
    }

    /// Compare on the mixer thread, where automatic handoffs also occur.
    pub fn swap_source_if_current(
        &self,
        request: LoadRequest,
        crossfade_seconds: f64,
        expected_source: String,
    ) -> Result<TrackInfoRec, EngineError> {
        let (reply, result) = crossbeam_channel::bounded(1);
        self.send(Command::ForSource {
            source: expected_source,
            command: Box::new(Command::SwapSource {
                request: to_track_source(request),
                crossfade_seconds,
                reply,
            }),
        })?;
        match result.recv_timeout(std::time::Duration::from_secs(30)) {
            Ok(Ok(info)) => Ok(info_to_rec(info)),
            Ok(Err(error)) => Err(EngineError::LoadFailed(error)),
            Err(_) => Err(EngineError::LoadFailed("swap timed out".into())),
        }
    }

    pub fn queue_next_if_current(
        &self,
        request: LoadRequest,
        expected_source: String,
    ) -> Result<(), EngineError> {
        self.send(Command::ForSource {
            source: expected_source,
            command: Box::new(Command::QueueNext {
                request: to_track_source(request),
            }),
        })
    }

    /// What a manual Next would promote: the pending request first, else the
    /// incoming voice of a running blend. `None` when nothing is armed (or
    /// the engine is not running) — the caller falls back to a full load.
    /// Read-only and fast: no decoding, no network.
    pub fn pending_track(&self) -> Option<QueuedTrackRec> {
        let (reply, result) = crossbeam_channel::bounded(1);
        if self.send(Command::PendingTrack { reply }).is_err() {
            return None;
        }
        match result.recv_timeout(std::time::Duration::from_secs(5)) {
            Ok(queued) => queued.map(|track| QueuedTrackRec {
                title: track.title,
                artist: track.artist,
                source: track.source,
            }),
            Err(_) => None,
        }
    }

    /// Skip to the armed successor now, using a short AutoMix mix when enabled
    /// and a trusted beat grid is available. Returns the target's info so the
    /// app can flip its queue index without waiting for the handoff event.
    pub fn skip_to_pending(&self) -> Result<TrackInfoRec, EngineError> {
        let (reply, result) = crossbeam_channel::bounded(1);
        self.send(Command::SkipToPending {
            skip_mix_enabled: self.skip_mix_enabled.load(Ordering::Acquire),
            reply,
        })?;
        match result.recv_timeout(std::time::Duration::from_secs(30)) {
            Ok(Ok(info)) => Ok(info_to_rec(info)),
            Ok(Err(error)) => Err(EngineError::LoadFailed(error)),
            Err(_) => Err(EngineError::LoadFailed("skip timed out".into())),
        }
    }

    pub fn next_energy_dip(&self, source: String, position_seconds: f64) -> Option<f64> {
        crate::analyzer::next_energy_dip(&source, position_seconds)
    }

    pub fn queue_next(&self, request: LoadRequest) -> Result<(), EngineError> {
        self.send(Command::QueueNext {
            request: to_track_source(request),
        })
    }

    pub fn play(&self) -> Result<(), EngineError> {
        #[cfg(target_os = "ios")]
        self.set_ios_output_running(true)?;
        #[cfg(not(target_os = "ios"))]
        self.output_paused.store(false, Ordering::Release);
        self.send(Command::Play)
    }

    pub fn pause(&self) -> Result<(), EngineError> {
        self.output_paused.store(true, Ordering::Release);
        self.send(Command::Pause)?;
        #[cfg(target_os = "ios")]
        self.set_ios_output_running(false)?;
        Ok(())
    }

    pub fn stop(&self) -> Result<(), EngineError> {
        #[cfg(target_os = "ios")]
        self.output_paused.store(true, Ordering::Release);
        self.bail_flush.store(true, Ordering::Release);
        self.send(Command::Stop)?;
        #[cfg(target_os = "ios")]
        self.set_ios_output_running(false)?;
        Ok(())
    }

    /// Moves the playhead. Returns as soon as the request is queued.
    ///
    /// It does not wait for the mixer to apply it, and deliberately so. This is
    /// called straight from a lyric-line tap on the main thread, and waiting
    /// there put a user-interactive thread behind a default-QoS mixer for up to
    /// fifteen seconds — Thread Performance Checker named it, and the UI stall it
    /// caused was the "navigating stutters the song" half of the report. Every
    /// player upstream is asynchronous here too. A refusal comes back as an
    /// error event; the position readout reconciles from the playhead on the
    /// next tick either way.
    pub fn seek(&self, seconds: f64) {
        if self
            .send(Command::Seek {
                seconds: seconds.max(0.0),
            })
            .is_err()
        {
            log::warn!("seek dropped — engine not started");
        }
    }

    /// What the output is, for the audio pipeline panel. Reports `started:
    /// false` before the first stream is built rather than inventing a device.
    pub fn output_device(&self) -> OutputDeviceRec {
        let bit_perfect_depth = self.active_bit_perfect_depth.load(Ordering::Relaxed);
        let format = if bit_perfect_depth == 16 {
            "PCM_16"
        } else if bit_perfect_depth == 24 {
            "PCM_24"
        } else if self.active_pcm_mode.load(Ordering::Relaxed) == 0 {
            "PCM_16"
        } else {
            "FLOAT_32"
        };
        OutputDeviceRec {
            name: self.device_name.lock().unwrap().clone(),
            sample_rate: self.output_rate.load(Ordering::Relaxed),
            channels: self.output_channels.load(Ordering::Relaxed),
            started: self.started.load(Ordering::Relaxed)
                && self.output_rate.load(Ordering::Relaxed) > 0,
            sample_format: format.to_string(),
            bit_perfect_active: bit_perfect_depth > 0
                && f32::from_bits(self.sleep_gain_bits.load(Ordering::Relaxed)) == 1.0,
            bit_perfect_reason: self.bit_perfect_reason.lock().unwrap().clone(),
        }
    }

    pub fn output_health(&self) -> OutputHealthRec {
        OutputHealthRec {
            buffered_frames: self.buffered_frames.load(Ordering::Relaxed),
            callback_underruns: self.callback_underruns.load(Ordering::Relaxed),
            output_rebuilds: self.output_rebuilds.load(Ordering::Relaxed),
            output_xruns: self.output_xruns.load(Ordering::Relaxed),
            output_peak: f32::from_bits(self.output_peak.load(Ordering::Relaxed)),
        }
    }

    /// Re-opens the output stream on whatever route is current now.
    ///
    /// The app calls this after a route change or an interruption, because it
    /// owns the `AVAudioSession` and is the only side that can re-activate it:
    /// a RemoteIO unit built while the session is down is never pulled by the
    /// audio daemon, which looks exactly like a mixer with nothing to say.
    /// `force` skips the reuse check — see `on_stream_error` for why a route
    /// change can never be detected by that check on iOS.
    pub fn request_output_rebuild(&self, force: bool) -> Result<(), EngineError> {
        let control = self.control.lock().unwrap().clone();
        match control {
            Some(control) => {
                control.request_rebuild(force);
                Ok(())
            }
            None => Err(EngineError::NotStarted),
        }
    }

    pub fn position_seconds(&self) -> f64 {
        self.position_ms.load(Ordering::Relaxed) as f64 / 1000.0
    }

    pub fn duration_seconds(&self) -> f64 {
        self.duration_ms.load(Ordering::Relaxed) as f64 / 1000.0
    }

    pub fn set_playback_regions(
        &self,
        source: String,
        regions: PlaybackRegions,
    ) -> Result<(), EngineError> {
        crate::playback_regions::put(source.clone(), regions.clone());
        self.send(Command::SetPlaybackRegions { source, regions })
    }
    pub fn set_sleep_gain(&self, gain: f32) -> Result<(), EngineError> {
        let gain = if gain.is_finite() {
            gain.clamp(0.0, 1.0)
        } else {
            1.0
        };
        self.sleep_gain_bits
            .store(gain.to_bits(), Ordering::Relaxed);
        let volume = f32::from_bits(self.user_volume_bits.load(Ordering::Relaxed));
        self.volume_bits
            .store((volume * gain).to_bits(), Ordering::Relaxed);
        self.send(Command::SetSleepGain(gain))
    }
    pub fn application_output_gain(&self) -> f32 {
        f32::from_bits(self.volume_bits.load(Ordering::Relaxed))
    }
    pub fn hold_track_end(&self, hold: bool) -> Result<(), EngineError> {
        self.send(Command::HoldTrackEnd(hold))
    }

    pub fn set_volume(&self, gain: f32) {
        let gain = if gain.is_finite() {
            gain.clamp(0.0, 1.0)
        } else {
            1.0
        };
        self.user_volume_bits
            .store(gain.to_bits(), Ordering::Relaxed);
        let sleep_gain = f32::from_bits(self.sleep_gain_bits.load(Ordering::Relaxed));
        self.volume_bits
            .store((gain * sleep_gain).to_bits(), Ordering::Relaxed);
        let _ = self.commands.send(Command::SetVolume(gain.clamp(0.0, 1.0)));
    }

    pub fn set_crossfade_window(&self, seconds: f64) -> Result<(), EngineError> {
        self.send(Command::SetCrossfadeWindow(seconds))
    }

    /// Release only Automix-owned processing; retain the listener's speed.
    pub fn cancel_automix_processing(&self) -> Result<(), EngineError> {
        self.send(Command::CancelAutomixProcessing)
    }

    pub fn set_spatial_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.send(Command::SetSpatial(enabled))
    }

    /// Head yaw, normalized −1..1 (iOS `HeadTracker` feeds this; macOS passes 0).
    pub fn set_head_rotation(&self, yaw: f32) -> Result<(), EngineError> {
        self.send(Command::SetHeadYaw(yaw))
    }

    pub fn set_voice_filter(
        &self,
        incoming: bool,
        low_hz: f32,
        high_hz: f32,
    ) -> Result<(), EngineError> {
        self.send(Command::SetVoiceFilter {
            incoming,
            low_hz,
            high_hz,
        })
    }

    pub fn open_transition_filters(&self) -> Result<(), EngineError> {
        self.send(Command::OpenFilters)
    }

    pub fn set_playback_speed(&self, speed: f32) -> Result<(), EngineError> {
        self.send(Command::SetPlaybackSpeed(if speed.is_finite() {
            speed.clamp(0.5, 2.0)
        } else {
            1.0
        }))
    }

    pub fn set_skip_silence(&self, enabled: bool) -> Result<(), EngineError> {
        self.send(Command::SetSkipSilence(enabled))
    }

    /// Sets the equaliser tuning (upstream `EqualizerProcessor.setTuning`).
    ///
    /// `gains_db` and `qs` are the ten-slot [`crate::eq::EqLayout`] values —
    /// slots 0..6 the manual tab (low shelf at 60 Hz, high shelf at 14 kHz,
    /// bells between), slots 7..9 the tone pad (250 Hz shelf, 1 kHz bell,
    /// 4 kHz shelf). The make-up preamp is computed here, once, from the
    /// summed response so the audio thread never walks it. `balance` is the
    /// −1..1 output trim (ignored for mono). `enabled = false` is a flat curve
    /// and centred balance — it glides down rather than cutting out.
    pub fn set_eq_tuning(
        &self,
        enabled: bool,
        gains_db: Vec<f32>,
        qs: Vec<f32>,
        balance: f32,
    ) -> Result<(), EngineError> {
        let curve = crate::eq::EqCurve::of(&gains_db, &qs);
        self.send(Command::SetEqTuning {
            enabled,
            gains_db: curve.gains_db,
            qs: curve.qs,
            preamp_db: curve.preamp_db,
            balance,
        })
    }

    /// Requested PCM word length (`PCM_16` / `FLOAT_32`; a stored `PCM_24`
    /// from before the rung was removed maps to the lossless path). The unit
    /// is rebuilt when the answer differs — same rebuild a route change gets,
    /// so a toggle mid-track never cuts the blend.
    pub fn set_output_pcm_mode(&self, mode: String) -> Result<(), EngineError> {
        let parsed = OutputPcmMode::parse(&mode);
        let code = match parsed {
            OutputPcmMode::Pcm16 => 0,
            OutputPcmMode::Float32 => 1,
        };
        if self.pcm_mode.swap(code, Ordering::Relaxed) == code {
            return Ok(());
        }
        log::info!("output PCM mode -> {}", parsed.label());
        if let Some(control) = self.control.lock().unwrap().clone() {
            control.request_rebuild(true);
        }
        Ok(())
    }

    /// Prefer a USB DAC over the system default. Takes effect through the
    /// same rebuild path: the next device pick prefers the USB match, and the
    /// name check forces the swap even at an identical format.
    pub fn set_prefer_usb_dac(&self, enabled: bool) -> Result<(), EngineError> {
        if self.prefer_usb.swap(enabled, Ordering::Relaxed) == enabled {
            return Ok(());
        }
        if let Some(control) = self.control.lock().unwrap().clone() {
            control.request_rebuild(false);
        }
        Ok(())
    }

    /// Loudness-normalization master switch. No reload: the render reads the
    /// flag per chunk and the readout follows it.
    /// Captures at most 30 seconds per stage to the caller's local directory.
    pub fn start_diagnostic_capture(
        &self,
        directory: String,
        seconds: f64,
    ) -> Result<(), EngineError> {
        self.send(Command::StartDiagnosticCapture { directory, seconds })
    }
    pub fn finish_diagnostic_capture(&self) -> Result<(), EngineError> {
        let (reply, response) = crossbeam_channel::bounded(1);
        self.send(Command::FinishDiagnosticCapture { reply: Some(reply) })?;
        response
            .recv_timeout(std::time::Duration::from_secs(30))
            .map_err(|_| {
                EngineError::LoadFailed("Diagnostic capture did not finish in time".into())
            })?
            .map_err(|message| EngineError::LoadFailed(message))
    }
    /// Complete-recording EBU R128 / BS.1770 measurement. Call off the UI thread.
    pub fn measure_loudness(&self, source: String) -> Result<LoudnessMeasurement, EngineError> {
        crate::loudness::measure(&source).map_err(EngineError::LoadFailed)
    }
    /// Applies identified measurement data only to the source that was measured.
    pub fn set_loudness_measurement(
        &self,
        source: String,
        measurement: LoudnessMeasurement,
    ) -> Result<(), EngineError> {
        self.send(Command::ForSource {
            source,
            command: Box::new(Command::SetLoudnessMeasurement(measurement)),
        })
    }
    pub fn set_sound_mode(&self, mode: SoundMode) -> Result<(), EngineError> {
        self.send(Command::SetSoundMode(mode))
    }
    pub fn set_clarity_tuning(&self, tuning: ClarityTuning) -> Result<(), EngineError> {
        self.send(Command::SetClarityTuning(tuning))
    }
    pub fn set_loudness_mode(&self, mode: LoudnessMode) -> Result<(), EngineError> {
        self.loudness_enabled
            .store(mode != LoudnessMode::Off, Ordering::Relaxed);
        self.send(Command::SetLoudnessMode(mode))
    }

    pub fn set_loudness_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.loudness_enabled.store(enabled, Ordering::Relaxed);
        self.send(Command::SetLoudnessEnabled(enabled))
    }

    /// Automix analysis tier (`EFFICIENT` / `BALANCED` / `PERFORMANCE`). Read
    /// when a plan is computed; EFFICIENT skips the vocal model.
    pub fn set_automix_performance(&self, mode: String) {
        *self.automix_tier.lock().unwrap() = AutomixTier::parse(&mode);
    }

    /// Set the fixed effect phrase length (0 = adaptive, 8 or 16 bars).
    pub fn set_automix_phrase_bars(&self, bars: u32) {
        *self.automix_phrase_bars.lock().unwrap() =
            if matches!(bars, 8 | 16) { bars } else { 0 };
    }

    /// Opening a replacement is not acceptance: the mixer decides after rendering the fade.
    /// None means this target has not completed a swap; a rejection keeps the original voice.
    pub fn source_swap_outcome(&self, source: String) -> Option<bool> {
        self.nerd.lock().ok().and_then(|snap| {
            if snap.swap_target == source {
                snap.swap_accepted
            } else {
                None
            }
        })
    }

    pub fn nerd_stats(&self) -> NerdStatsRec {
        let snap = self.nerd.lock().unwrap().clone();
        NerdStatsRec {
            codec: snap.codec,
            sample_rate: snap.sample_rate,
            bit_depth: snap.bit_depth,
            channels: snap.channels,
            kbps: snap.kbps,
            loudness_gain_db: snap.loudness_gain_db,
            transition_match_db: snap.transition_match_db,
            swap_correlation: snap.swap_correlation,
            active_stages: snap.active_stages,
            converter_delay_frames: snap.converter_delay_frames,
            protection_reduction_db: snap.protection_reduction_db,
            protection_interventions: snap.protection_interventions,
            build_revision: snap.build_revision,
            decoder_implementation: snap.decoder_implementation,
            decoded_layout: snap.decoded_layout,
            queued_target_ms: snap.queued_target_ms,
            loudness_origin: snap.loudness_origin,
        }
    }

    // ---- Analysis entry points (spec §2, §1.3) -----------------------------

    /// Seek-bounded region decode — the contract upstream's `AudioDecoder`
    /// documents and `TrackAnalyzer` depends on: float PCM + sample rate +
    /// effective start, mono or stereo variant, null on failure.
    pub fn decode_region(
        &self,
        source: String,
        start_seconds: f64,
        duration_seconds: f64,
        mono: bool,
    ) -> Option<DecodedRegion> {
        decode_region_impl(&source, start_seconds, duration_seconds, mono).ok()
    }

    /// Analysis decode using the same request headers as playback. The caller
    /// runs this off the render and UI threads; `open_available` deliberately
    /// returns the bytes that have arrived so far for growing stream files.
    pub fn decode_region_with_headers(
        &self,
        source: String,
        start_seconds: f64,
        duration_seconds: f64,
        mono: bool,
        headers: std::collections::HashMap<String, String>,
    ) -> Option<DecodedRegion> {
        decode_region_impl_with_headers(&source, start_seconds, duration_seconds, mono, &headers)
            .ok()
    }

    /// Mono region as little-endian f32 bytes, resampled down to
    /// `target_rate` when given. Bytes cross the bridge in one copy.
    pub fn decode_region_pcm(
        &self,
        source: String,
        start_seconds: f64,
        duration_seconds: f64,
        headers: std::collections::HashMap<String, String>,
        target_rate: Option<u32>,
    ) -> Option<crate::records::DecodedPcm> {
        crate::api::decode_region_pcm_impl(&source, start_seconds, duration_seconds, &headers, target_rate)
            .ok()
    }

    /// Decode a track once, start to end, into a 16-bit mono WAV at `dest`
    /// for the system analysis frameworks. False (and no file) on failure.
    pub fn write_analysis_wav(
        &self,
        source: String,
        dest: String,
        headers: std::collections::HashMap<String, String>,
        max_seconds: f64,
        target_rate: Option<u32>,
    ) -> bool {
        match crate::api::write_analysis_wav_impl(&source, &dest, &headers, max_seconds, target_rate) {
            Ok(()) => true,
            Err(error) => {
                log::warn!("analysis wav failed: {error}");
                false
            }
        }
    }

    /// `ComputeBeatSpectrogram` over pre-resampled 22.05 kHz input.
    pub fn mel_spectrogram(&self, samples: Vec<f32>, sample_rate: f64) -> MelSpectrogramResult {
        let BeatSpectrogram { frames, values } =
            crate::analyzer::compute_beat_spectrogram(&samples, sample_rate);
        MelSpectrogramResult {
            frames: frames as u64,
            mels: crate::analyzer::BEAT_SPECTROGRAM_MELS as u64,
            values,
        }
    }

    /// Offline `Resample()` port (analysis path; playback resamples inline).
    pub fn resample_audio(&self, samples: Vec<f32>, input_rate: f64, output_rate: f64) -> Vec<f32> {
        crate::analyzer::resample(&samples, input_rate, output_rate)
    }

    /// True once Beat This! loaded. Energy-based tempo planning still works
    /// without it — Automix falls back to a plain fade, matching upstream.
    pub fn analyzer_available(&self) -> bool {
        crate::analyzer::analyzer_ready()
    }

    /// Plan an Automix transition from two audio sources (Beat This! +
    /// open-unmix when models are configured, energy/tempo otherwise).
    /// Duration and request-header hints let the planner analyze remote streams
    /// with the same context as playback instead of degrading them to a plain
    /// crossfade because local tag probing cannot inspect a URL.
    pub fn plan_automix(
        &self,
        outgoing_path: String,
        incoming_path: String,
        outgoing_text: String,
        incoming_text: String,
        album_sequential: bool,
        crossfade_seconds: f64,
        outgoing_duration_seconds: f64,
        incoming_duration_seconds: f64,
        outgoing_headers: Option<std::collections::HashMap<String, String>>,
        incoming_headers: Option<std::collections::HashMap<String, String>>,
        allow_effects: bool,
    ) -> TransitionPlanRec {
        let tier = *self.automix_tier.lock().unwrap();
        let phrase_bars = *self.automix_phrase_bars.lock().unwrap();
        let outgoing_headers = outgoing_headers.unwrap_or_default();
        let incoming_headers = incoming_headers.unwrap_or_default();
        plan_automix_impl_with_tier_and_phrase_bars(
            &outgoing_path,
            &incoming_path,
            &outgoing_text,
            &incoming_text,
            album_sequential,
            crossfade_seconds,
            outgoing_duration_seconds,
            incoming_duration_seconds,
            &outgoing_headers,
            &incoming_headers,
            tier,
            allow_effects,
            phrase_bars,
        )
    }
}

impl Drop for PlayerEngine {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        // The stream's error callback owns an OutputControl which owns the
        // stream cell. Take the stream out to break that cycle. Never dispose
        // CoreAudio under the cell lock: callbacks may still be winding down.
        let stream = self.stream.lock().unwrap_or_else(|p| p.into_inner()).take();
        drop(stream);
        // The mixer observes shutdown even while idle. It releases its voices,
        // event callback and ring on exit; joining here could deadlock if the
        // host released its last engine reference from a mixer callback.
    }
}

#[cfg(test)]
mod tests {
    use super::PlayerEngine;

    #[test]
    fn releasing_engine_stops_idle_mixer_and_releases_its_events() {
        use std::sync::{Arc, atomic::Ordering};
        let engine = PlayerEngine::new();
        let events = Arc::downgrade(&engine.events);
        let shutdown = engine.shutdown.clone();
        let (producer, _consumer) = rtrb::RingBuffer::new(8192);
        let rx = engine.command_rx.lock().unwrap().take().unwrap();
        let args = (engine.buffered_frames.clone(), engine.position_ms.clone(), engine.duration_ms.clone(),
            engine.events.clone(), engine.shutdown.clone(), engine.flush_ring.clone(), engine.bail_flush.clone(), engine.nerd.clone());
        let (sent, received) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            crate::mixer::run_mixer(rx, producer, args.0, args.1, args.2, 48000, args.3, args.4, args.5, args.6, args.7);
            sent.send(()).unwrap();
        });
        drop(engine);
        let stopped = received.recv_timeout(std::time::Duration::from_secs(2)).is_ok();
        shutdown.store(true, Ordering::Release); // Also clean up after a regression.
        worker.join().unwrap();
        assert!(stopped, "dropping the engine left its mixer running");
        assert!(events.upgrade().is_none(), "mixer retained its event callback cell");
    }

    #[test]
    fn phrase_bars_setting_accepts_supported_values_and_defaults_invalid_to_adaptive() {
        let engine = PlayerEngine::new();
        assert_eq!(*engine.automix_phrase_bars.lock().unwrap(), 0);
        engine.set_automix_phrase_bars(8);
        assert_eq!(*engine.automix_phrase_bars.lock().unwrap(), 8);
        engine.set_automix_phrase_bars(16);
        assert_eq!(*engine.automix_phrase_bars.lock().unwrap(), 16);
        engine.set_automix_phrase_bars(12);
        assert_eq!(*engine.automix_phrase_bars.lock().unwrap(), 0);
    }
}

impl PlayerEngine {
    /// On iOS a running RemoteIO unit is still active audio playback even when
    /// its callback writes zeroes. Stop rendering on Pause while retaining the
    /// AVAudioSession and decoded ring; Resume starts that same unit again.
    #[cfg(target_os = "ios")]
    pub(super) fn set_ios_output_running(&self, running: bool) -> Result<(), EngineError> {
        let output = self.stream.lock().unwrap();
        let stream = output.as_ref().ok_or(EngineError::NotStarted)?;
        let result = if running {
            stream.play()
        } else {
            stream.pause()
        };
        result.map_err(|e| EngineError::StreamInit(e.to_string()))?;
        // Publish the transport flag before releasing the stream lock so a
        // simultaneous rebuild cannot install a paused unit after Resume.
        self.output_paused.store(!running, Ordering::Release);
        log::info!(
            "iOS output rendering {}",
            if running { "started" } else { "paused" }
        );
        Ok(())
    }

    pub(super) fn send(&self, cmd: Command) -> Result<(), EngineError> {
        self.commands.send(cmd).map_err(|_| EngineError::NotStarted)
    }
}
