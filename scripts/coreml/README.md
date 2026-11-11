# Beat This! final0 → Core ML

A reproducible conversion of CPJKU **Beat This! final0** to a fixed-shape
Core ML `mlprogram`, plus the parity/placement harness used to choose the
shipping variant. Only this directory is touched by the conversion.

## Provenance

| | |
|---|---|
| Model code | [`CPJKU/beat_this`](https://github.com/CPJKU/beat_this) @ `ad7974846029835307ba19a3d5cefbf40b243041` (v1.1.0, MIT) |
| Checkpoint | `final0.ckpt`, official CPJKU DAV URL, 81,058,141 B, SHA-256 `8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331` |
| Conversion | torch 2.13.0 CPU, coremltools 9.0, `minimum_deployment_target=iOS18` (macOS 15). The published v1/v2 archives were converted with torch 2.8.0; 2.13.0 produces the same weights and program, differing only in the recorded `torch==` version string |
| Output | int8 linear per-channel weight PTQ, about 20.8 MB (v2 archive 18,826,124 B) |

The model source is fetched into a cache at the pinned commit and patched by
`convert_beat_this.py`; it is not vendored. `git` and Apple's `aa` must be on
`PATH`. The run is byte-reproducible from a fresh Python 3.12 venv (torch 2.13
needs Python 3.10 or later). On Python 3.9 the script adds
`from __future__ import annotations` to the fetched package (upstream uses PEP
604 annotations). Two additional in-process patches:

1. **Rotary einsum** — `einsum("..., f -> ... f")` cannot lower to MIL;
   `rotate_queries_or_keys` is rewritten as position × frequency broadcast +
   `repeat_interleave(2)` + cos/sin (exact; no cached table).
2. **RMSNorm** — `F.normalize(x, -1) * sqrt(dim) * gamma` becomes
   `x * rsqrt(mean(x², -1) + 1e-24) * gamma`. 1e-24 is the mean-domain
   equivalent of F.normalize's 1e-12 norm clamp. The 25 `reduce_l2_norm` CPU
   ops become `reduce_mean` + `rsqrt` on the ANE.
3. **Blocked attention** (since `model-beat-this-final0-coreml-v2`) — every
   `Attend` computes `scaled_dot_product_attention` in 150-row query blocks
   and concatenates them. Each query row's softmax only reads its own scores,
   so this is the same algebra; the converter's fp32 parity gate covers it.
   Whole-sequence attention kept every head's 1500×1500 score matrix live on
   the Neural Engine, about 460 MB of device buffers that macOS charges to the
   app. Blocked, a GUI test process is charged about 90 MB and a window
   predicts in about 215 ms instead of 237 ms. Block sizes 100–150 measured
   best; 50 and 500 cost more. v2 is 18,826,124 B, SHA-256 `cd00f20b…`; on
   five real tracks its beat/downbeat peaks and BPM match v1 exactly.

## Run

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r scripts/coreml/requirements.txt          # exact pins
python scripts/coreml/convert_beat_this.py --out /tmp/bitchord-coreml/release
```

`--out` also accepts already-downloaded `--checkpoint PATH` (still SHA-checked)
and `--ship fp16|int8` (default `int8`). Outputs:

- `BeatThisFinal0.fp16.mlpackage` (40.9 MB)
- `BeatThisFinal0.int8.mlpackage` (20.7 MB)
- `BeatThisFinal0.mlpackage` — the chosen variant
- `beat_this_final0_coreml.aar` — Apple Archive containing that package
- `conversion.json`

The converter verifies the RMSNorm rewrite in fp32 (≥120 dB), traces, converts,
quantizes, checks the float32 I/O contract, re-loads the package, builds the
archive with `aa archive`, extracts it with `aa extract`, and runs the extracted
model before returning. Two independent runs produce byte-identical `.mlpackage`
and `.aar` files; `Manifest.json` UUIDs, mtimes and protobuf map ordering are
canonicalised for that (verified across a fresh Python 3.11 venv, a fresh source
clone and two runs on the same machine: same `.aar` SHA-256). Pin the `.aar` bytes.

**Contract (fixed):** input `spectrogram` Float32 `[1,1500,128]`; outputs
`beat`, `downbeat` Float32 `[1,1500]` logits, same meaning as the ONNX heads.
Metadata: author `BitChord`, license `MIT`, short description, and
`source_commit` / `checkpoint_sha256` / `provenance` user keys.

## Parity

The Rust dumper in `mel_dumper/` path-depends on `native-core` and uses the
app's decode → stereo downmix → `StreamResampler(22.05 kHz)` →
`compute_beat_spectrogram` path. It writes `u32 frames` then row-major f32.

```bash
CARGO_TARGET_DIR=/tmp/bitchord-coreml/meldump-target \
  cargo run --release --manifest-path scripts/coreml/mel_dumper/Cargo.toml -- \
  ~/Library/Caches/BitChord/audio/<track>.m4a /tmp/mel/<track>.bin

python scripts/coreml/parity_beat_this.py \
  --mels /tmp/mel --out /tmp/parity \
  --coreml-dir /tmp/bitchord-coreml/release \
  --onnx /tmp/bitchord-coreml/beat_final0.onnx \
  --rten-cli /tmp/bitchord-coreml/proto/bin/rten_cli
```

Picking, tempo and ±1 matching are 1:1 ports of `native-core/src/analyzer/beat.rs`.
Each track runs with `app` chunking (short last chunk) and `right` chunking
(full 1500-frame final window ending at the track end; only uncovered frames are
copied). Core ML is only run right-aligned.

Results on the two cached tracks and the 30 s/120 BPM click track; SNR is
Core ML vs PyTorch float, counts are peaks/±1 mismatches:

| Track | BPM | int8 beat | int8 downbeat | rten int8 beat | rten int8 downbeat |
|---|---|---|---|---|---|
| `o0cgJIEq8WE` (216.5 s) | 72.0 | 50.5 dB, 255/255, 0/0 | 55.2 dB, 64/64, 0/0 | 32.0 dB, 1 miss/2 extra | 37.1 dB, 1/1 |
| `p_JXC884wAo` (212.3 s) | 115.1 | 49.3 dB, 399/399, 0/0 | 53.6 dB, 100/100, 0/0 | 32.8 dB, 0/0 | 37.2 dB, 0/0 |
| `click120` (30.0 s) | 120.0 | 43.1 dB, 61/61, 0/0 | 44.5 dB, 57/57, 0/0 | 28.8 dB, 0/0 | 30.5 dB, 51/57, 6 miss/0 extra |

fp16 scores 55.6–59.2 dB beat and 57.7–62.9 dB downbeat, also 0/0. Int8 is the
shipping variant: it beats the shipped rten int8 graph on every track while
being 20.7 MB. Full-track fp32 Core ML vs PyTorch is 121.7–125.7 dB (beat) and
123.0–128.8 dB (downbeat); the RMSNorm rewrite itself is 128.9/131.1 dB.

Right-aligning changes only the final window: `o0cgJIEq8WE` last app chunk
`(10416,409)` vs right `(9325,1500)` gives a whole-track 20.9 dB and
2 missed/3 extra beat peaks; `p_JXC884wAo` `(10416,200)`→`(9116,1500)` gives
30.1 dB and 0/0; `click120` `(1488,13)`→`(1,1500)` gives 27.8 dB and 1/1.
BPM is unchanged in all three cases.

## Placement and latency

Build `mlcli` (`swiftc -O -parse-as-library scripts/coreml/mlcli.swift -o /tmp/mlcli`)
and run with `--plan`. Under `CPU_AND_NE` the chosen model is **672 ANE / 0 CPU**
of 1336 ops (664 unassigned: 592 const, 58 int8 scale, 12 SDPA, 2 cast); before
the RMSNorm rewrite the prototype had 646 ANE / 25 CPU. Latency, median of 25
runs on an idle M2: **CPU_AND_NE 178 ms, ALL 178 ms**; rten 2 threads on the same
1500-frame chunk: **833–985 ms**.
