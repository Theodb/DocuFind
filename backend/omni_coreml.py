"""BidirLM-Omni on the Neural Engine through Core ML, without PyTorch.

The model is published as Core ML packages (tools/coreml builds them from the PyTorch model):
  text_first   text layers 1–14, with the photo snapshots added after layers 1 and 2   (512 to 1,024 tokens)
  text_last    text layers 15–28, final norm and mean pooling                           (512 to 1,024 tokens)
  vision       the photo part                                                           (1,728 and 2,304 patches)
  audio        the audio part                                                           (one 30-second window)
Everything else happens here with NumPy: tokens, photo patches, audio spectrum, positions and the sequence layout.
"""
from __future__ import annotations

import json
import math
import os
import shutil
from pathlib import Path
from typing import Any, Callable

import numpy as np

HIDDEN, HEAD_DIM, SEGMENTS = 2048, 128, 8
TEXT_SIZES = (512, 640, 1024)             # 512 packs short texts; longer ones go whole up to 1,024 tokens
VISION_SIZES = (1728, 2304)
PATCH, MERGE, TEMPORAL = 16, 2, 2
FACTOR = PATCH * MERGE
IMAGE_SIDE = 768                       # photos are embedded at most this long on their longest side
MIN_PIXELS, MAX_PIXELS = 65536, 1048576
AUDIO_SECONDS, AUDIO_RATE, HOP, N_FFT = 30, 16000, 160, 400
AUDIO_CHUNKS, AUDIO_FRAMES, AUDIO_PER_CHUNK, AUDIO_SEQ = 15, 200, 25, 400
PROMPT, END = "<|im_start|>user\n", "<|im_end|>\n"


# MARK: - Preprocessing

def image_size(width: int, height: int) -> tuple[int, int]:
    """The size a photo is resized to, once: fit within IMAGE_SIDE, then each side to a multiple of 32 (Qwen2-VL's rule)."""
    scale = min(1.0, IMAGE_SIDE / max(width, height))
    w, h = width * scale, height * scale
    if max(w, h) / min(w, h) > 200:
        raise ValueError("This image is too long and thin to read.")
    h_bar, w_bar = round(h / FACTOR) * FACTOR, round(w / FACTOR) * FACTOR
    if h_bar * w_bar > MAX_PIXELS:
        beta = math.sqrt(h * w / MAX_PIXELS)
        h_bar, w_bar = max(FACTOR, math.floor(h / beta / FACTOR) * FACTOR), max(FACTOR, math.floor(w / beta / FACTOR) * FACTOR)
    elif h_bar * w_bar < MIN_PIXELS:
        beta = math.sqrt(MIN_PIXELS / (h * w))
        h_bar, w_bar = math.ceil(h * beta / FACTOR) * FACTOR, math.ceil(w * beta / FACTOR) * FACTOR
    return max(FACTOR, w_bar), max(FACTOR, h_bar)


def resize_image(image: Any) -> Any:
    """An RGB PIL image at the size the model reads, in one bicubic resize."""
    from PIL import Image
    image = image.convert("RGB")
    size = image_size(*image.size)
    return image if image.size == size else image.resize(size, Image.BICUBIC)


def image_patches(image: Any) -> tuple[np.ndarray, tuple[int, int]]:
    """Qwen2-VL patches of an already resized image: (patches, 1536) in merge-block order, and the (rows, columns) grid."""
    pixels = (np.asarray(image, dtype=np.float32) / 255.0 - 0.5) / 0.5            # (H, W, 3)
    pixels = pixels.transpose(2, 0, 1)                                              # (3, H, W)
    rows, cols = pixels.shape[1] // PATCH, pixels.shape[2] // PATCH
    p = pixels.reshape(3, rows // MERGE, MERGE, PATCH, cols // MERGE, MERGE, PATCH).transpose(1, 4, 2, 5, 0, 3, 6)
    p = np.broadcast_to(p[:, :, :, :, :, None], (*p.shape[:5], TEMPORAL, *p.shape[5:]))
    return np.ascontiguousarray(p).reshape(rows * cols, 3 * TEMPORAL * PATCH * PATCH), (rows, cols)


def audio_features(samples: np.ndarray, rate: int, mel_filters: np.ndarray) -> np.ndarray:
    """Whisper-style log-mel spectrum, (128, frames): 16 kHz, 400-sample Hann frames every 160 samples."""
    audio = np.asarray(samples, dtype=np.float32)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if rate != AUDIO_RATE:
        import librosa
        audio = librosa.resample(audio, orig_sr=rate, target_sr=AUDIO_RATE)
    padded = np.pad(audio.astype(np.float64), N_FFT // 2, mode="reflect")
    count = 1 + (len(padded) - N_FFT) // HOP
    frames = np.lib.stride_tricks.as_strided(padded, (count, N_FFT), (padded.strides[0] * HOP, padded.strides[0]))
    window = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT)               # periodic Hann
    power = np.abs(np.fft.rfft(frames * window, axis=1)) ** 2                      # (frames, 201)
    mel = np.log10(np.maximum(mel_filters.T.astype(np.float64) @ power.T, 1e-10))[:, :-1]
    mel = np.maximum(mel, mel.max() - 8.0)
    return ((mel + 4.0) / 4.0).astype(np.float32)


# MARK: - Positions

def vision_positions(pos_table: np.ndarray, rows: int, cols: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """The photo part's inputs that depend on the grid: interpolated position embeddings (patches, 1024) and the
    2-D rotation cos/sin (patches, 64), in merge-block order."""
    side = int(round(math.sqrt(pos_table.shape[0])))
    hs, ws = np.linspace(0, side - 1, rows, dtype=np.float32), np.linspace(0, side - 1, cols, dtype=np.float32)
    h0, w0 = hs.astype(np.int64), ws.astype(np.int64)
    h1, w1 = np.minimum(h0 + 1, side - 1), np.minimum(w0 + 1, side - 1)
    dh, dw = (hs - h0)[:, None], (ws - w0)[None, :]
    table = pos_table.astype(np.float32)
    pos = (table[(h0[:, None] * side + w0[None, :])] * ((1 - dh) * (1 - dw))[..., None]
           + table[(h0[:, None] * side + w1[None, :])] * ((1 - dh) * dw)[..., None]
           + table[(h1[:, None] * side + w0[None, :])] * (dh * (1 - dw))[..., None]
           + table[(h1[:, None] * side + w1[None, :])] * (dh * dw)[..., None])          # (rows, cols, 1024)
    pos = pos.reshape(rows // MERGE, MERGE, cols // MERGE, MERGE, -1).transpose(0, 2, 1, 3, 4).reshape(rows * cols, -1)
    r = (np.arange(rows // MERGE)[:, None, None, None] * MERGE + np.arange(MERGE)[None, None, :, None])
    c = (np.arange(cols // MERGE)[None, :, None, None] * MERGE + np.arange(MERGE)[None, None, None, :])
    r = np.broadcast_to(r, (rows // MERGE, cols // MERGE, MERGE, MERGE)).reshape(-1)
    c = np.broadcast_to(c, (rows // MERGE, cols // MERGE, MERGE, MERGE)).reshape(-1)
    dim = 32                                                                            # half the 64-wide heads
    inverse = 1.0 / (10000.0 ** (np.arange(0, dim, 2, dtype=np.float32) / dim))
    angles = np.concatenate([r[:, None] * inverse, c[:, None] * inverse], axis=1)       # (patches, 32)
    angles = np.concatenate([angles, angles], axis=1)                                  # (patches, 64)
    return pos.astype(np.float32), np.cos(angles).astype(np.float32), np.sin(angles).astype(np.float32)


def text_rotation(positions: np.ndarray, theta: float, sections: tuple[int, int, int] = (24, 20, 20)) -> tuple[np.ndarray, np.ndarray]:
    """cos/sin (tokens, 128) for 3-D positions (3, tokens): time, row, column frequencies interleaved, as the model does."""
    inverse = 1.0 / (theta ** (np.arange(0, HEAD_DIM, 2, dtype=np.float64) / HEAD_DIM))  # 64 frequencies
    freqs = positions[:, :, None].astype(np.float64) * inverse[None, None, :]             # (3, tokens, 64)
    mixed = freqs[0].copy()
    for axis, offset in ((1, 1), (2, 2)):
        span = slice(offset, sections[axis] * 3, 3)
        mixed[:, span] = freqs[axis][:, span]
    angles = np.concatenate([mixed, mixed], axis=1)
    return np.cos(angles).astype(np.float32), np.sin(angles).astype(np.float32)


def photo_positions(ids: np.ndarray, image_token: int, grid: tuple[int, int]) -> np.ndarray:
    """3-D positions (3, tokens) for one photo's sequence: text counts up, photo tokens use (start, row, column)."""
    rows, cols = grid[0] // MERGE, grid[1] // MERGE
    where = np.flatnonzero(ids == image_token)
    first, count = int(where[0]), len(where)
    out = np.zeros((3, len(ids)), np.int64)
    out[:, :first] = np.arange(first)
    r, c = np.meshgrid(np.arange(rows), np.arange(cols), indexing="ij")
    out[0, first:first + count] = first
    out[1, first:first + count] = first + r.reshape(-1)
    out[2, first:first + count] = first + c.reshape(-1)
    after = first + count
    out[:, after:] = out[:, first:after].max() + 1 + np.arange(len(ids) - after)
    return out


# MARK: - The model

class OmniModel:
    """The Core ML model in `folder` (as published): compiled once on this Mac, then run on the Neural Engine."""

    def __init__(self, folder: Path, progress: Callable[[str, float, float], None] | None = None):
        """progress(part, done, share) is called before each part loads: the fraction already done, and this part's
        share of the whole. The first load on a Mac builds each part for its Neural Engine, which takes minutes."""
        import coremltools as ct
        from tokenizers import Tokenizer
        self.folder = Path(folder)
        self.manifest = json.loads((self.folder / "omni.json").read_text())
        self.tokenizer = Tokenizer.from_file(str(self.folder / "tokenizer.json"))
        self.table = np.load(self.folder / "embeddings.npy", mmap_mode="r")            # (vocab, 2048) float16
        self.pos_table = np.load(self.folder / "vision_positions.npy")
        self.mel_filters = np.load(self.folder / "mel_filters.npy")
        self.theta = float(self.manifest["ropeTheta"])
        self.tokens = self.manifest["tokens"]
        compiled = self.folder / "compiled"
        units = ct.ComputeUnit.CPU_AND_NE

        def load(name: str, function: str | None = None):
            package, target = self.folder / f"{name}.mlpackage", compiled / f"{name}.mlmodelc"
            if not target.exists():
                # Each part is kept as soon as it compiles, so a quit midway resumes with the next one. The rename
                # is atomic, so a part cut off mid-compile is never mistaken for a finished one.
                compiled.mkdir(exist_ok=True)
                partial = compiled / f"{name}.partial.mlmodelc"
                shutil.rmtree(partial, ignore_errors=True)
                ct.models.utils.compile_model(str(package), str(partial))
                os.replace(partial, target)
            return ct.models.CompiledMLModel(str(target), compute_units=units, function_name=function)

        parts = ([("text_first", f"tokens{n}") for n in TEXT_SIZES] + [("text_last", f"tokens{n}") for n in TEXT_SIZES]
                 + [("vision", f"patches{n}") for n in VISION_SIZES] + [("audio", None)])
        # A part's build time grows with its weights, so each load's share of the wait follows its package size.
        sizes = {name: sum(f.stat().st_size for f in (self.folder / f"{name}.mlpackage").rglob("*") if f.is_file()) for name, _ in parts}
        total = sum(sizes[name] for name, _ in parts)
        loaded, done = {}, 0
        for name, function in parts:
            if progress:
                progress(name, done / total, sizes[name] / total)
            loaded[name, function] = load(name, function)
            done += sizes[name]
        self.text_first = {n: loaded["text_first", f"tokens{n}"] for n in TEXT_SIZES}
        self.text_last = {n: loaded["text_last", f"tokens{n}"] for n in TEXT_SIZES}
        self.vision = {n: loaded["vision", f"patches{n}"] for n in VISION_SIZES}
        self.audio = loaded["audio", None]

    # Tokens and sequences

    def text_ids(self, text: str) -> list[int]:
        return self.tokenizer.encode(f"{PROMPT}{text}{END}", add_special_tokens=False).ids

    def wrapped_ids(self, start: str, pad: str, count: int, end: str) -> np.ndarray:
        return np.asarray(self.tokenizer.encode(f"{PROMPT}{start}{pad * count}{end}{END}", add_special_tokens=False).ids)

    def _run(self, embeds: list[np.ndarray], positions: list[np.ndarray], deep: list[np.ndarray | None]) -> list[np.ndarray]:
        """Up to 8 sequences packed into one block; each attends only to itself and is mean-pooled separately."""
        total = sum(len(e) for e in embeds)
        seq = next(n for n in TEXT_SIZES if total <= n)
        x = np.zeros((1, HIDDEN, 1, seq), np.float16)
        cos = np.ones((1, HEAD_DIM, 1, seq), np.float16)
        sin = np.zeros((1, HEAD_DIM, 1, seq), np.float16)
        d0, d1 = np.zeros((1, HIDDEN, 1, seq), np.float16), np.zeros((1, HIDDEN, 1, seq), np.float16)
        segment = np.full(seq, -1)
        pool = np.zeros((1, seq, SEGMENTS), np.float16)
        offset = 0
        for slot, (e, p, d) in enumerate(zip(embeds, positions, deep)):
            n = len(e)
            x[0, :, 0, offset:offset + n] = e.T
            c, s = text_rotation(p, self.theta)
            cos[0, :, 0, offset:offset + n], sin[0, :, 0, offset:offset + n] = c.T, s.T
            if d is not None:                                                             # photo snapshots, (tokens, 2048)
                where, first, second = d
                d0[0, :, 0, offset + where] = first                                       # advanced indexing puts tokens first
                d1[0, :, 0, offset + where] = second
            segment[offset:offset + n] = slot
            pool[0, offset:offset + n, slot] = 1.0 / n
            offset += n
        mask = np.where((segment[:, None] == segment[None, :]) & (segment[:, None] >= 0), 0, -1e4).astype(np.float16)[None, :, None, :]
        feed = {"cos": cos, "sin": sin, "mask": mask}
        h = self.text_first[seq].predict({"x": x, **feed, "deep0": d0, "deep1": d1})["y"]
        y = self.text_last[seq].predict({"x": h, **feed, "weights": pool})["y"][0].astype(np.float32)
        return [y[:, slot] for slot in range(len(embeds))]

    # Inputs

    def encode_texts(self, texts: list[str]) -> list[np.ndarray]:
        ids = [self.text_ids(t) for t in texts]
        out: list[Any] = [None] * len(texts)
        # A text longer than the largest block is split into parts that are embedded alone and averaged.
        limit, prefix, suffix = TEXT_SIZES[-1], 3, 2
        parts: list[tuple[int, list[int]]] = []
        for index, row in enumerate(ids):
            if len(row) <= limit:
                parts.append((index, row))
                continue
            body, step = row[prefix:-suffix], limit - prefix - suffix
            for start in range(0, len(body), step):
                parts.append((index, row[:prefix] + body[start:start + step] + row[-suffix:]))
        runs: list[list] = []                                                             # first-fit decreasing
        for k in sorted(range(len(parts)), key=lambda k: -len(parts[k][1])):
            n = len(parts[k][1])
            for run in runs:
                if run[1] + n <= TEXT_SIZES[0] and len(run[0]) < SEGMENTS:
                    run[0].append(k); run[1] += n
                    break
            else:
                runs.append([[k], n])
        vectors: dict[int, list[np.ndarray]] = {}
        for members, _ in runs:
            rows = [np.asarray(parts[k][1]) for k in members]
            results = self._run([self.table[r].astype(np.float32) for r in rows],
                                [np.broadcast_to(np.arange(len(r)), (3, len(r))) for r in rows], [None] * len(rows))
            for k, v in zip(members, results):
                vectors.setdefault(parts[k][0], []).append(v)
        for index, found in vectors.items():
            out[index] = found[0] if len(found) == 1 else np.mean([v / np.linalg.norm(v) for v in found], axis=0)
        return out

    def encode_image(self, image: Any) -> np.ndarray:
        patches, grid = image_patches(resize_image(image))
        count = patches.shape[0]
        size = next(n for n in VISION_SIZES if count <= n)
        pos, cos, sin = vision_positions(self.pos_table, *grid)
        def layout(a, fill=0.0):
            out = np.full((1, a.shape[1], 1, size), fill, np.float16)
            out[0, :, 0, :count] = a.T
            return out
        keymask = np.full((1, size, 1, 1), -1e4, np.float16); keymask[0, :count] = 0
        out = self.vision[size].predict({"patches": layout(patches), "pos": layout(pos), "cos": layout(cos, 1.0),
                                         "sin": layout(sin), "keymask": keymask})
        m = count // 4
        merged, d8, d16 = (out[k][0, :, 0, :m].T.astype(np.float32) for k in ("merged", "deep8", "deep16"))
        ids = self.wrapped_ids("<|vision_start|>", "<|image_pad|>", m, "<|vision_end|>")
        embeds = self.table[ids].astype(np.float32)
        where = np.flatnonzero(ids == self.tokens["image"])
        embeds[where] = merged
        return self._run([embeds], [photo_positions(ids, self.tokens["image"], grid)], [(where, d8, d16)])[0]

    def encode_audio(self, samples: np.ndarray, rate: int) -> np.ndarray:
        features = audio_features(samples, rate, self.mel_filters)
        window = AUDIO_SECONDS * AUDIO_RATE // HOP
        parts = [features[:, s:s + window] for s in range(0, max(features.shape[1], 1), window)]
        found = [self._audio_window(p) for p in parts if p.shape[1] > 0]
        if not found:
            raise ValueError("This recording is too short to read.")
        return found[0] if len(found) == 1 else np.mean([v / np.linalg.norm(v) for v in found], axis=0)

    def _audio_window(self, features: np.ndarray) -> np.ndarray:
        frames = features.shape[1]
        mel = np.zeros((AUDIO_CHUNKS, 1, features.shape[0], AUDIO_FRAMES), np.float16)
        count = 0
        for c in range((frames + AUDIO_FRAMES - 1) // AUDIO_FRAMES):
            part = features[:, c * AUDIO_FRAMES:(c + 1) * AUDIO_FRAMES]
            mel[c, 0, :, :part.shape[1]] = part
            n = part.shape[1]
            for _ in range(3):
                n = (n - 1) // 2 + 1
            count += n
        keymask = np.where(np.arange(AUDIO_SEQ) < count, 0, -1e4).astype(np.float16).reshape(1, AUDIO_SEQ, 1, 1)
        tokens = self.audio.predict({"mel": mel, "keymask": keymask})["audio"][0, :, 0, :count].T.astype(np.float32)
        ids = self.wrapped_ids("<|audio_start|>", "<|audio_pad|>", count, "<|audio_end|>")
        embeds = self.table[ids].astype(np.float32)
        embeds[ids == self.tokens["audio"]] = tokens
        return self._run([embeds], [np.broadcast_to(np.arange(len(ids)), (3, len(ids)))], [None])[0]

    # Check

    def self_check(self) -> float:
        """Embeds the published samples and returns the lowest agreement with the PyTorch model's vectors for them."""
        from PIL import Image
        check = self.manifest["check"]
        found = self.encode_texts(check["texts"])
        found += [self.encode_image(Image.open(self.folder / path)) for path in check["images"]]
        found.append(self.encode_audio(np.load(self.folder / check["audio"]), AUDIO_RATE))
        want = np.load(self.folder / check["vectors"]).astype(np.float64)
        got = np.asarray(found, np.float64)
        got /= np.linalg.norm(got, axis=1, keepdims=True)
        return float((got * want).sum(1).min())
