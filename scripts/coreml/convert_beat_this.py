#!/usr/bin/env python3
"""Reproducible Beat This! final0 -> Core ML mlprogram conversion.

Fetches CPJKU/beat_this at a pinned commit and the official final0 checkpoint
(SHA-256 verified), applies the two conversion patches in-process, converts a
fixed [1,1500,128] float32 graph, emits fp16 and int8 (linear weight PTQ)
variants, picks the shipping variant, and packages it as
BeatThisFinal0.mlpackage inside beat_this_final0_coreml.aar.

Usage:
    python scripts/coreml/convert_beat_this.py --out /tmp/bitchord-coreml/release
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import beat_this_common as common  # noqa: E402

try:
    import coremltools as ct
    from coremltools.proto import Model_pb2
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )
except ImportError as error:  # pragma: no cover - the message is the point
    raise SystemExit("install scripts/coreml/requirements.txt first: " + str(error))

TARGET = common.TARGET_FRAMES
SOURCE_DATE_EPOCH = 1_700_000_000
MODEL_NAME = "BeatThisFinal0.mlpackage"
ARCHIVE_NAME = "beat_this_final0_coreml.aar"

DESCRIPTION = (
    "Beat This! final0 beat/downbeat logits over a 128-bin Slaney log-mel "
    "spectrogram, fixed 1500-frame chunks, float32 I/O."
)


def set_metadata(model: "ct.models.MLModel", variant: str) -> None:
    model.author = "BitChord"
    model.license = "MIT"
    model.short_description = DESCRIPTION
    model.version = "1.0"
    metadata = model.user_defined_metadata
    # coremltools stamps the wall-clock date into the spec; strip it so two
    # conversions of the same source produce the same bytes.
    for key in list(metadata):
        if key.endswith("conversion_date"):
            del metadata[key]
    metadata.update(
        {
            "provenance": (
                "CPJKU/beat_this@" + common.SOURCE_COMMIT
                + " final0.ckpt sha256:" + common.CHECKPOINT_SHA256
            ),
            "source_commit": common.SOURCE_COMMIT,
            "checkpoint_sha256": common.CHECKPOINT_SHA256,
            "checkpoint_bytes": str(common.CHECKPOINT_SIZE),
            "variant": variant,
            "contract": "input spectrogram float32 [1,1500,128]; outputs beat,downbeat float32 [1,1500] logits",
        }
    )
    # ScalarMap is a live view of the spec; mutate it in place (the property
    # has no setter in coremltools 9).


def normalize_package(path: Path) -> None:
    """Make the mlpackage bytes independent of conversion time.

    coremltools writes random UUIDs into Manifest.json.  They are opaque item
    identifiers, so replace them deterministically and set every mtime to a
    fixed epoch before archiving.
    """
    manifest_path = path / "Manifest.json"
    manifest = json.loads(manifest_path.read_text())
    entries = sorted(manifest["itemInfoEntries"].items(), key=lambda item: item[1]["path"])
    fixed_ids = [
        "00000000-0000-0000-0000-000000000001",
        "00000000-0000-0000-0000-000000000002",
    ]
    if len(entries) > len(fixed_ids):
        fixed_ids.extend(
            f"00000000-0000-0000-0000-{index:012d}" for index in range(3, len(entries) + 1)
        )
    new_entries = {}
    root_id = fixed_ids[0]
    for (old_id, info), new_id in zip(entries, fixed_ids):
        new_entries[new_id] = info
        if info.get("name") == "model.mlmodel":
            root_id = new_id
    manifest["itemInfoEntries"] = new_entries
    manifest["rootModelIdentifier"] = root_id
    manifest_path.write_text(json.dumps(manifest, indent=4, sort_keys=True) + "\n")

    # The spec protobuf has map fields, so coremltools' default serialization
    # order varies between runs even when the model is semantically identical.
    # Deterministic serialization makes the .mlmodel bytes stable too.
    spec_path = path / "Data" / "com.apple.CoreML" / "model.mlmodel"
    spec = Model_pb2.Model()
    spec.ParseFromString(spec_path.read_bytes())
    spec_path.write_bytes(spec.SerializeToString(deterministic=True))

    for root, directories, files in os.walk(path, topdown=False):
        for name in files + directories:
            os.utime(os.path.join(root, name), (SOURCE_DATE_EPOCH, SOURCE_DATE_EPOCH))
    os.utime(path, (SOURCE_DATE_EPOCH, SOURCE_DATE_EPOCH))


def model_size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def convert(args) -> None:
    out = Path(args.out).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    cache = Path(args.cache_dir).expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)

    checkpoint = common.ensure_checkpoint(cache, args.checkpoint)
    print(f"checkpoint {checkpoint} sha256={common.sha256_file(checkpoint)}", flush=True)
    model = common.load_patched_model(checkpoint, cache, patch_rms=False)

    torch.manual_seed(0)
    example = torch.randn(1, TARGET, 128)
    with torch.no_grad():
        reference = model(example)
        original = {key: value.clone() for key, value in reference.items()}

    patched = common.patch_rmsnorm(model)
    with torch.no_grad():
        rewritten = model(example)
    parity = {}
    for head in ("beat", "downbeat"):
        error = (original[head] - rewritten[head]).abs()
        parity[head] = {
            "max_abs": float(error.max()),
            "snr_db": common.snr_db(original[head].numpy(), rewritten[head].numpy()),
        }
    print(f"RMSNorm rewritten in {patched} modules; fp32 parity {json.dumps(parity)}", flush=True)
    if min(parity[head]["snr_db"] for head in parity) < args.min_parity_db:
        raise SystemExit(
            f"RMSNorm rewrite parity below {args.min_parity_db} dB: {json.dumps(parity)}"
        )

    wrapper = common.BeatThisWrapper(model).eval()
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)
        eager = wrapper(example)
        traced_out = traced(example)
    for head, value in zip(("beat", "downbeat"), traced_out):
        difference = (eager[("beat", "downbeat").index(head)] - value).abs().max()
        if float(difference) != 0.0:
            raise SystemExit(f"traced {head} differs from eager by {float(difference)}")

    inputs = [
        ct.TensorType(name="spectrogram", shape=(1, TARGET, 128), dtype=np.float32)
    ]
    outputs = [
        ct.TensorType(name="beat", dtype=np.float32),
        ct.TensorType(name="downbeat", dtype=np.float32),
    ]
    started = time.time()
    fp16_model = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    set_metadata(fp16_model, "fp16")
    fp16_path = out / "BeatThisFinal0.fp16.mlpackage"
    if fp16_path.exists():
        shutil.rmtree(fp16_path)
    fp16_model.save(str(fp16_path))
    normalize_package(fp16_path)
    print(f"fp16 {fp16_path} ({model_size(fp16_path)/1e6:.1f} MB) in {time.time()-started:.1f}s", flush=True)

    # Linear per-channel int8 weight quantization, exactly the pass the
    # prototype used.  Quantizing the saved fp16 package matches that run.
    config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel"
        )
    )
    int8_model = linear_quantize_weights(ct.models.MLModel(str(fp16_path)), config)
    set_metadata(int8_model, "int8-linear-ptq")
    int8_path = out / "BeatThisFinal0.int8.mlpackage"
    if int8_path.exists():
        shutil.rmtree(int8_path)
    int8_model.save(str(int8_path))
    normalize_package(int8_path)
    print(f"int8 {int8_path} ({model_size(int8_path)/1e6:.1f} MB)", flush=True)

    variants = {"fp16": fp16_path, "int8": int8_path}
    chosen = variants[args.ship]
    chosen_path = out / MODEL_NAME
    if chosen_path.exists():
        shutil.rmtree(chosen_path)
    shutil.copytree(chosen, chosen_path)
    normalize_package(chosen_path)

    # Re-load the chosen package and check its declared contract.
    probe = ct.models.MLModel(str(chosen_path))
    spec = probe.get_spec()
    input_type = spec.description.input[0].type.multiArrayType
    if list(input_type.shape) != [1, TARGET, 128] or int(input_type.dataType) != 65568:
        raise SystemExit(
            f"unexpected input contract: shape={list(input_type.shape)} dtype={int(input_type.dataType)}"
        )
    for output in spec.description.output:
        if int(output.type.multiArrayType.dataType) != 65568:
            raise SystemExit(f"output {output.name} is not float32")
    with torch.no_grad():
        expected = int8_model.predict({"spectrogram": example.numpy()}) if args.ship == "int8" else fp16_model.predict({"spectrogram": example.numpy()})
    loaded = probe.predict({"spectrogram": example.numpy()})
    for head in ("beat", "downbeat"):
        if not np.array_equal(expected[head], loaded[head]):
            raise SystemExit(f"reloaded {args.ship} {head} differs from the in-memory model")

    aar = out / ARCHIVE_NAME
    if not args.no_archive:
        aa = shutil.which("aa")
        if aa is None:
            raise SystemExit("'aa' (Apple Archive) is not on PATH")
        stage = out / "_archive_root"
        if stage.exists():
            shutil.rmtree(stage)
        stage.mkdir()
        shutil.copytree(chosen_path, stage / MODEL_NAME)
        normalize_package(stage / MODEL_NAME)
        # The root entry's ctime/mtime is archived too; pin it as well.
        os.utime(stage, (SOURCE_DATE_EPOCH, SOURCE_DATE_EPOCH))
        if aar.exists():
            aar.unlink()
        subprocess.run([aa, "archive", "-d", str(stage), "-o", str(aar)], check=True)
        verify = out / "_archive_verify"
        if verify.exists():
            shutil.rmtree(verify)
        verify.mkdir()
        subprocess.run([aa, "extract", "-i", str(aar), "-d", str(verify)], check=True)
        extracted = verify / MODEL_NAME
        if not extracted.is_dir():
            raise SystemExit("archive round-trip did not produce BeatThisFinal0.mlpackage")
        extracted_model = ct.models.MLModel(str(extracted))
        extracted_out = extracted_model.predict({"spectrogram": example.numpy()})
        for head in ("beat", "downbeat"):
            if not np.array_equal(expected[head], extracted_out[head]):
                raise SystemExit(f"archive-extracted {head} differs from the in-memory model")
        print(
            f"archive {aar} ({aar.stat().st_size} B) sha256={common.sha256_file(aar)}",
            flush=True,
        )
        shutil.rmtree(stage)
        shutil.rmtree(verify)

    report = {
        "source_commit": common.SOURCE_COMMIT,
        "checkpoint_sha256": common.CHECKPOINT_SHA256,
        "checkpoint_bytes": common.CHECKPOINT_SIZE,
        "rmsnorm_modules": patched,
        "rmsnorm_fp32_parity": parity,
        "ship": args.ship,
        "models": {
            "fp16": {"path": str(fp16_path), "bytes": model_size(fp16_path)},
            "int8": {"path": str(int8_path), "bytes": model_size(int8_path)},
            "chosen": {"path": str(chosen_path), "bytes": model_size(chosen_path)},
        },
        "archive": None if args.no_archive else {
            "path": str(aar),
            "bytes": aar.stat().st_size,
            "sha256": common.sha256_file(aar),
        },
        "versions": {
            "python": sys.version.split()[0],
            "torch": torch.__version__,
            "coremltools": ct.__version__,
            "numpy": np.__version__,
        },
    }
    common.write_json(out / "conversion.json", report)
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--cache-dir", default=str(common.DEFAULT_CACHE))
    parser.add_argument("--checkpoint", type=Path, help="use this final0.ckpt (still SHA-verified)")
    parser.add_argument("--ship", choices=("int8", "fp16"), default="int8")
    parser.add_argument("--no-archive", action="store_true")
    parser.add_argument("--min-parity-db", type=float, default=120.0)
    return parser.parse_args(argv)


if __name__ == "__main__":
    convert(parse_args())
