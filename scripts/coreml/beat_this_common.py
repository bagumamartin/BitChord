"""Shared helpers for the Beat This! final0 Core ML conversion.

Pinned upstream, checkpoint verification, the two source-level patches the
converter needs, and the app-side chunking / peak-picking logic used by the
parity script.  Nothing here vendored: the model package is fetched at a
pinned git commit into a cache directory and patched in memory where possible
(the Python 3.9 ``from __future__`` shim is the one source edit).
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

SOURCE_REPO = "https://github.com/CPJKU/beat_this.git"
# v1.1.0 (the version the app's export was built from); pinned by commit, not tag.
SOURCE_COMMIT = "ad7974846029835307ba19a3d5cefbf40b243041"
CHECKPOINT_URL = "https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt"
CHECKPOINT_SHA256 = "8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331"
CHECKPOINT_SIZE = 81_058_141

TARGET_FRAMES = 1500
BORDER_FRAMES = 6
FRAME_RATE = 50.0

DEFAULT_CACHE = Path(
    os.environ.get("BITCHORD_COREML_CACHE", Path.home() / ".cache" / "bitchord-coreml")
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download_verified(url: str, destination: Path, sha256: str, size: int) -> Path:
    """Download once, verify the pinned bytes, then atomically publish."""
    destination = Path(destination)
    if destination.exists() and destination.stat().st_size == size:
        if sha256_file(destination) == sha256:
            return destination
        destination.unlink()
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".part")
    if partial.exists():
        partial.unlink()
    print(f"downloading {url}", flush=True)
    with urllib.request.urlopen(url, timeout=120) as response, open(partial, "wb") as out:
        shutil.copyfileobj(response, out, length=1 << 20)
    if partial.stat().st_size != size:
        raise RuntimeError(
            f"checkpoint size {partial.stat().st_size} != pinned {size}; refusing to continue"
        )
    got = sha256_file(partial)
    if got != sha256:
        raise RuntimeError(f"checkpoint SHA-256 {got} != pinned {sha256}; refusing to continue")
    os.replace(partial, destination)
    return destination


def ensure_checkpoint(cache_dir: Path, checkpoint: Path | None = None) -> Path:
    if checkpoint is not None:
        checkpoint = Path(checkpoint)
        if not checkpoint.exists():
            raise FileNotFoundError(checkpoint)
        if checkpoint.stat().st_size != CHECKPOINT_SIZE or sha256_file(checkpoint) != CHECKPOINT_SHA256:
            raise RuntimeError(f"{checkpoint} does not match the pinned final0 checkpoint")
        return checkpoint
    return download_verified(
        CHECKPOINT_URL, Path(cache_dir) / "final0.ckpt", CHECKPOINT_SHA256, CHECKPOINT_SIZE
    )


def ensure_source(cache_dir: Path) -> Path:
    """Fetch CPJKU/beat_this at SOURCE_COMMIT into a reusable cache checkout."""
    repo = Path(cache_dir) / "beat_this-src"
    git_dir = repo / ".git"
    if git_dir.is_dir():
        try:
            head = subprocess.check_output(
                ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
            ).strip()
        except subprocess.CalledProcessError:
            head = ""
        if head == SOURCE_COMMIT:
            return repo
    if repo.exists():
        shutil.rmtree(repo)
    repo.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "remote", "add", "origin", SOURCE_REPO], check=True
    )
    subprocess.run(
        ["git", "-C", str(repo), "fetch", "-q", "--depth", "1", "origin", SOURCE_COMMIT],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(repo), "checkout", "-q", "--detach", "FETCH_HEAD"], check=True
    )
    head = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
    ).strip()
    if head != SOURCE_COMMIT:
        raise RuntimeError(f"fetched {head}, expected {SOURCE_COMMIT}")
    return repo


def add_python39_annotations(repo: Path) -> None:
    """Prepend the future import on Python 3.9.

    Upstream uses PEP 604 annotations (``int | None``) that Python 3.9 cannot
    evaluate at class-definition time.  The import makes them strings and is a
    no-op on 3.10+.  Inserted at the very top: a module docstring is still a
    string expression, and the future import remains valid.
    """
    if sys.version_info >= (3, 10):
        return
    package = Path(repo) / "beat_this"
    for path in sorted(package.rglob("*.py")):
        text = path.read_text()
        if "from __future__ import annotations" in text:
            continue
        path.write_text("from __future__ import annotations\n" + text)


def import_beat_this(cache_dir: Path):
    repo = ensure_source(Path(cache_dir))
    add_python39_annotations(repo)
    repo_str = str(repo)
    if repo_str not in sys.path:
        sys.path.insert(0, repo_str)
    from beat_this.inference import load_model  # noqa: F401

    return load_model


def patch_rotary() -> None:
    """Rewrite rotary_embedding_torch's generic einsum path.

    coremltools cannot lower ``einsum("..., f -> ... f")`` (MIL rejects the
    one-character permutation).  This is the exact algebra for the shapes this
    model uses: sequence position times the frequency table, doubled by
    repeat_interleave, then the standard rotate-half product.
    """
    import rotary_embedding_torch.rotary_embedding_torch as rotary

    def rotate_queries_or_keys(self, t, seq_dim=None, offset=0, scale=None):
        if offset != 0:
            raise NotImplementedError("beat_this only uses offset=0")
        seq_dim = self.default_seq_dim if seq_dim is None else seq_dim
        seq_len = t.shape[seq_dim]
        seq = torch.arange(seq_len, device=t.device, dtype=t.dtype)
        freqs = torch.repeat_interleave(seq[:, None] * self.freqs, 2, dim=-1)
        return (t * freqs.cos()) + (rotary.rotate_half(t) * freqs.sin())

    rotary.RotaryEmbedding.rotate_queries_or_keys = rotate_queries_or_keys


def disable_rotary_cache(model: nn.Module) -> None:
    for module in model.modules():
        if hasattr(module, "cache_if_possible"):
            module.cache_if_possible = False


def patch_rmsnorm(model: nn.Module) -> int:
    """Replace RMSNorm's F.normalize with ANE-friendly elementwise MIL ops.

    Upstream: ``F.normalize(x, dim=-1) * sqrt(dim) * gamma``.  With
    ``rms = sqrt(mean(x^2))`` that is ``x / rms * gamma``.  F.normalize clamps
    the norm at 1e-12, equivalent to flooring the mean at 1e-24; adding 1e-24
    to the mean reproduces that clamp to within one ulp of the floor.  No
    reduce_l2_norm op is emitted, so no RMSNorm falls back to the CPU.
    """
    count = 0
    for module in model.modules():
        if module.__class__.__name__ == "RMSNorm" and hasattr(module, "gamma"):
            module.forward = _rmsnorm_forward.__get__(module, type(module))
            count += 1
    return count


def _rmsnorm_forward(self, x):
    mean_square = torch.mean(x * x, dim=self.dim, keepdim=True)
    return x * torch.rsqrt(mean_square + 1e-24) * self.gamma


# Query rows per attention block. 1500 / 150 = 10 blocks for the time
# attention; shorter sequences (the frontend's frequency attention) are one.
ATTENTION_BLOCK = 150


def patch_attention(model: nn.Module, block: int = ATTENTION_BLOCK) -> int:
    """Compute attention in blocks of query rows.

    Each query row's softmax only reads its own scores, so splitting the
    queries and concatenating the results is the same algebra. On the Neural
    Engine it is not the same memory: the whole-sequence form keeps every
    head's 1500x1500 score matrix live, about 450 MB of device buffers per
    loaded model, which macOS charges to the app. In 150-row blocks the
    measured cost is about 120 MB, and each window predicts slightly faster.
    """
    count = 0
    for module in model.modules():
        if module.__class__.__name__ == "Attend":
            module.forward = _blocked_attend.__get__(module, type(module))
            module.attention_block = block
            count += 1
    return count


def _blocked_attend(self, q, k, v):
    if self.scale is not None:
        q = q * (self.scale / (q.shape[-1] ** -0.5))
    block = self.attention_block
    rows = q.shape[-2]
    if rows <= block:
        return F.scaled_dot_product_attention(q, k, v)
    return torch.cat(
        [
            F.scaled_dot_product_attention(q[..., start : start + block, :], k, v)
            for start in range(0, rows, block)
        ],
        dim=-2,
    )


class BeatThisWrapper(nn.Module):
    """Stable Core ML output names: beat and downbeat."""

    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model

    def forward(self, spectrogram):
        result = self.model(spectrogram)
        return result["beat"], result["downbeat"]


def load_patched_model(checkpoint: Path, cache_dir: Path, patch_rms: bool = True):
    patch_rotary()
    load_model = import_beat_this(Path(cache_dir))
    model = load_model(str(checkpoint)).eval()
    disable_rotary_cache(model)
    if patch_rms:
        patch_rmsnorm(model)
        patch_attention(model)
    return model


# ---- app-side frame logic -------------------------------------------------


def read_mel(path: Path) -> np.ndarray:
    """Read the Rust dumper's [frames,128] format: u32 count, then f32 rows."""
    raw = Path(path).read_bytes()
    if len(raw) < 4:
        raise ValueError(f"{path}: short mel file")
    frames = int.from_bytes(raw[:4], "little")
    values = np.frombuffer(raw[4:], dtype="<f4")
    if values.size != frames * 128:
        raise ValueError(f"{path}: {values.size} floats for {frames} frames")
    return values.reshape(frames, 128).copy()


def chunk_beat_rs(frames: int):
    """The app's current chunking in native-core/src/analyzer/beat.rs.

    Returns (start, length, keep_from, keep_to) per chunk.  The last chunk is
    short and starts at the next 1488-frame stride; its left 6 frames are
    discarded unless it is the first chunk, exactly as beat.rs does.
    """
    stride = TARGET_FRAMES - 2 * BORDER_FRAMES
    start = 0
    while start < frames:
        length = min(TARGET_FRAMES, frames - start)
        if length <= 2 * BORDER_FRAMES and start > 0:
            break
        keep_from = 0 if start == 0 else BORDER_FRAMES
        keep_to = length if start + length >= frames else length - BORDER_FRAMES
        yield start, length, keep_from, keep_to
        if start + length >= frames:
            break
        start += stride


def chunk_right_aligned(frames: int):
    """Fixed 1500-frame chunks with the last one aligned to the track end.

    The final chunk starts at ``frames - 1500`` and only the frames not already
    written by earlier chunks are kept, so the model gets real left context
    instead of silence.  Core ML's input is fixed at 1500 frames, so padding
    would change real frames (the transformer attends globally).
    """
    if frames < TARGET_FRAMES:
        raise ValueError(f"{frames} frames is shorter than the Core ML chunk")
    stride = TARGET_FRAMES - 2 * BORDER_FRAMES
    start = 0
    covered = 0
    while True:
        if start + TARGET_FRAMES >= frames:
            last_start = frames - TARGET_FRAMES
            keep_from = 0 if last_start == 0 else max(BORDER_FRAMES, covered - last_start)
            if keep_from >= TARGET_FRAMES:
                return
            yield last_start, TARGET_FRAMES, keep_from, TARGET_FRAMES
            return
        yield start, TARGET_FRAMES, 0 if start == 0 else BORDER_FRAMES, TARGET_FRAMES - BORDER_FRAMES
        covered = start + TARGET_FRAMES - BORDER_FRAMES
        start += stride


def pick_peaks(logits: np.ndarray):
    """1:1 port of native-core/src/analyzer/beat.rs pick_peaks."""
    half = 7 // 2
    peaks = []
    for index in range(len(logits)):
        if logits[index] <= 0.0:
            continue
        is_maximum = True
        for offset in range(-half, half + 1):
            neighbour = index + offset
            if neighbour < 0 or neighbour >= len(logits):
                continue
            if logits[neighbour] > logits[index]:
                is_maximum = False
                break
        if is_maximum:
            peaks.append(index)

    deduped = []
    index = 0
    while index < len(peaks):
        mean = float(peaks[index])
        count = 1.0
        while index + 1 < len(peaks) and (peaks[index + 1] - mean) <= 1.0:
            index += 1
            count += 1.0
            mean += (peaks[index] - mean) / count
        deduped.append(int(round(mean)))
        index += 1

    spaced = []
    for frame in deduped:
        if spaced and (frame - spaced[-1]) < 6:
            if logits[frame] > logits[spaced[-1]]:
                spaced.pop()
                spaced.append(frame)
        else:
            spaced.append(frame)

    out = []
    for frame in spaced:
        if frame == 0 or frame + 1 >= len(logits):
            out.append(float(frame))
            continue
        left = float(logits[frame - 1])
        centre = float(logits[frame])
        right = float(logits[frame + 1])
        denominator = left - 2.0 * centre + right
        if abs(denominator) <= 1e-9:
            out.append(float(frame))
            continue
        out.append(frame + max(-0.5, min(0.5, 0.5 * (left - right) / denominator)))
    return out


def mismatch(reference, test, tol=1.0):
    """One-to-one nearest matching within tol frames; returns (missed, extra)."""
    reference = list(reference)
    test = list(test)
    used = [False] * len(test)
    matched = 0
    for value in reference:
        best = float("inf")
        best_index = -1
        for index, candidate in enumerate(test):
            if used[index]:
                continue
            distance = abs(value - candidate)
            if distance < best:
                best = distance
                best_index = index
        if best_index >= 0 and best <= tol:
            used[best_index] = True
            matched += 1
    return len(reference) - matched, len(test) - matched


def tempo_from_beats(beats) -> float:
    """1:1 port of beat.rs tempo_from_beats (median interval, 40-220 BPM)."""
    if len(beats) < 8:
        return 0.0
    gaps = [beats[i + 1] - beats[i] for i in range(len(beats) - 1)]
    rough = float(np.median(gaps))
    if rough <= 0.0:
        return 0.0
    kept = [gap for gap in gaps if abs(gap - rough) <= rough * 0.2]
    interval = float(np.median(kept if len(kept) >= 4 else gaps))
    if interval <= 0.0:
        return 0.0
    bpm = 60.0 / interval
    return bpm if 40.0 <= bpm <= 220.0 else 0.0


def snr_db(reference: np.ndarray, test: np.ndarray) -> float:
    reference = np.asarray(reference, dtype=np.float64)
    error = reference - np.asarray(test, dtype=np.float64)
    signal = float(np.sum(reference * reference))
    noise = float(np.sum(error * error))
    if noise == 0.0:
        return float("inf")
    return float(10.0 * np.log10(signal / max(noise, 1e-300)))


def write_json(path: Path, payload) -> None:
    Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
