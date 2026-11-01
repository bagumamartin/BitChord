#!/usr/bin/env python3
"""Beat This! final0 parity on real music: PyTorch, Core ML, and rten ONNX.

The mels are produced by the app's own Rust front end
(``mel_dumper``; native-core decode -> downmix -> StreamResampler ->
compute_beat_spectrogram), never a Python reimplementation.  Each track is run
twice:

* ``app``   - beat.rs's current chunking: 1500-frame chunks, short final chunk.
* ``right`` - fixed 1500-frame chunks, final chunk right-aligned to the track
              end, keeping only frames not already covered.  This is the only
              shape Core ML accepts.

Peak picking, tempo and the +/-1-frame matching are 1:1 ports of
native-core/src/analyzer/beat.rs.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import beat_this_common as common  # noqa: E402

try:
    import coremltools as ct
except ImportError as error:  # pragma: no cover
    raise SystemExit("install scripts/coreml/requirements.txt first: " + str(error))


def aggregate_chunks(outputs, chunks, frames):
    """Copy the same frame ranges beat.rs copies, no padding and no overlap."""
    beat = np.zeros(frames, dtype=np.float32)
    downbeat = np.zeros(frames, dtype=np.float32)
    for (start, length, keep_from, keep_to), (chunk_beat, chunk_downbeat) in zip(chunks, outputs):
        for index in range(keep_from, min(keep_to, length)):
            target = start + index
            if target >= frames:
                break
            beat[target] = chunk_beat[index]
            downbeat[target] = chunk_downbeat[index]
    return beat, downbeat


def run_pytorch_aggregated(model, mel, chunks):
    outputs = []
    for start, length, _, _ in chunks:
        x = np.ascontiguousarray(mel[start : start + length][None]).copy()
        with torch.no_grad():
            output = model(torch.from_numpy(x))
        outputs.append((output["beat"][0].numpy(), output["downbeat"][0].numpy()))
    return aggregate_chunks(outputs, chunks, len(mel))


def run_coreml(model, mel, chunks):
    outputs = []
    for start, length, _, _ in chunks:
        if length != common.TARGET_FRAMES:
            raise ValueError("Core ML only accepts fixed 1500-frame chunks")
        x = np.ascontiguousarray(mel[start : start + length][None]).copy()
        result = model.predict({"spectrogram": x})
        outputs.append((result["beat"][0], result["downbeat"][0]))
    return aggregate_chunks(outputs, chunks, len(mel))


def run_rten(cli: Path, onnx: Path, mel, chunks, workdir: Path):
    workdir.mkdir(parents=True, exist_ok=True)
    outputs = []
    for index, (start, length, _, _) in enumerate(chunks):
        input_path = workdir / f"in.{index}.bin"
        prefix = workdir / f"out.{index}"
        x = np.ascontiguousarray(mel[start : start + length]).copy()
        input_path.write_bytes(x.astype("<f4").tobytes())
        subprocess.run(
            [str(cli), str(onnx), str(input_path), str(length), str(prefix)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        beat = np.fromfile(f"{prefix}.0.bin", dtype="<f4")
        downbeat = np.fromfile(f"{prefix}.1.bin", dtype="<f4")
        if beat.size != length or downbeat.size != length:
            raise RuntimeError(f"rten {beat.size}/{downbeat.size} for {length} frames")
        outputs.append((beat, downbeat))
    return aggregate_chunks(outputs, chunks, len(mel))


def metrics(reference, test, frames):
    beat_ref, downbeat_ref = reference
    beat_test, downbeat_test = test
    result = {}
    for name, ref, got in (
        ("beat", beat_ref, beat_test),
        ("downbeat", downbeat_ref, downbeat_test),
    ):
        peaks_ref = common.pick_peaks(ref)
        peaks_got = common.pick_peaks(got)
        missed, extra = common.mismatch(peaks_ref, peaks_got)
        result[name] = {
            "snr_db": common.snr_db(ref, got),
            "max_abs": float(np.max(np.abs(ref.astype(np.float64) - got.astype(np.float64)))),
            "peaks_ref": len(peaks_ref),
            "peaks_test": len(peaks_got),
            "mismatch_missed": missed,
            "mismatch_extra": extra,
            "bpm_ref": common.tempo_from_beats([value / common.FRAME_RATE for value in peaks_ref]),
            "bpm_test": common.tempo_from_beats([value / common.FRAME_RATE for value in peaks_got]),
        }
    return result


def summarize(name, reference, test, frames):
    values = metrics(reference, test, frames)
    return {
        "name": name,
        "beat": values["beat"],
        "downbeat": values["downbeat"],
        "bpm_ref": values["beat"]["bpm_ref"],
        "bpm_test": values["beat"]["bpm_test"],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mels", required=True, type=Path, help="directory of Rust mel dumps")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--coreml-dir", required=True, type=Path,
                        help="directory holding BeatThisFinal0.fp16/int8.mlpackage")
    parser.add_argument("--onnx", required=True, type=Path)
    parser.add_argument("--rten-cli", required=True, type=Path)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--cache-dir", type=Path, default=common.DEFAULT_CACHE)
    parser.add_argument("--tracks", nargs="*", help="mel basenames (default: every .bin)")
    parser.add_argument("--cores", type=int, default=4)
    args = parser.parse_args(argv)

    torch.set_num_threads(max(1, args.cores))
    args.out.mkdir(parents=True, exist_ok=True)
    checkpoint = common.ensure_checkpoint(args.cache_dir, args.checkpoint)
    model = common.load_patched_model(checkpoint, args.cache_dir)
    fp16 = ct.models.MLModel(
        str(args.coreml_dir / "BeatThisFinal0.fp16.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    int8 = ct.models.MLModel(
        str(args.coreml_dir / "BeatThisFinal0.int8.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )

    if args.tracks:
        mels = [args.mels / f"{name}.bin" for name in args.tracks]
    else:
        mels = sorted(args.mels.glob("*.bin"))
    report = {"tracks": {}}
    for mel_path in mels:
        mel = common.read_mel(mel_path)
        frames = len(mel)
        name = mel_path.stem
        if frames < common.TARGET_FRAMES:
            print(f"skip {name}: {frames} frames (< 1500; the app uses rten)", flush=True)
            continue
        print(f"== {name}: {frames} frames ({frames/50.0:.1f}s)", flush=True)
        app_chunks = list(common.chunk_beat_rs(frames))
        right_chunks = list(common.chunk_right_aligned(frames))
        with tempfile.TemporaryDirectory(prefix=f"rten-{name}-") as tmp:
            tmp_path = Path(tmp)
            (tmp_path / "app").mkdir()
            (tmp_path / "right").mkdir()
            pt_app = run_pytorch_aggregated(model, mel, app_chunks)
            pt_right = run_pytorch_aggregated(model, mel, right_chunks)
            rten_app = run_rten(args.rten_cli, args.onnx, mel, app_chunks, tmp_path / "app")
            rten_right = run_rten(args.rten_cli, args.onnx, mel, right_chunks, tmp_path / "right")
        cm_fp16 = run_coreml(fp16, mel, right_chunks)
        cm_int8 = run_coreml(int8, mel, right_chunks)

        track = {
            "frames": frames,
            "chunks_app": len(app_chunks),
            "chunks_right": len(right_chunks),
            "last_chunk_app": list(app_chunks[-1]),
            "last_chunk_right": list(right_chunks[-1]),
            "pt_right_vs_pt_app": summarize("pt-right vs pt-app", pt_right, pt_app, frames),
            "cm_fp16_vs_pt_right": summarize("cm-fp16 vs pt-right", pt_right, cm_fp16, frames),
            "cm_int8_vs_pt_right": summarize("cm-int8 vs pt-right", pt_right, cm_int8, frames),
            "rten_right_vs_pt_right": summarize("rten-right vs pt-right", pt_right, rten_right, frames),
            "rten_app_vs_pt_app": summarize("rten-app vs pt-app", pt_app, rten_app, frames),
            "rten_app_vs_pt_right": summarize("rten-app vs pt-right", pt_right, rten_app, frames),
        }
        report["tracks"][name] = track
        for key in ("cm_fp16_vs_pt_right", "cm_int8_vs_pt_right", "rten_right_vs_pt_right"):
            item = track[key]
            print(
                f"  {key:26s} beat {item['beat']['snr_db']:6.2f} dB  "
                f"peaks {item['beat']['peaks_ref']}/{item['beat']['peaks_test']}  "
                f"+-1 {item['beat']['mismatch_missed']}/{item['beat']['mismatch_extra']}  "
                f"down {item['downbeat']['snr_db']:6.2f} dB  "
                f"{item['downbeat']['peaks_ref']}/{item['downbeat']['peaks_test']}  "
                f"+-1 {item['downbeat']['mismatch_missed']}/{item['downbeat']['mismatch_extra']}  "
                f"bpm {item['bpm_ref']:.1f}/{item['bpm_test']:.1f}",
                flush=True,
            )
        print(
            f"  pt-right vs pt-app        last {app_chunks[-1][:2]} -> {right_chunks[-1][:2]}  "
            f"beat {track['pt_right_vs_pt_app']['beat']['snr_db']:.2f} dB  "
            f"bpm {track['pt_right_vs_pt_app']['bpm_ref']:.1f}/{track['pt_right_vs_pt_app']['bpm_test']:.1f}",
            flush=True,
        )

    common.write_json(args.out / "parity.json", report)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
