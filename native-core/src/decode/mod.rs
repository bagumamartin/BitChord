//! Decode (spec §3.1): symphonia-based decode pipeline and the streaming
//! `MediaSource` reader.
//!
//! Two source shapes: a local file (plain path — security-scoped bookmarks are
//! resolved by the Swift layer before reaching here) and an HTTP URL. The
//! HTTP path is `HttpMediaSource`: a background fetch thread pulls bounded
//! 1 MiB ranges (upstream `ChunkedDataSource` — unbounded googlevideo reads
//! are throttled to playback speed). A path that still has a sibling `.grow`
//! marker is a `GrowingFile`: Ktor is appending the rest of the track, and
//! reads wait at EOF until `.complete` appears. symphonia only requires a
//! `MediaSource`, so the same decoder drives both.
//!
//! Symphonia 0.6.1 has no bundled Opus decoder, so the one missing codec is
//! supplied by the libopus adapter. This lets configured sources serve WebM and
//! Ogg Opus directly instead of forcing an AAC fallback.

#[cfg(target_vendor = "apple")]
mod apple_aac;
mod codec;
mod growing_file;
mod http_source;
mod opus;
mod pcm;
pub mod resampler;

#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::fs::File;

use symphonia::core::audio::Channels;
use symphonia::core::codecs::audio::well_known::{CODEC_ID_AAC, CODEC_ID_MP3, CODEC_ID_OPUS};
use symphonia::core::codecs::audio::AudioDecoder;
use symphonia::core::codecs::CodecParameters;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::Time;

use codec::{alac_bit_depth, codec_label, container_duration_secs, open_audio_decoder};
use growing_file::GrowingFile;
use http_source::HttpMediaSource;
use pcm::{copy_interleaved_f32, downmix_stereo};

/// Where a track's bytes come from. `Path` is used verbatim; `Url` goes
/// through [`HttpMediaSource`].
#[derive(Debug, Clone)]
pub enum SourceKind {
    Path(String),
    Url(String),
}

impl SourceKind {
    pub fn parse(source: &str) -> SourceKind {
        if source.starts_with("http://") || source.starts_with("https://") {
            SourceKind::Url(source.to_string())
        } else {
            SourceKind::Path(source.to_string())
        }
    }
}

/// Fully decoded stream state for one track.
pub struct SymphoniaDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    sample_rate: u32,
    channels: usize,
    expected_layout: Channels,
    duration_secs: Option<f64>,
    decoded_frames: u64,
    measured_packet_bytes: u64,
    measured_packet_frames: u64,
    seek_skip_frames: usize,
    decoder_eof_drained: bool,
    sanitized_samples: u64,
    /// Packets dropped since the last one that decoded, and why: each is
    /// audio the listener never hears, so a run of them is reported.
    dropped_packets: u32,
    drop_reason: String,
    drop_at: f64,
    priming_total_frames: usize,
    priming_remaining: usize,
    valid_frames: Option<u64>,
    /// Interleaved stereo f32 left over from the last decoded packet.
    pending: Vec<f32>,
    pending_cursor: usize,
    codec: String,
    bit_depth: u32,
}

#[derive(Debug)]
pub struct DecodeError(pub String);

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for DecodeError {}

impl SymphoniaDecoder {
    pub fn open(
        source: &SourceKind,
        headers: &HashMap<String, String>,
    ) -> Result<Self, DecodeError> {
        Self::open_inner(source, headers, true)
    }

    /// Like [`open`], but a download that is still appending ends at the bytes
    /// on disk. Planning uses this. Playback uses [`open`], which waits, so a
    /// song never stops in the middle of its own download.
    pub fn open_available(
        source: &SourceKind,
        headers: &HashMap<String, String>,
    ) -> Result<Self, DecodeError> {
        Self::open_inner(source, headers, false)
    }

    fn open_inner(
        source: &SourceKind,
        headers: &HashMap<String, String>,
        block_on_growth: bool,
    ) -> Result<Self, DecodeError> {
        let mss: MediaSourceStream = match source {
            SourceKind::Path(path) => {
                let boxed: Box<dyn MediaSource> = if GrowingFile::is_growing(path) {
                    let growing = if block_on_growth {
                        GrowingFile::open(path)
                    } else {
                        GrowingFile::open_mode(path, false)
                    };
                    Box::new(growing.map_err(|e| DecodeError(format!("open {path}: {e}")))?)
                } else {
                    Box::new(
                        File::open(path).map_err(|e| DecodeError(format!("open {path}: {e}")))?,
                    )
                };
                MediaSourceStream::new(boxed, MediaSourceStreamOptions::default())
            }
            SourceKind::Url(url) => {
                let http = HttpMediaSource::open(url, headers)
                    .map_err(|e| DecodeError(format!("open {url}: {e}")))?;
                MediaSourceStream::new(Box::new(http), MediaSourceStreamOptions::default())
            }
        };

        let mut hint = Hint::new();
        if let SourceKind::Path(path) = source {
            if let Some(ext) = std::path::Path::new(path)
                .extension()
                .and_then(|e| e.to_str())
            {
                hint.with_extension(ext);
            }
        }

        let probe = symphonia::default::get_probe();
        let format = probe
            .probe(
                &hint,
                mss,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
            .map_err(|e| DecodeError(format!("probe: {e}")))?;

        let track = format
            .tracks()
            .iter()
            .find(|t| {
                t.codec_params
                    .as_ref()
                    .and_then(|p| p.audio())
                    .is_some_and(|a| a.sample_rate.is_some())
            })
            .or_else(|| format.tracks().first())
            .ok_or_else(|| DecodeError("no audio track".into()))?
            .clone();

        let track_id = track.id;
        let audio_params: CodecParameters = track
            .codec_params
            .clone()
            .ok_or_else(|| DecodeError("no codec params".into()))?;
        let audio = audio_params
            .audio()
            .cloned()
            .ok_or_else(|| DecodeError("track is not audio".into()))?;
        let sample_rate = audio
            .sample_rate
            .ok_or_else(|| DecodeError("no sample rate".into()))?;
        let channels = audio
            .channels
            .as_ref()
            .map(|c| c.count())
            .unwrap_or(2)
            .max(1);
        // ISO-MP4 often has mdhd timescale ≠ sample rate (muxed itag 18), so
        // `num_frames` is left unset. Use the container duration + timebase.
        let duration_secs = match (track.time_base, track.duration) {
            (Some(tb), Some(dur)) => {
                let secs = tb.calc_duration_saturating(dur).as_secs_f64();
                if secs > 0.0 {
                    Some(secs)
                } else {
                    None
                }
            }
            _ => track
                .num_frames
                .filter(|&f| f > 0)
                .map(|f| f as f64 / sample_rate as f64),
        }
        .or_else(|| container_duration_secs(format.media_info()));

        let decoder = open_audio_decoder(&audio)?;
        let sample_rate = decoder.codec_params().sample_rate.unwrap_or(sample_rate);
        let channels = decoder
            .codec_params()
            .channels
            .as_ref()
            .map(|c| c.count())
            .unwrap_or(channels);
        let expected_layout = decoder
            .codec_params()
            .channels
            .clone()
            .ok_or_else(|| DecodeError("missing decoded layout".into()))?;
        let codec = codec_label(&audio);
        let mut timing: Option<(u64, usize)> = None;
        #[cfg(target_vendor = "apple")]
        if audio.codec == symphonia::core::codecs::audio::well_known::CODEC_ID_AAC
            && track.delay.is_none()
            && track.padding.is_none()
        {
            if let SourceKind::Path(path) = source {
                timing = apple_aac::file_timing(path, sample_rate);
            }
        }
        let duration_secs = timing
            .map(|(frames, _)| frames as f64 / sample_rate as f64)
            .or(duration_secs);

        // Only report source bit depth for codecs with a meaningful integer PCM
        // precision. Lossy codecs decode to float, which is not their encoded
        // source depth and must not be presented as one.
        let bit_depth = if matches!(codec.as_str(), "FLAC" | "ALAC" | "PCM" | "PCM Float") {
            audio
                .bits_per_sample
                .filter(|depth| *depth > 0)
                .or_else(|| {
                    decoder
                        .codec_params()
                        .bits_per_sample
                        .filter(|depth| *depth > 0)
                })
                .or_else(|| {
                    (audio.codec == symphonia::core::codecs::audio::well_known::CODEC_ID_ALAC)
                        .then(|| audio.extra_data.as_deref().and_then(alac_bit_depth))
                        .flatten()
                })
                .unwrap_or(0)
        } else {
            0
        };

        let label = match source {
            SourceKind::Path(p) => p.rsplit('/').next().unwrap_or(p),
            SourceKind::Url(_) => "url",
        };
        log::info!(
            "opened {label}: codec={codec} rate={sample_rate} ch={channels} bits={bit_depth} duration={duration_secs:?}s frames={:?}",
            track.num_frames
        );

        Ok(Self {
            format,
            decoder,
            track_id,
            sample_rate,
            channels,
            expected_layout,
            duration_secs,
            decoded_frames: 0,
            measured_packet_bytes: 0,
            measured_packet_frames: 0,
            seek_skip_frames: 0,
            decoder_eof_drained: false,
            sanitized_samples: 0,
            dropped_packets: 0,
            drop_reason: String::new(),
            drop_at: 0.0,
            priming_total_frames: timing.map(|t| t.1).unwrap_or(0),
            priming_remaining: timing.map(|t| t.1).unwrap_or(0),
            valid_frames: timing.map(|t| t.0),
            pending: Vec::new(),
            pending_cursor: 0,
            codec,
            bit_depth,
        })
    }

    /// Packet payload rate over the decoded window; a VBR estimate, not a claim.
    pub fn estimated_kbps(&self) -> Option<u32> {
        (self.measured_packet_frames > 0).then(|| {
            (self.measured_packet_bytes as f64 * 8.0 * self.sample_rate as f64
                / self.measured_packet_frames as f64
                / 1000.0)
                .round() as u32
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    pub fn codec(&self) -> &str {
        &self.codec
    }

    pub fn bit_depth(&self) -> u32 {
        self.bit_depth
    }

    /// Source-domain duration in seconds, when the container declares it.
    pub fn duration_seconds(&self) -> Option<f64> {
        self.duration_secs
    }

    /// Source-domain frames decoded since open/last seek.
    pub fn decoded_frames(&self) -> u64 {
        self.decoded_frames
    }

    /// Source-domain position of the next frame returned to the caller.
    /// A compressed seek keeps decoder preroll pending until the first read,
    /// but those discarded frames must not move the playback position back.
    pub fn position_seconds(&self) -> f64 {
        let pending = (self.pending.len().saturating_sub(self.pending_cursor) / 2) as u64;
        self.decoded_frames
            .saturating_sub(pending)
            .saturating_add(self.seek_skip_frames as u64) as f64
            / self.sample_rate as f64
    }
    pub fn sanitized_samples(&self) -> u64 {
        self.sanitized_samples
    }
    pub fn implementation(&self) -> &str {
        self.decoder.codec_info().long_name
    }
    pub fn layout(&self) -> String {
        format!("{:?}", self.decoder.codec_params().channels)
    }

    /// Seeks to `seconds` in source time. Symphonia reports the actual
    /// timestamp landed on; decoded-frame counting restarts from there.
    pub fn seek_seconds(&mut self, seconds: f64) -> Result<(), DecodeError> {
        // Compressed codecs need preceding packets to restore overlap,
        // prediction and SBR state. Decode the preroll, then discard exactly
        // to the requested source frame; never expose the cold decoder tail.
        let codec = self.decoder.codec_params().codec;
        let preroll = if codec == CODEC_ID_OPUS {
            // RFC 7845 requires at least 80 ms. A longer bounded history also
            // converges SILK prediction on quiet Matroska/WebM material.
            1.0
        } else if codec == CODEC_ID_AAC || codec == CODEC_ID_MP3 {
            0.120
        } else {
            0.0
        };
        let encoded_seconds = (seconds.max(0.0)
            + self.priming_total_frames as f64 / self.sample_rate as f64
            - preroll)
            .max(0.0);
        let time = Time::try_from_secs_f64(encoded_seconds)
            .ok_or_else(|| DecodeError("bad seek time".into()))?;
        let to = SeekTo::Time {
            time,
            track_id: Some(self.track_id),
        };
        match self.format.seek(SeekMode::Accurate, to) {
            Ok(seeked_to) => {
                self.decoder.reset();
                self.decoder_eof_drained = false;
                self.pending.clear();
                self.pending_cursor = 0;
                // Frame counting restarts from where the seek landed. The
                // container's timestamp is the better answer when it has one,
                // but a stream with no real timestamps (raw WAV, ADTS) reports
                // zero there — and trusting that restarts the playhead at the
                // file start while the audio is in the middle of the song. The
                // requested time is the honest fallback.
                let requested = seconds.max(0.0);
                let landed = self
                    .time_base()
                    .map(|tb| tb.calc_time_saturating(seeked_to.actual_ts).as_secs_f64())
                    .filter(|t| t.is_finite() && *t >= 0.0)
                    .unwrap_or(requested);
                let encoded_frames = (landed * self.sample_rate as f64).round() as u64;
                if self.decoder.codec_params().codec == CODEC_ID_OPUS {
                    let params = self
                        .format
                        .tracks()
                        .iter()
                        .find(|t| t.id == self.track_id)
                        .and_then(|t| t.codec_params.as_ref())
                        .and_then(|p| p.audio())
                        .ok_or_else(|| DecodeError("Opus seek lost codec metadata".into()))?;
                    self.decoder = opus::OpusDecoder::open(params, landed == 0.0)?;
                }
                self.priming_remaining = self
                    .priming_total_frames
                    .saturating_sub(encoded_frames as usize);
                self.decoded_frames =
                    encoded_frames.saturating_sub(self.priming_total_frames as u64);
                self.seek_skip_frames = ((requested * self.sample_rate as f64).round() as u64)
                    .saturating_sub(self.decoded_frames)
                    as usize;
                Ok(())
            }
            Err(e) => Err(DecodeError(format!("seek: {e}"))),
        }
    }

    fn time_base(&self) -> Option<symphonia::core::units::TimeBase> {
        self.format
            .tracks()
            .iter()
            .find(|t| t.id == self.track_id)
            .and_then(|t| t.time_base)
    }

    /// Reads up to `max_frames` source-domain frames as interleaved stereo
    /// f32 (mono is upmixed; >2 channels fold onto L/R). Empty slice = EOS.
    pub fn read_stereo(&mut self, max_frames: usize) -> Result<Vec<f32>, DecodeError> {
        let mut out = Vec::with_capacity(max_frames * 2);
        if self.pending_cursor < self.pending.len() {
            let take = (self.pending.len() - self.pending_cursor).min(max_frames * 2);
            out.extend_from_slice(&self.pending[self.pending_cursor..self.pending_cursor + take]);
            self.pending_cursor += take;
        }

        let mut interleaved: Vec<f32> = Vec::new();
        let mut skipped = 0u32;
        while out.len() < max_frames * 2 {
            // A rest point for paced analysis; the render thread is never armed.
            crate::pace::tick();
            if self.valid_frames.is_some_and(|f| self.decoded_frames >= f) {
                break;
            }
            let packet = match self.format.next_packet() {
                Ok(p) => p,
                Err(SymphoniaError::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    None
                }
                Err(e) => {
                    log::debug!("next_packet: {e}");
                    if self.dropped_packets == 0 {
                        self.drop_at = self.position_seconds();
                    }
                    self.dropped_packets += 1;
                    self.drop_reason = format!("demux: {e}");
                    skipped += 1;
                    if skipped > 256 {
                        return Err(DecodeError(format!("demuxing failed: {e}")));
                    }
                    continue;
                }
            };
            let Some(packet) = packet else {
                if !self.decoder_eof_drained && self.implementation() == "Apple AudioToolbox AAC" {
                    self.decoder_eof_drained = true;
                    self.decoder.finalize();
                    let decoded = self.decoder.last_decoded();
                    interleaved.clear();
                    copy_interleaved_f32(&decoded, &mut interleaved);
                    if decoded.spec().rate() != self.sample_rate
                        || decoded.spec().channels() != &self.expected_layout
                    {
                        return Err(DecodeError(
                            "decoded format changed during AAC drain".into(),
                        ));
                    }
                    for s in &mut interleaved {
                        if !s.is_finite() {
                            *s = 0.0;
                            self.sanitized_samples += 1;
                        }
                    }
                    self.pending = downmix_stereo(&interleaved, &self.expected_layout)?;
                    let priming = self.priming_remaining.min(self.pending.len() / 2);
                    self.priming_remaining -= priming;
                    self.pending.drain(..priming * 2);
                    if let Some(valid) = self.valid_frames {
                        self.pending
                            .truncate(valid.saturating_sub(self.decoded_frames) as usize * 2);
                    }
                    self.decoded_frames += (self.pending.len() / 2) as u64;
                    let skip = self.seek_skip_frames.min(self.pending.len() / 2);
                    self.seek_skip_frames -= skip;
                    self.pending.drain(..skip * 2);
                    let take = self.pending.len().min(max_frames * 2 - out.len());
                    out.extend_from_slice(&self.pending[..take]);
                    self.pending_cursor = take;
                }
                break;
            };
            if packet.track_id != self.track_id {
                continue;
            }
            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                Err(SymphoniaError::DecodeError(e)) => {
                    log::debug!("decode error, skipping packet: {e}");
                    if self.dropped_packets == 0 {
                        self.drop_at = self.position_seconds();
                    }
                    self.dropped_packets += 1;
                    self.drop_reason = format!("decode: {e}");
                    continue;
                }
                Err(e) => {
                    return Err(DecodeError(format!("decode: {e}")));
                }
            };

            self.measured_packet_bytes += packet.data.len() as u64;
            self.measured_packet_frames += decoded.frames() as u64;
            if self.dropped_packets > 0 {
                // Debug-level lines never reach the diagnostics file; a jump
                // the listener hears has to.
                log::warn!(
                    "decoder dropped {} packet(s) at {:.2}s ({}); audible as a skip",
                    self.dropped_packets,
                    self.drop_at,
                    self.drop_reason
                );
                self.dropped_packets = 0;
            }
            interleaved.clear();
            copy_interleaved_f32(&decoded, &mut interleaved);
            for s in &mut interleaved {
                if !s.is_finite() {
                    *s = 0.0;
                    self.sanitized_samples += 1;
                }
            }
            let spec = decoded.spec();
            if spec.rate() != self.sample_rate || spec.channels() != &self.expected_layout {
                return Err(DecodeError(format!(
                    "decoded format changed: {} Hz / {:?}, expected {} Hz / {:?}",
                    spec.rate(),
                    spec.channels(),
                    self.sample_rate,
                    self.expected_layout
                )));
            }
            let layout = spec.channels().clone();
            let frames = decoded.frames();

            // Every pending buffer has the same stereo layout as the caller.
            // Keeping raw mono/surround leftovers here changes both channel
            // order and duration on the next read.
            self.pending = downmix_stereo(&interleaved, &layout)?;
            let priming = self.priming_remaining.min(frames);
            self.priming_remaining -= priming;
            self.pending.drain(..priming * 2);
            if let Some(valid) = self.valid_frames {
                self.pending
                    .truncate(valid.saturating_sub(self.decoded_frames) as usize * 2);
            }
            self.decoded_frames += (self.pending.len() / 2) as u64;

            let skip = self.seek_skip_frames.min(self.pending.len() / 2);
            self.seek_skip_frames -= skip;
            self.pending.drain(..skip * 2);
            let take = self.pending.len().min(max_frames * 2 - out.len());
            out.extend_from_slice(&self.pending[..take]);
            self.pending_cursor = take;
        }
        Ok(out)
    }
}
