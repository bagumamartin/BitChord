//! Dump the app's Beat This! log-mel for one audio file.
//!
//! Path-depends on native-core and uses the same decode -> stereo downmix ->
//! StreamResampler(22.05 kHz) -> compute_beat_spectrogram path as the app's
//! plan/analysis.rs.  The output is `u32` frame count then row-major f32
//! `[frames,128]` log-mel, little-endian.
//!
//! usage: mel_dumper <audio> <out.bin>
use std::collections::HashMap;
use std::io::Write;

use native_core::analyzer::{compute_beat_spectrogram, BEAT_SPECTROGRAM_SAMPLE_RATE};
use native_core::decode::resampler::StreamResampler;
use native_core::decode::{SourceKind, SymphoniaDecoder};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: mel_dumper <audio> <out.bin>");
        std::process::exit(2);
    }
    let (input, output) = (&args[1], &args[2]);

    let mut decoder =
        SymphoniaDecoder::open_available(&SourceKind::parse(input), &HashMap::new()).expect("open");
    let rate = decoder.sample_rate();
    let duration = decoder.duration_seconds().unwrap_or(0.0);
    let target = (duration * rate as f64) as usize;

    let mut resampler = StreamResampler::new(rate, BEAT_SPECTROGRAM_SAMPLE_RATE as u32);
    let mut mono: Vec<f32> = Vec::new();
    let mut read_frames = 0usize;
    while target == 0 || read_frames < target {
        let chunk = decoder.read_stereo(4096).expect("read");
        if chunk.is_empty() {
            break;
        }
        read_frames += chunk.len() / 2;
        let downmix: Vec<f32> = chunk
            .chunks_exact(2)
            .map(|pair| (pair[0] + pair[1]) * 0.5)
            .collect();
        mono.extend(resampler.process(&downmix));
    }
    mono.extend(resampler.flush());

    let spectrogram = compute_beat_spectrogram(&mono, BEAT_SPECTROGRAM_SAMPLE_RATE);
    let mut file = std::fs::File::create(output).expect("create output");
    file.write_all(&(spectrogram.frames as u32).to_le_bytes())
        .unwrap();
    for value in &spectrogram.values {
        file.write_all(&value.to_le_bytes()).unwrap();
    }
    eprintln!(
        "rate={rate} frames={} mels=128 mono_samples={}",
        spectrogram.frames,
        mono.len()
    );
}
