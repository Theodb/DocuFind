#!/usr/bin/env python3
"""Local-only BidirLM retrieval worker. Stdout is exclusively JSON lines.

Heavy inference dependencies are deliberately lazy: status and folder settings
work before setup and never download weights. Run worker.py for the protocol.
"""
from __future__ import annotations

from array import array
from contextlib import contextmanager
from dataclasses import dataclass
from hashlib import sha256
import heapq
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable, Iterable, Iterator, Protocol

import indexing_rules
import model_download
from ocr import recognizer
from text_index import ExactQuery, TextIndex, excerpt

MODEL_ID = model_download.MODEL_ID
MODEL_REVISION = model_download.MODEL_REVISION
INDEX_VERSION = "2"
# Photos are embedded at this longest side: omni_coreml.IMAGE_SIDE, where the model resizes them once. Each photo
# records its size, so changing this re-embeds photos only, not text. (omni_coreml needs NumPy, so it loads lazily.)
IMAGE_SIZE = 768
# Increment when the published Core ML conversion changes its numbers.
CONVERSION_VERSION = 1
# Increment when text extraction changes (2: HTML is read as the text a browser shows, and passages
# that aren't language are skipped). Older text entries are read again once.
TEXT_VERSION = 2
HTML_EXTENSIONS = frozenset({".html", ".htm"})  # Increment when chunking, model, or embedding semantics change.
# Vectors from the Neural Engine model. Earlier versions' vectors (other keys) are embedded again once.
MODEL_KEY = f"{MODEL_ID}@coreml-{CONVERSION_VERSION}:{INDEX_VERSION}"
# JSON is machine data (settings, exports, results), rarely something to find by meaning; it is skipped.
# Source code and tabular data can be turned on in Library → File Types; they are off by default.
# Configuration files count as code and logs as data: both are off unless their File Types switch is on.
CODE_EXTENSIONS = frozenset(".py .swift .js .ts .jsx .tsx .css .c .h .cpp .hpp .java .go .rs .sh .sql .yaml .yml .toml .xml".split())
DATA_EXTENSIONS = frozenset(".csv .tsv .log".split())
FILE_TYPES = {"code": CODE_EXTENSIONS, "data": DATA_EXTENSIONS}
TEXT_EXTENSIONS = frozenset(".txt .md .markdown .rst .html .htm .tex .rtf".split()) | CODE_EXTENSIONS | DATA_EXTENSIONS
IMAGE_EXTENSIONS = frozenset(".jpg .jpeg .png .webp .gif .bmp .tif .tiff .heic .heif".split())
AUDIO_EXTENSIONS = frozenset(".wav .wave .mp3 .flac .ogg .aiff .aif .m4a .aac .caf .opus".split())
EXCLUDED_DIRECTORIES = frozenset(".git .hg .svn .venv venv env node_modules __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox .nox .cache .Trash .Trashes .Spotlight-V100 .fseventsd .DocumentRevisions-V100 .TemporaryItems .ssh .aws .gnupg .azure .kube .docker .npm .cargo .rustup .gradle .m2 .terraform .conda .local".split())
# Folders macOS shows as single documents: their insides are an app's working files, not the user's.
PACKAGE_SUFFIXES = (".app", ".bundle", ".framework", ".photoslibrary", ".photolibrary", ".xcassets", ".git",
                    ".logicx", ".band", ".xcodeproj", ".xcworkspace", ".pages", ".numbers", ".key")
DEPENDENCIES = {"numpy": "numpy", "PIL": "Pillow", "soundfile": "soundfile", "librosa": "librosa", "pypdf": "pypdf",
                "coremltools": "coremltools", "tokenizers": "tokenizers", "huggingface_hub": "huggingface_hub"}


class UserError(Exception):
    """An actionable failure suitable for the app's error display."""


class ModelError(UserError):
    pass


class Cancelled(Exception):
    pass


class Encoder(Protocol):
    loaded: bool
    device: str
    def encode(self, inputs: list[Any]) -> list[list[float]]: ...


def normalized(vector: Iterable[float]) -> list[float]:
    values = [float(v) for v in vector]
    norm = math.sqrt(sum(v * v for v in values))
    if not values or not math.isfinite(norm) or norm <= 0:
        raise ModelError("The model returned an invalid embedding. Index again; if it keeps happening, reinstall the runtime in Settings.")
    return [v / norm for v in values]


def within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def missing_dependencies() -> list[str]:
    return [package for module, package in DEPENDENCIES.items() if importlib.util.find_spec(module) is None]


def neural_engine_available() -> tuple[bool, str]:
    """The model runs on the Neural Engine through Core ML: Apple silicon with macOS 15 or later."""
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        return False, "DocuFind needs a Mac with Apple silicon."
    try:
        major = int(platform.mac_ver()[0].split(".")[0])
    except ValueError:
        major = 0
    if major < 15:
        return False, "DocuFind needs macOS 15 or later on Apple silicon."
    return True, ""


def normalized_rows(result: Any, expected: int) -> list[list[float]]:
    """Validate and normalize once."""
    import numpy as np
    values = np.asarray(result, dtype=np.float32)
    if values.ndim != 2 or values.shape[0] != expected or values.shape[1] == 0:
        raise ValueError("The model returned an unexpected number or shape of embeddings.")
    if not np.isfinite(values).all():
        raise ValueError("The model returned non-finite embeddings. Try again; if it keeps happening, reinstall the model in Settings.")
    lengths = np.linalg.norm(values, axis=1, keepdims=True)
    if not np.isfinite(lengths).all() or (lengths <= 0).any():
        raise ValueError("The model returned invalid embedding lengths. Try again; if it keeps happening, reinstall the model in Settings.")
    return (values / lengths).tolist()


def model_prepared(cache: Path) -> bool:
    """Compiled for this Mac and checked, so loading takes seconds."""
    folder = model_download.folder(cache)
    return (folder / "compiled").is_dir() and (folder / f".checked-{model_download.REVISION}").is_file()


class Preparation:
    """The model's first preparation on a Mac, step by step, for the setup bar.

    Each step reports where it starts, its share of the whole and the pace so far (seconds for a whole preparation).
    The app fills the step's share over the time that pace gives it, holding just short of its end until the next
    step begins. The filling happens in the app: while Core ML builds a part it holds Python's lock, so nothing here
    could report in the middle of a step. The first step assumes a typical pace; later ones use this Mac's own.
    """
    SECONDS = 500.0                   # a whole first preparation, about 8 to 9 minutes on an M4
    LABELS = {"text_first": "text", "text_last": "text", "vision": "photos", "audio": "recordings", "check": "checking it"}

    def __init__(self, report: Callable[[float, float, float, str], None]):
        self.report = report
        self.began, self.pace = time.monotonic(), self.SECONDS

    def step(self, part: str, start: float, share: float) -> None:
        if start > 0:
            self.pace = (time.monotonic() - self.began) / start      # seconds per whole preparation, as measured so far
        self.report(start, share, self.pace, self.LABELS.get(part, part))


class CoreMLEncoder:
    """BidirLM-Omni on the Neural Engine (omni_coreml), downloaded once and checked on this Mac before its first use."""

    device = "ane"

    def __init__(self, device: str, cache: Path, progress: Callable[[dict], None]):
        self.cache = cache
        self.progress = progress
        self.loaded = False
        self.model = None
        self._calls = 0
        self._inputs = 0
        self._seconds = 0.0

    @property
    def folder(self) -> Path:
        return model_download.folder(self.cache)

    @property
    def model_key(self) -> str:
        return MODEL_KEY

    @property
    def check_marker(self) -> Path:
        return self.folder / f".checked-{model_download.REVISION}"

    def batch_size_for(self, kind: str) -> int:
        # Texts are packed into shared Neural Engine runs; photos and recordings run one at a time.
        return {"text": 32}.get(kind, 1)

    def profile(self) -> dict:
        return {"device": self.device, "modelKey": self.model_key, "loaded": self.loaded, "calls": self._calls,
                "inputs": self._inputs, "seconds": round(self._seconds, 4),
                "itemsPerSecond": round(self._inputs / self._seconds, 3) if self._seconds else None}

    def download(self) -> None:
        """Fetches the model once, before its first load, reporting the bytes received."""
        def report(received: int, total: int) -> None:
            self.progress({"stage": "download", "progress": received / total, "receivedBytes": received, "totalBytes": total,
                           "message": f"Downloading the search model, {received / 1e9:.1f} of {total / 1e9:.1f} GB. Your files stay on this Mac."})
        try:
            model_download.download(self.cache, report)
        except Exception as exc:
            raise ModelError(f"Could not download the search model: {exc}. Check your internet connection and free disk space, then try again.") from exc

    def load(self) -> None:
        if self.loaded:
            return
        supported, reason = neural_engine_available()
        if not supported:
            raise ModelError(reason)
        missing = missing_dependencies()
        if missing:
            raise ModelError("Python dependencies are missing: " + ", ".join(missing) + ". Run backend/setup.sh once, then restart DocuFind.")
        if not model_download.verified(self.cache):
            try:
                if not model_download.downloaded(self.cache):
                    raise OSError("not downloaded")
                model_download.verify(self.cache)
            except OSError:
                self.download()
        # Core ML compiles the model for this Mac the first time, which takes a few minutes.
        first = not (self.folder / "compiled").is_dir()
        self.progress({"stage": "model", "message": "Optimizing the search model for your Mac's chip, once. This takes a few minutes…" if first else "Loading the search model…"})
        checking = not self.check_marker.is_file()
        # The self-check takes seconds; the parts share the rest of the bar.
        loads = 0.98 if checking else 1.0

        def report(fraction: float, share: float, pace: float, label: str) -> None:
            self.progress({"stage": "model", "progress": round(fraction, 4), "share": round(share, 4), "pace": round(pace, 1), "part": label,
                           "message": f"Optimizing the search model for your Mac's chip, once: {label}…" if first
                           else "Loading the search model…"})
        try:
            import omni_coreml
            preparation = Preparation(report)
            model = omni_coreml.OmniModel(self.folder, lambda part, done, share: preparation.step(part, done * loads, share * loads))
            # The first load on this Mac compares the published samples with the PyTorch model's vectors for them.
            if checking:
                preparation.step("check", loads, 1 - loads)
                agreement = model.self_check()
            if checking:
                minimum = float(model.manifest["check"]["minimumAgreement"])
                if agreement < minimum:
                    raise ModelError(f"The search model's results on this Mac differ from the published ones (agreement {agreement:.4f}, "
                                     f"{minimum} needed). Reinstall the model in Settings.")
                self.check_marker.write_text(json.dumps({"agreement": round(agreement, 6)}) + "\n")
                report(1.0, 0.0, preparation.pace, "ready")
        except UserError:
            raise
        except Exception as exc:
            raise ModelError(f"Could not load the search model on the Neural Engine: {exc}. Check the setup installation and free disk space.") from exc
        self.model = model
        self.loaded = True

    def tokenize(self, texts: list[str]) -> list[list[int]]:
        """The exact token ids the model receives for each text, without padding."""
        self.load()
        return [self.model.text_ids(text) for text in texts]

    def encode(self, inputs: list[Any]) -> list[list[float]]:
        if not inputs:
            return []
        self.load()
        import time
        started = time.perf_counter()
        try:
            result: list[Any] = [None] * len(inputs)
            # Texts go together, so they can share packed runs; photos and recordings go one by one.
            texts = [index for index, value in enumerate(inputs) if isinstance(value, str)]
            if texts:
                for index, vector in zip(texts, self.model.encode_texts([inputs[i] for i in texts])):
                    result[index] = vector
            for index, value in enumerate(inputs):
                if isinstance(value, str):
                    continue
                if isinstance(value, dict) and "array" in value:
                    result[index] = self.model.encode_audio(value["array"], int(value.get("sampling_rate") or 16000))
                else:
                    result[index] = self.model.encode_image(value)
            vectors = normalized_rows(result, len(inputs))
        except UserError:
            raise
        except Exception as exc:
            raise ModelError(f"The search model failed on the Neural Engine: {exc}") from exc
        self._seconds += time.perf_counter() - started
        self._calls += 1
        self._inputs += len(inputs)
        return vectors

    def unload(self) -> None:
        self.model = None
        self.loaded = False


@dataclass
class Chunk:
    payload: Any
    snippet: str
    location: str
    # Words to match as written; text chunks use their payload.
    text: str | None = None

    @property
    def words(self) -> str:
        return self.text if self.text is not None else (self.payload if isinstance(self.payload, str) else "")


def split_text(text: str, size: int = 1800, overlap: int = 250) -> Iterator[tuple[str, int]]:
    """Boundary-aware, overlapping text chunks with original character offsets."""
    if not (0 <= overlap < size):
        raise ValueError("Chunk overlap must be smaller than size")
    start = 0
    while start < len(text):
        end = min(start + size, len(text))
        if end < len(text):
            boundary = max(text.rfind("\n", start + size // 2, end), text.rfind(" ", start + size // 2, end))
            if boundary > start:
                end = boundary
        content = text[start:end].strip()
        if content:
            yield content, start
        if end == len(text):
            break
        start = max(start + 1, end - overlap)


def text_file_chunks(path: Path) -> Iterator[Chunk]:
    with path.open("rb") as sample:
        if b"\x00" in sample.read(8192):
            raise UserError("File contains binary data rather than UTF-8 text.")
    # A bounded rolling buffer avoids reading arbitrarily large logs into RAM.
    with path.open("r", encoding="utf-8-sig", errors="replace") as stream:
        buffer, base = "", 0
        while True:
            block = stream.read(32768)
            buffer += block
            final = not block
            while len(buffer) >= 3600 or (final and buffer):
                end = min(1800, len(buffer))
                if end < len(buffer):
                    boundary = max(buffer.rfind("\n", 900, end), buffer.rfind(" ", 900, end))
                    if boundary > 0:
                        end = boundary
                content = buffer[:end].strip()
                if content:
                    yield Chunk(content, " ".join(content.split())[:280], f"Character {base + 1}")
                if end == len(buffer):
                    buffer = ""
                    break
                consumed = max(1, end - 250)
                buffer, base = buffer[consumed:], base + consumed
            if final:
                break


def html_text(path: Path, limit: int = 8 * 1024 * 1024) -> str:
    """The text a browser shows: no tags, scripts, styles, drawings or template syntax."""
    from html.parser import HTMLParser

    hidden = {"script", "style", "svg", "noscript", "template", "head", "math", "canvas", "iframe"}
    blocks = {"p", "div", "br", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article",
              "header", "footer", "blockquote", "pre", "title", "dt", "dd", "figcaption", "table", "ul", "ol"}

    class Reader(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.parts: list[str] = []
            self.skipping = 0
            self.title: list[str] = []
            self.in_title = False

        def handle_starttag(self, tag, attrs):
            if tag == "title":
                self.in_title = True
            elif tag in hidden:
                self.skipping += 1
            elif tag in blocks:
                self.parts.append("\n")

        def handle_endtag(self, tag):
            if tag == "title":
                self.in_title = False
            elif tag in hidden:
                self.skipping = max(0, self.skipping - 1)
            elif tag in blocks:
                self.parts.append("\n")

        def handle_data(self, data):
            if self.in_title:
                self.title.append(data)
            elif not self.skipping:
                self.parts.append(data)

    with path.open("rb") as stream:
        raw = stream.read(limit)
    if b"\x00" in raw[:8192]:
        raise UserError("File contains binary data rather than HTML text.")
    source = raw.decode("utf-8", errors="replace")
    # Go, Hugo, Jinja and similar template directives are code, not page text.
    source = re.sub(r"\{\{.*?\}\}|\{%.*?%\}|\{#.*?#\}|<%.*?%>", " ", source, flags=re.S)
    reader = Reader()
    reader.feed(source)
    reader.close()
    title = " ".join("".join(reader.title).split())
    body = re.sub(r"[ \t\r\f\v]+", " ", "".join(reader.parts))
    body = re.sub(r"\n\s*\n+", "\n\n", body).strip()
    return (title + "\n\n" + body).strip() if title and title not in body[:len(title) + 50] else body


def passage_windows(text: str, size: int = 360) -> list[tuple[int, str]]:
    """A passage cut at sentence and line ends into pieces of about `size` characters, with their offsets."""
    pieces, start = [], 0
    units = [m for m in re.finditer(r".+?(?:[.!?…](?=\s)|\n|$)", text, re.S)]
    current, current_start = "", 0
    for unit in units:
        piece = unit.group(0)
        if not piece.strip():
            continue
        if current and len(current) + len(piece) > size:
            pieces.append((current_start, current.strip()))
            current, current_start = "", unit.start()
        if not current:
            current_start = unit.start()
        current += piece
    if current.strip():
        pieces.append((current_start, current.strip()))
    return pieces


def shifted_location(location: str, offset: int) -> str:
    """'Character 1545' (or 'Page 3, character 120') moved forward by offset characters."""
    match = re.search(r"([Cc]haracter )(\d+)", location or "")
    if not match:
        return location
    return location[:match.start(2)] + str(int(match.group(2)) + offset) + location[match.end(2):]


def looks_like_language(text: str) -> bool:
    """Whether a passage reads as words rather than data: drawing coordinates, encoded blobs or number dumps.

    Simple ratios in the spirit of the Gopher and FineWeb text filters: enough letters among the
    characters, and words of ordinary length. A short passage passes if it holds a few letters, so a
    template reduced to a lone "|" is dropped: its near-empty meaning would match every query.
    """
    characters = [c for c in text if not c.isspace()]
    if len(characters) < 40:
        return sum(c.isalpha() for c in characters) >= 3
    letters = sum(c.isalpha() for c in characters)
    if letters / len(characters) < 0.45:
        return False
    words = text.split()
    # Records like JSON lines: many "key": pairs among few words.
    if len(re.findall(r'"\s*:', text)) / max(1, len(words)) > 0.08:
        return False
    return sum(len(word) for word in words) / len(words) <= 25


def short_passage_penalty(kind: str, snippet: str | None) -> float:
    """A few words carry little meaning and land close to every query; such passages rank a little lower."""
    return 0.05 if kind == "text" and len((snippet or "").strip()) < 60 else 0.0


# Bumped whenever the rules for what is indexed change (file types, packages, machine-made checks), so the next
# configure re-checks the index once.
SCOPE_RULES_VERSION = 2

SF_DATALESS = 0x40000000


def is_cloud_only(stat) -> bool:
    """A file kept only in iCloud (its contents not on this Mac): reading it would start a download."""
    return bool(getattr(stat, "st_flags", 0) & SF_DATALESS)


def kind_for(path: Path) -> str | None:
    suffix = path.suffix.lower()
    if suffix in TEXT_EXTENSIONS or suffix == ".pdf":
        return "text"
    if suffix in IMAGE_EXTENSIONS:
        return "image"
    if suffix in AUDIO_EXTENSIONS:
        return "audio"
    return None


def audio_spans(frames: int, sample_rate: int, seconds: int = 30, overlap: int = 5) -> Iterator[tuple[int, int]]:
    size, step = sample_rate * seconds, sample_rate * (seconds - overlap)
    if sample_rate <= 0 or seconds <= overlap or overlap < 0:
        raise ValueError("Invalid audio window")
    for start in range(0, frames, step):
        end = min(start + size, frames)
        yield start, end
        if end == frames:
            break


# Formats whose seeks decode from the start of the file: read in one pass instead.
SLOW_SEEK_AUDIO = frozenset({".ogg", ".oga", ".opus"})


@contextmanager
def readable_audio(path: Path):
    import soundfile as sf
    try:
        audio = sf.SoundFile(str(path))
    except Exception as original:
        # macOS AudioToolbox decodes AAC/M4A without loading the entire recording
        # into Python memory. The private temporary WAV is deleted afterwards.
        if not Path("/usr/bin/afconvert").exists():
            raise UserError(f"Cannot decode audio: {original}. WAV, FLAC, MP3 and AIFF work with libsndfile; AAC/M4A need macOS AudioToolbox.") from original
        with tempfile.TemporaryDirectory(prefix="docufind-audio-") as tmp:
            converted = Path(tmp) / "decoded.wav"
            result = subprocess.run(["/usr/bin/afconvert", str(path), str(converted), "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"], capture_output=True, text=True, timeout=900)
            if result.returncode:
                raise UserError(f"Cannot decode this audio file: {result.stderr.strip()[:400]}")
            with sf.SoundFile(str(converted)) as audio:
                yield audio
        return
    with audio:
        yield audio


def extract(path: Path, kind: str) -> Iterator[Chunk]:
    if kind == "text" and path.suffix.lower() == ".pdf":
        from pypdf import PdfReader
        reader = PdfReader(str(path))
        if reader.is_encrypted:
            raise UserError("Password-protected PDF; unlock it before indexing.")
        for number, page in enumerate(reader.pages, 1):
            text = page.extract_text() or ""
            if len(text.strip()) < 20:
                # A scanned page has no text layer; read its image instead.
                text = recognizer.pdf_page_text(path, number) or text
            for passage, offset in split_text(text):
                yield Chunk(passage, " ".join(passage.split())[:280], f"Page {number}, character {offset + 1}")
    elif kind == "text" and path.suffix.lower() in HTML_EXTENSIONS:
        text = html_text(path)
        for passage, offset in split_text(text):
            yield Chunk(passage, " ".join(passage.split())[:280], f"Character {offset + 1}")
    elif kind == "text":
        yield from text_file_chunks(path)
    elif kind == "image":
        from PIL import Image, ImageOps
        # HEIC/HEIF are decoded by macOS if Pillow lacks their codec.
        try:
            with Image.open(path) as source:
                image = ImageOps.exif_transpose(source).convert("RGB")
        except Exception:
            if path.suffix.lower() not in {".heic", ".heif"} or not Path("/usr/bin/sips").exists():
                raise
            with tempfile.TemporaryDirectory(prefix="docufind-image-") as tmp:
                # Uncompressed TIFF: the same pixels as PNG, five times faster to write and read.
                converted = Path(tmp) / "image.tiff"
                result = subprocess.run(["/usr/bin/sips", "-s", "format", "tiff", str(path), "--out", str(converted)], capture_output=True, text=True, timeout=120)
                if result.returncode:
                    raise UserError("This image could not be decoded by macOS.")
                with Image.open(converted) as source:
                    image = ImageOps.exif_transpose(source).convert("RGB")
        # The photo's own size, before it is shrunk for the model.
        width, height = image.size
        import omni_coreml
        # Shrunk here, once, so a photo read ahead holds a model-sized picture rather than the full one.
        image = omni_coreml.resize_image(image)
        # Text in screenshots and photos is matched as written; the picture itself is embedded.
        yield Chunk(image, f"Image · {width} × {height}", "Image", text=recognizer.image_text(path))
    elif kind == "audio":
        with readable_audio(path) as audio:
            sample_rate = audio.samplerate
            for start, end in audio_spans(len(audio), sample_rate):
                audio.seek(start)
                samples = audio.read(end - start, dtype="float32", always_2d=True).mean(axis=1)
                location = f"{start / sample_rate:.1f}–{end / sample_rate:.1f} seconds"
                yield Chunk({"array": samples, "sampling_rate": sample_rate}, f"Audio · {location}", location)


_PAGE = re.compile(r"^Page (\d+)")


def with_page(item: dict) -> dict:
    """Adds the PDF page a passage is on, so the app can open the file there."""
    match = _PAGE.match(item.get("location") or "")
    if match and item["path"].lower().endswith(".pdf"):
        item["page"] = int(match.group(1))
    return item


def large_folders(paths: list[Path], roots: list[Path], minimum: int = 2000, limit: int = 5) -> list[dict]:
    """The few folders that hold most of the files, as specific as possible.

    A folder is only suggested when its larger subfolders don't already account for
    most of it, so a projects folder full of datasets suggests the datasets instead.
    """
    counts: dict[Path, int] = {}
    for path in paths:
        root = next((root for root in roots if within(path, root)), None)
        if root is None:
            continue
        parts = path.relative_to(root).parts[:-1]
        for depth in range(1, min(len(parts), 5) + 1):
            folder = root.joinpath(*parts[:depth])
            counts[folder] = counts.get(folder, 0) + 1
    chosen: list[Path] = []
    for folder in sorted((f for f, n in counts.items() if n >= minimum), key=lambda f: -len(f.parts)):
        covered = sum(counts[c] for c in chosen if within(c, folder))
        if covered < 0.8 * counts[folder]:
            chosen.append(folder)
    chosen = [f for f in chosen if not any(other != f and within(other, f) for other in chosen)]
    chosen.sort(key=lambda f: -counts[f])
    return [{"path": str(f), "files": counts[f]} for f in chosen[:limit]]


def default_data_dir() -> Path:
    override = os.environ.get("DOCUFIND_DATA_DIR")
    if override:
        return Path(override).expanduser()
    support = Path.home() / "Library" / "Application Support"
    # The app was called Magnifind, and OmniFind before that; an existing folder from those names is used
    # until a DocuFind one exists.
    for name in ("DocuFind", "Magnifind", "OmniFind"):
        if (support / name).exists():
            return support / name
    return support / "DocuFind"


def _close(iterator) -> None:
    close = getattr(iterator, "close", None)
    if close:
        close()


class Lookahead:
    """Reads the next photos and recordings on background threads while the Neural Engine embeds the current file.

    Decoding, text recognition and resizing then overlap with inference instead of waiting their turn. Only files
    the plan expects to embed are read, in the order indexing visits them, and a read is used only if the file is
    unchanged since. Reads that indexing passes by (an unchanged file, a copy) are dropped and closed.
    """
    KINDS = ("image", "audio")
    DEPTH, WORKERS = 4, 2

    def __init__(self, paths: list[Path], read: Callable[[Path], tuple[list[Chunk], Iterator[Chunk]]]):
        from concurrent.futures import ThreadPoolExecutor
        self.paths, self.read = paths, read
        self.position = {str(path): index for index, path in enumerate(paths)}
        self.pool = ThreadPoolExecutor(self.WORKERS, thread_name_prefix="DocuFind read-ahead")
        self.queued: dict[str, Any] = {}
        self.next = 0
        self._fill()

    def _fill(self) -> None:
        while len(self.queued) < self.DEPTH and self.next < len(self.paths):
            path = self.paths[self.next]
            self.next += 1
            self.queued[str(path)] = self.pool.submit(self._read, path)

    def _read(self, path: Path):
        signature = Engine._stat_signature(path.stat())
        head, rest = self.read(path)
        return signature, head, rest

    @staticmethod
    def _drop(future) -> None:
        if not future.cancel():
            future.add_done_callback(lambda done: done.exception() is None and _close(done.result()[2]))

    def take(self, path: Path, stat) -> tuple[list[Chunk], Iterator[Chunk]] | None:
        """The file's first chunks and the rest of them, or None to read it now. A failed read raises its error."""
        index = self.position.get(str(path))
        if index is None:
            return None
        for name in [name for name in self.queued if self.position[name] < index]:
            self._drop(self.queued.pop(name))
        future = self.queued.pop(str(path), None)
        self.next = max(self.next, index + 1)
        self._fill()
        if future is None:
            return None
        signature, head, rest = future.result()
        if signature != Engine._stat_signature(stat):
            _close(rest)
            return None
        return head, rest

    def close(self) -> None:
        for future in self.queued.values():
            self._drop(future)
        self.queued.clear()
        self.pool.shutdown(wait=False, cancel_futures=True)


class Engine:
    def __init__(self, data_dir: Path | None = None, encoder_factory: Callable | None = None):
        self.data_dir = (data_dir or default_data_dir()).resolve()
        self.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db_path = self.data_dir / "index.sqlite3"
        self.db = sqlite3.connect(self.db_path, check_same_thread=False)
        os.chmod(self.db_path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA temp_store=FILE")  # Long-file staging may spill to private temporary disk.
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, kind TEXT NOT NULL, mtime INTEGER NOT NULL, size INTEGER NOT NULL, model_key TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS chunks(id TEXT PRIMARY KEY, path TEXT NOT NULL, position INTEGER NOT NULL, snippet TEXT NOT NULL, location TEXT NOT NULL, dimensions INTEGER NOT NULL, vector BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);
            CREATE TEMP TABLE staging(id TEXT PRIMARY KEY, path TEXT NOT NULL, position INTEGER NOT NULL, snippet TEXT NOT NULL, location TEXT NOT NULL, dimensions INTEGER NOT NULL, vector BLOB NOT NULL);
        """)
        self.db.commit()
        from file_reuse import FileReuse
        self.file_reuse = FileReuse(self.db, self.lock)
        self.texts = TextIndex(self.db)
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS image_sizes(path TEXT PRIMARY KEY, size INTEGER NOT NULL);
            CREATE TRIGGER IF NOT EXISTS image_sizes_files_delete AFTER DELETE ON files BEGIN
                DELETE FROM image_sizes WHERE path=OLD.path; END;
            CREATE TABLE IF NOT EXISTS text_versions(path TEXT PRIMARY KEY, version INTEGER NOT NULL);
            -- Files with nothing to index (blank, or no passage reads as language), until they change.
            CREATE TABLE IF NOT EXISTS empty_files(path TEXT PRIMARY KEY, mtime INTEGER NOT NULL, size INTEGER NOT NULL, version INTEGER NOT NULL);
            CREATE TRIGGER IF NOT EXISTS text_versions_files_delete AFTER DELETE ON files BEGIN
                DELETE FROM text_versions WHERE path=OLD.path; END;
        """)
        # Tables a development build created for a code index that no longer exists.
        self.db.executescript("""
            DROP TABLE IF EXISTS code_chunk_fts; DROP TABLE IF EXISTS code_chunk_texts; DROP TABLE IF EXISTS code_file_texts;
            DROP TABLE IF EXISTS code_symbols; DROP TABLE IF EXISTS code_chunks; DROP TABLE IF EXISTS code_files;
            DELETE FROM settings WHERE key='code_roots';
        """)
        self.roots = [Path(p) for p in self._setting("roots", [])]
        # Folders inside the chosen ones that are never read.
        self.skipped = [Path(p) for p in self._setting("skipped", [])]
        self.options = indexing_rules.options(self._setting("indexing_options", None))
        self.auto_skipped: dict[str, int] = {}
        self._folders = indexing_rules.FolderCache()
        self.file_types = {name: bool(value) for name, value in self._setting("file_types", {"code": False, "data": False}).items() if name in FILE_TYPES}
        self.large_folders: list[dict] = []
        self.encoder_factory = encoder_factory or CoreMLEncoder
        self.encoder: Encoder | None = None
        # Searches run while indexing; the model is used by one of them at a time.
        self.encoder_lock = threading.RLock()
        self.cancel_event = threading.Event()
        self.indexing = False
        self.last_error: str | None = None
        # Filters/limits do not change a query embedding. Keep a small in-memory
        # LRU only; query content is never saved to disk or diagnostic output.
        self._query_cache: dict[tuple, tuple[float, ...]] = {}
        # Refined snippets by (query, passage), oldest first.
        self._refine_cache: dict[tuple, dict] = {}
        # Content-free diagnostics for the last/current indexing operation.
        self.index_metrics: dict[str, Any] = {}

    def _setting(self, key: str, default: Any) -> Any:
        row = self.db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def _save_settings(self) -> None:
        for key, value in (("roots", [str(p) for p in self.roots]), ("skipped", [str(p) for p in self.skipped]),
                           ("file_types", self.file_types), ("indexing_options", self.options)):
            self.db.execute("INSERT OR REPLACE INTO settings VALUES (?,?)", (key, json.dumps(value)))
        self.db.commit()

    def _model_key(self) -> str:
        if self.encoder is not None and hasattr(self.encoder, "model_key"):
            return self.encoder.model_key
        return MODEL_KEY

    def _compatible_model_keys(self) -> tuple[str, ...]:
        """Vectors that can be compared with the current ones: only the current model's. Older vectors are embedded again."""
        return (self._model_key(),)

    def status(self) -> dict:
        model_keys = self._compatible_model_keys()
        placeholders = ",".join("?" for _ in model_keys)
        with self.lock:
            count = self.db.execute(f"SELECT COUNT(*) FROM files WHERE model_key IN ({placeholders})", model_keys).fetchone()[0]
            chunks = self.db.execute(f"SELECT COUNT(*) FROM chunks JOIN files USING(path) WHERE model_key IN ({placeholders})", model_keys).fetchone()[0]
            total = self.db.execute("SELECT COUNT(*) FROM files").fetchone()[0]
            kinds = {row[0]: row[1] for row in self.db.execute(f"SELECT kind, COUNT(*) FROM files WHERE model_key IN ({placeholders}) GROUP BY kind", model_keys)}
        real = self.encoder_factory is CoreMLEncoder
        missing = missing_dependencies() if real else []
        supported, reason = neural_engine_available() if real else (True, "")
        problem = reason if not supported else "Run backend/setup.sh, then restart DocuFind." if missing else None
        return {"indexingOptions": dict(self.options), "autoSkipped": dict(self.auto_skipped), "fileTypes": dict(self.file_types), "skipped": [str(p) for p in self.skipped], "largeFolders": list(self.large_folders),
                "ready": not missing and supported, "indexing": self.indexing, "indexedCount": count, "kindCounts": kinds, "chunkCount": chunks, "staleIndexCount": total - count, "compatibleModelKeys": list(model_keys), "roots": [str(p) for p in self.roots], "device": "ane", "model": MODEL_ID, "modelRevision": MODEL_REVISION, "modelReady": bool(self.encoder and self.encoder.loaded), "modelDownloaded": model_download.downloaded(self.data_dir / "models"), "modelPrepared": model_prepared(self.data_dir / "models"), "missingDependencies": missing, "indexMetrics": dict(self.index_metrics), "error": self.last_error or problem}

    def configure(self, roots: list[str], device: str = "auto", skipped: list[str] | None = None,
                  neural: bool | None = None, file_types: dict | None = None, options: dict | None = None) -> dict:
        # device and neural are accepted from older apps and ignored: the model always runs on the Neural Engine.
        if self.indexing:
            raise UserError("Stop indexing before changing folders.")
        if not isinstance(roots, list) or not all(isinstance(p, str) for p in roots):
            raise UserError("Folders must be a list of local paths.")
        clean = []
        for name in roots:
            path = Path(name).expanduser().resolve()
            if not path.is_dir():
                raise UserError(f"Folder does not exist or cannot be opened: {path}")
            if not any(within(path, root) for root in clean):
                clean = [root for root in clean if not within(root, path)]
                clean.append(path)
        if skipped is not None:
            if not isinstance(skipped, list) or not all(isinstance(p, str) for p in skipped):
                raise UserError("Skipped folders must be a list of local paths.")
            self.skipped = sorted({Path(p).expanduser().resolve() for p in skipped})
        if file_types is not None:
            if not isinstance(file_types, dict) or not all(name in FILE_TYPES and isinstance(on, bool) for name, on in file_types.items()):
                raise UserError("File types must map code and data to true or false.")
            self.file_types = {**self.file_types, **file_types}
        if options is not None:
            if not isinstance(options, dict) or not all(key in indexing_rules.DEFAULT_OPTIONS and isinstance(on, bool) for key, on in options.items()):
                raise UserError("Indexing options must be true or false.")
            self.options = indexing_rules.options({**self.options, **options})
            self._folders = indexing_rules.FolderCache()
        self.roots = clean
        with self.lock:
            # Re-checking every indexed file (listing folders to spot machine-made ones) is slow, so it happens only
            # when the folders, skipped folders, file types, options or the rules themselves changed.
            scope = json.dumps({"roots": [str(p) for p in clean], "skipped": [str(p) for p in self.skipped], "types": self.file_types,
                                "options": self.options, "rules": SCOPE_RULES_VERSION}, sort_keys=True)
            saved = self.db.execute("SELECT value FROM settings WHERE key='checked_scope'").fetchone()
            self._save_settings()
            removed: list[str] = []
            if saved is None or saved[0] != scope:
                removed = [row[0] for row in self.db.execute("SELECT path FROM files")
                           if not any(within(Path(row[0]), root) for root in clean) or any(within(Path(row[0]), skip) for skip in self.skipped)
                           or not self._readable_type(Path(row[0])) or self._machine_made(Path(row[0])) is not None]
                self._delete_paths(removed)
                self.db.execute("INSERT OR REPLACE INTO settings VALUES ('checked_scope', ?)", (scope,))
                self.db.commit()
        return {**self.status(), "deletedPaths": removed}

    def _release_encoder(self) -> None:
        # Detach first so repeated close/configure calls cannot unload twice.
        # Lightweight/custom encoders are allowed to omit this optional API.
        encoder, self.encoder = self.encoder, None
        self._query_cache.clear()
        self._refine_cache.clear()
        unload = getattr(encoder, "unload", None)
        if callable(unload):
            unload()

    def _delete_paths(self, paths: list[str]) -> None:
        self.db.executemany("DELETE FROM chunks WHERE path=?", ((p,) for p in paths))
        self.db.executemany("DELETE FROM files WHERE path=?", ((p,) for p in paths))
        self.db.commit()

    def remove_root(self, path: str) -> dict:
        target = Path(path).expanduser().resolve()
        return self.configure([str(p) for p in self.roots if p != target])

    def _check_cancel(self) -> None:
        if self.cancel_event.is_set():
            raise Cancelled()

    def _encoder(self, progress: Callable[[dict], None]) -> Encoder:
        with self.lock:
            if self.encoder is None:
                self.encoder = self.encoder_factory("ane", self.data_dir / "models", progress)
            elif isinstance(self.encoder, CoreMLEncoder):
                self.encoder.progress = progress
            return self.encoder

    @staticmethod
    def _batch_size(encoder: Encoder, kind: str) -> int:
        chooser = getattr(encoder, "batch_size_for", None)
        value = chooser(kind) if chooser else {"text": 4, "image": 2, "audio": 1}[kind]
        # Bound decoded payload memory even when a setting is accidentally huge.
        return max(1, min(int(value), {"text": 32, "image": 8, "audio": 2}[kind]))

    @staticmethod
    def _prefetched_chunks(source: Iterable[Chunk], capacity: int,
                           cancel: Callable[[], None]) -> Iterator[Chunk]:
        """Decode at most one batch ahead while the consumer runs inference.

        The producer owns and closes the extractor. Cancellation never closes a
        generator from another thread, and a full queue cannot prevent shutdown.
        A decoder already inside an OS call finishes privately before cleanup.
        """
        from queue import Empty, Full, Queue
        queue = Queue(maxsize=max(1, capacity))
        stop = threading.Event()
        finished = object()
        iterator = iter(source)

        def put(value):
            while not stop.is_set():
                try:
                    queue.put(value, timeout=0.05)
                    return
                except Full:
                    pass

        def produce():
            error = None
            try:
                while not stop.is_set():
                    try:
                        chunk = next(iterator)
                    except StopIteration:
                        break
                    if stop.is_set():
                        break
                    put((True, chunk))
            except Exception as exc:
                error = exc
            finally:
                try:
                    close = getattr(iterator, "close", None)
                    if close:
                        close()
                except Exception as exc:
                    error = error or exc
                if error is not None:
                    put((False, error))
                put(finished)

        producer = threading.Thread(target=produce, name="DocuFind extraction", daemon=True)
        producer.start()
        try:
            while True:
                cancel()
                try:
                    value = queue.get(timeout=0.05)
                except Empty:
                    continue
                if value is finished:
                    return
                success, chunk = value
                if not success:
                    raise chunk
                yield chunk
        finally:
            stop.set()
            # Most decoders finish immediately; bound the wait for a decoder
            # blocked in a platform subprocess or unavailable volume.
            producer.join(timeout=0.2)

    def _encoded_batches(self, path: Path, kind: str, encoder: Encoder,
                         cancel: Callable[[], None] = lambda: None,
                         source: Iterable[Chunk] | None = None,
                         encode_chunks: Callable[[list[Chunk]], list[list[float]]] | None = None):
        """Stream bounded homogeneous batches without retaining a whole file."""
        iterator = iter(extract(path, kind) if source is None else source)
        dimension = None
        batch_size = self._batch_size(encoder, kind)
        try:
            while True:
                chunks = []
                for _ in range(batch_size):
                    cancel()
                    try:
                        chunks.append(next(iterator))
                    except StopIteration:
                        break
                if not chunks:
                    return
                cancel()
                if encode_chunks:
                    vectors = encode_chunks(chunks)
                else:
                    with self.encoder_lock:
                        vectors = encoder.encode([chunk.payload for chunk in chunks])
                cancel()
                if len(vectors) != len(chunks):
                    raise ModelError("The model returned the wrong number of embeddings.")
                vectors = [normalized(vector) for vector in vectors]
                for vector in vectors:
                    if dimension is None:
                        dimension = len(vector)
                    elif len(vector) != dimension:
                        raise ModelError("The model returned inconsistent embedding dimensions.")
                yield chunks, vectors
        finally:
            close = getattr(iterator, "close", None)
            if close:
                close()

    def _clear_staging(self) -> None:
        with self.lock:
            self.db.rollback()
            self.db.execute("DELETE FROM staging")
            self.texts.clear_staging()
            self.db.commit()

    def _query_profile(self, encoder: Encoder) -> tuple:
        # The model key and optional declared dimensions all
        # participate; a different model cannot reuse stale vectors.
        return (self._model_key(), id(encoder),
                getattr(encoder, "dimensions", None),
                getattr(encoder, "embedding_dimension", None))

    def _cached_query(self, key: tuple) -> list[float] | None:
        value = self._query_cache.pop(key, None)
        if value is not None:
            self._query_cache[key] = value
            return list(value)
        return None

    def _remember_query(self, key: tuple, vector: list[float]) -> None:
        if len(vector) > 16384 or (key[1] == "text" and len(key[2]) > 65536):
            return  # Do not let arbitrary external query strings grow the LRU.
        self._query_cache.pop(key, None)
        self._query_cache[key] = tuple(vector)
        while len(self._query_cache) > 32:
            self._query_cache.pop(next(iter(self._query_cache)))

    @staticmethod
    def _stat_signature(stat) -> tuple:
        return (stat.st_dev, stat.st_ino, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size)

    @classmethod
    def _query_file_signature(cls, path: Path) -> tuple:
        return cls._stat_signature(path.stat())

    def _excluded(self, path: Path) -> bool:
        if within(path, self.data_dir) or any(within(path, skip) for skip in getattr(self, "skipped", [])):
            return True
        if any(part in EXCLUDED_DIRECTORIES or part.lower().endswith(PACKAGE_SUFFIXES) for part in path.parts):
            return True
        home = Path.home()
        # Library includes caches, credentials, application internals, and our
        # own model. Whole-home indexing still covers ordinary personal folders.
        excluded_roots = [home / "Library", Path("/System"), Path("/Library"), Path("/private"), Path("/usr"), Path("/bin"), Path("/sbin"), Path("/dev")]
        return any(within(path, root) for root in excluded_roots)

    def _skipped_below(self, path: Path) -> bool:
        """Whether a changed path lies outside the folders, or somewhere a full walk would not go."""
        root = next((root for root in self.roots if within(path, root)), None)
        if root is None or self._excluded(path):
            return True
        return any(part.startswith(".") or part in EXCLUDED_DIRECTORIES or part.lower().endswith(PACKAGE_SUFFIXES)
                   for part in path.relative_to(root).parts)

    def _machine_made(self, path: Path) -> str | None:
        """Why a file is skipped as machine-made (when that option is on), or None."""
        if not self.options["skipMachineFiles"]:
            return None
        root = next((root for root in self.roots if within(path, root)), None)
        return indexing_rules.machine_made(path, root, self._folders) if root is not None else None

    def _readable_type(self, path: Path) -> bool:
        """A supported file whose type is turned on."""
        if not kind_for(path):
            return False
        suffix = path.suffix.lower()
        return not any(suffix in extensions and not self.file_types.get(name, False) for name, extensions in FILE_TYPES.items())

    def _passages(self, path: Path, kind: str) -> Iterator[Chunk]:
        """A file's chunks. With the options on, text passages that aren't language are left out, and very
        long plain-text files stop at the passage limit (PDFs are always read in full)."""
        chunks = extract(path, kind)
        if kind != "text":
            yield from chunks
            return
        limit = self.options["limitLongFiles"] and path.suffix.lower() != ".pdf"
        filter_data = self.options["skipMachineFiles"]
        count = 0
        try:
            for chunk in chunks:
                if filter_data and not looks_like_language(chunk.words):
                    self.index_metrics["skippedPassages"] = self.index_metrics.get("skippedPassages", 0) + 1
                    continue
                if limit and count == indexing_rules.LONG_FILE_PASSAGES:
                    self.index_metrics["shortenedFiles"] = self.index_metrics.get("shortenedFiles", 0) + 1
                    return
                count += 1
                yield chunk
        finally:
            chunks.close()

    def refine(self, text: str, items: list[dict], progress: Callable[[dict], None] = lambda event: None) -> dict:
        """The part of each matched passage closest to the query, for its snippet and location.

        A passage is about 1,800 characters; a card shows 280. The passage is cut into sentence groups
        of a few hundred characters, those are embedded, and the closest one becomes the snippet.
        Runs after the results are shown, for the first few text results only.
        """
        import numpy as np
        query_text = (text or "").strip()
        if not query_text or not isinstance(items, list):
            return {"items": []}
        encoder = self._encoder(progress)
        key = (self._query_profile(encoder), "text", query_text)
        query = self._cached_query(key)
        if query is None:
            with self.encoder_lock:
                query = normalized(encoder.encode([query_text])[0])
            self._remember_query(key, query)
        jobs = []
        refined: list[dict] = []
        for item in items[:8]:
            if not isinstance(item, dict) or not isinstance(item.get("path"), str) or not isinstance(item.get("position"), int):
                continue
            with self.lock:
                row = self.db.execute("SELECT text FROM chunk_texts WHERE path=? AND position=?", (item["path"], item["position"])).fetchone()
                place = self.db.execute("SELECT location FROM chunks WHERE path=? AND position=?", (item["path"], item["position"])).fetchone()
            if row is None or len(row[0]) <= 320:
                continue
            # The same query on the same passage gives the same answer: kept, so repeating a search is instant.
            cache_key = (key, item["path"], item["position"], hash(row[0]))
            if cache_key in self._refine_cache:
                refined.append({"id": item.get("id"), "path": item["path"], "position": item["position"], **self._refine_cache[cache_key]})
                continue
            windows = passage_windows(row[0])
            if len(windows) > 1:
                jobs.append((item, windows, place[0] if place else "", cache_key))
        if not jobs:
            return {"items": refined}
        flat = [window for _, windows, _, _ in jobs for _, window in windows]
        with self.encoder_lock:
            vectors = np.asarray(encoder.encode(flat), dtype=np.float32)
        vectors /= np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-9)
        scores = vectors @ np.asarray(query, dtype=np.float32)
        index = 0
        for item, windows, location, cache_key in jobs:
            best = int(np.argmax(scores[index:index + len(windows)]))
            index += len(windows)
            offset, window = windows[best]
            snippet = " ".join(window.split())
            answer = {"snippet": snippet[:277] + "…" if len(snippet) > 280 else snippet, "location": shifted_location(location, offset)}
            self._refine_cache[cache_key] = answer
            while len(self._refine_cache) > 512:
                self._refine_cache.pop(next(iter(self._refine_cache)))
            refined.append({"id": item.get("id"), "path": item["path"], "position": item["position"], **answer})
        return {"items": refined}

    def _collapse_copies(self, items: list[dict]) -> list[dict]:
        """One result per content: byte-identical copies, whatever their names, fold into the best-ranked one.

        The result lists every other indexed copy in "copies", most recently changed first.
        """
        with self.lock:
            groups = self.file_reuse.copies([item["path"] for item in items])
            names = [item["path"] for item in items]
            sizes = dict(self.db.execute(f"SELECT path, size FROM files WHERE path IN ({','.join('?' for _ in names)})", names).fetchall()) if names else {}
        shown: list[dict] = []
        seen: set[str] = set()
        # Without fingerprints, files of the same size whose matching passage, place and score (an identical vector)
        # are the same hold the same content: those fold together too. Short passages are left apart, since unrelated
        # files can share a line like a heading.
        same: dict[tuple, dict] = {}
        for item in items:
            if item["path"] in seen:
                continue
            snippet = item.get("snippet") or ""
            key = (item["kind"], snippet, item.get("location"), round(float(item.get("score", 0)), 6), sizes.get(item["path"]))
            comparable = sizes.get(item["path"]) and (item["kind"] != "text" or len(snippet) >= 80)
            twin = same.get(key) if comparable else None
            if twin is not None:
                twin.setdefault("copies", [])
                if item["path"] not in twin["copies"]:
                    twin["copies"].append(item["path"])
                seen.add(item["path"])
                seen.update(groups.get(item["path"], []))
                continue
            copies = groups.get(item["path"], [])
            seen.update(copies)
            if copies:
                item["copies"] = list(copies)
            same[key] = item
            shown.append(item)
        return shown

    def _gone(self, path: Path) -> bool:
        """Whether an indexed file should leave the index: deleted, or still there but now excluded."""
        try:
            os.lstat(path)
        except (FileNotFoundError, NotADirectoryError):
            return True
        except OSError:
            return False  # No permission to look: keep it.
        if not any(within(path, root) for root in self.roots):
            return False  # Folder changes are handled by configure().
        return (self._skipped_below(path) or not self._readable_type(path) or path.is_symlink()
                or self._machine_made(path) is not None)

    def _walk(self, progress: Callable[[dict], None], inaccessible: list[Path],
              targets: list[Path] | None = None) -> Iterator[Path]:
        """Supported files in the chosen folders, or only in the changed paths given as targets."""
        def walk_error(exc: OSError):
            blocked = Path(exc.filename or "/")
            inaccessible.append(blocked)
            progress({"stage": "warning", "path": str(blocked), "message": "Cannot read this folder. Allow access in System Settings → Privacy & Security → Full Disk Access if you want it indexed."})
        if targets is not None:
            seen: set[Path] = set()
            for target in targets:
                self._check_cancel()
                if self._skipped_below(target) or target.is_symlink():
                    continue
                if target.is_file():
                    if self._readable_type(target) and target not in seen and self._machine_made(target) is None:
                        seen.add(target)
                        yield target
                elif target.is_dir():
                    for path in self._walk_tree(target, walk_error):
                        if path not in seen:
                            seen.add(path)
                            yield path
            return
        for root in self.roots:
            self._check_cancel()
            if not root.exists():
                inaccessible.append(root)
                progress({"stage": "warning", "path": str(root), "message": "Folder is unavailable; its existing index is retained. Reconnect the volume and index again."})
                continue
            yield from self._walk_tree(root, walk_error)

    def _walk_tree(self, root: Path, walk_error: Callable[[OSError], None]) -> Iterator[Path]:
        for directory, folders, files in os.walk(root, followlinks=False, onerror=walk_error):
            self._check_cancel()
            base = Path(directory)
            if self._excluded(base):
                folders[:] = []
                continue
            machine = self.options["skipMachineFiles"]
            if machine and (base.name.lower() in indexing_rules.FIXTURE_FOLDERS or self._folders.model_folder(base, files)):
                # A downloaded model or test fixtures: nothing below is written by a person.
                reason = "test fixtures" if base.name.lower() in indexing_rules.FIXTURE_FOLDERS else "model folders"
                self.auto_skipped[reason] = self.auto_skipped.get(reason, 0) + sum(1 for name in files if self._readable_type(base / name))
                folders[:] = []
                continue
            folders[:] = sorted(name for name in folders if name not in EXCLUDED_DIRECTORIES and not name.startswith(".") and not name.lower().endswith(PACKAGE_SUFFIXES) and not (base / name).is_symlink() and not self._excluded(base / name))
            for name in sorted(files):
                path = base / name
                # Extension filtering is pure string work. Avoid an extra
                # metadata read for every unsupported file in large trees.
                if name.startswith(".") or not self._readable_type(path) or path.is_symlink():
                    continue
                if machine and indexing_rules.machine_file(name):
                    self.auto_skipped["tokenizer files"] = self.auto_skipped.get("tokenizer files", 0) + 1
                    continue
                yield path

    def _current_images(self) -> set[str]:
        """Photos embedded at the current IMAGE_SIZE and texts read with the current TEXT_VERSION. Call under the lock."""
        return ({row[0] for row in self.db.execute("SELECT path FROM image_sizes WHERE size=?", (IMAGE_SIZE,))}
                | {row[0] for row in self.db.execute("SELECT path FROM text_versions WHERE version=?", (TEXT_VERSION,))})

    def _remember_image_size(self, name: str, kind: str) -> None:
        """Records how a file was read, so a later change to reading reads it again."""
        self.db.execute("DELETE FROM empty_files WHERE path=?", (name,))
        if kind == "image":
            self.db.execute("INSERT OR REPLACE INTO image_sizes VALUES (?,?)", (name, IMAGE_SIZE))
        elif kind == "text":
            self.db.execute("INSERT OR REPLACE INTO text_versions VALUES (?,?)", (name, TEXT_VERSION))

    def _needs_text(self, path: Path, current: set[str]) -> bool:
        """Indexed before words were kept; pictures wait until text recognition is available."""
        return str(path) not in current and (kind_for(path) != "image" or recognizer.available)

    def _plan_index(self, compatible_keys: tuple, targets: list[Path] | None = None,
                    progress: Callable[[dict], None] = lambda event: None, inaccessible: list[Path] | None = None) -> dict:
        """List supported files, most recently modified first, and count those that look new or changed.

        A metadata-only pass (no file contents). Recent files come first, so search is useful
        early in a long first pass. It also finds the folders that hold most of the files.
        """
        placeholders = ",".join("?" for _ in compatible_keys) or "''"
        with self.lock:
            known = {row[0]: (row[1], row[2]) for row in self.db.execute(
                f"SELECT path, mtime, size FROM files WHERE model_key IN ({placeholders})", compatible_keys)}
            current = self.texts.current_paths()
            images = self._current_images()
            empty = {row[0]: (row[1], row[2]) for row in self.db.execute("SELECT path, mtime, size FROM empty_files WHERE version=?", (TEXT_VERSION,))}
        found: list[tuple[int, Path]] = []
        likely: set[str] = set()
        if targets is None:
            self.auto_skipped = {}
            self._folders = indexing_rules.FolderCache()
        for path in self._walk(progress, inaccessible if inaccessible is not None else [], targets):
            self._check_cancel()
            try:
                stat = path.stat()
            except OSError:
                found.append((0, path))
                continue
            if is_cloud_only(stat):
                continue
            found.append((stat.st_mtime_ns, path))
            if empty.get(str(path)) == (stat.st_mtime_ns, stat.st_size):
                continue
            if (known.get(str(path)) != (stat.st_mtime_ns, stat.st_size) or self._needs_text(path, current)
                    or (kind_for(path) in ("image", "text") and str(path) not in images)):
                likely.add(str(path))
        if self.options["importantFirst"]:
            def key(entry):
                root = next((root for root in self.roots if within(entry[1], root)), entry[1].parent)
                return indexing_rules.priority(entry[1], root, entry[0])
            found.sort(key=key)
        else:
            found.sort(key=lambda entry: -entry[0])
        paths = [path for _, path in found]
        if targets is None:
            self.large_folders = large_folders(paths, self.roots)
        return {"total": len(paths), "toProcess": len(likely), "paths": paths, "likely": likely}

    def reserve_index(self) -> None:
        with self.lock:
            if self.indexing:
                raise UserError("Indexing is already running.")
            if not self.roots:
                raise UserError("Choose at least one folder in Settings before indexing.")
            self.indexing = True
            self.cancel_event.clear()
            self.last_error = None

    def index(self, progress: Callable[[dict], None] = lambda event: None, reserved: bool = False,
              paths: list[str] | None = None) -> dict:
        """Index new and changed files in the chosen folders.

        With paths (from the app's file watcher), only those files and folders are
        checked, and the ones that no longer exist leave the index.
        """
        import time
        targets = None if paths is None else [Path(os.path.abspath(os.path.expanduser(p))) for p in paths]
        if not reserved:
            self.reserve_index()
        processed = unchanged = failed = scanned = 0
        started = time.perf_counter()
        self.index_metrics = metrics = {"elapsedSeconds": 0.0, "scanSeconds": 0.0, "extractionSeconds": 0.0,
                                        "inferenceSeconds": 0.0, "writeSeconds": 0.0, "loadSeconds": 0.0, "reuseSeconds": 0.0,
                                        "decodedChunks": 0, "embeddedChunks": 0, "writtenChunks": 0,
                                        "reusedFiles": 0, "reusedChunks": 0,
                                        "completedFiles": 0, "unchangedFiles": 0, "failedFiles": 0,
                                        "prefetchEnabled": False, "stageTimesCanOverlap": True,
                                        "phase": "scanning"}
        outer_progress = progress

        def progress(event):
            metrics.update(elapsedSeconds=time.perf_counter() - started, completedFiles=processed,
                           unchangedFiles=unchanged, failedFiles=failed)
            outer_progress({**event, "indexMetrics": dict(metrics)})

        # Same-size twins left without a fingerprint by an earlier, interrupted pass get one now, so their copies
        # merge in results even if this pass is stopped before its end.
        metrics["fingerprintedFiles"] = self.file_reuse.fingerprint_twins(self.lock, self._check_cancel)
        seen: set[str] = set()
        inaccessible: list[Path] = []
        encoder = None
        model_key = None
        compatible_keys = ()
        # Queue small documents by chunk count rather than file count. Ordinary
        # multi-page PDFs can share full batches, with atomic per-file publish.
        # Large files still stream through the disk-backed staging table.
        pending: dict[str, list[tuple]] = {"text": [], "image": [], "audio": []}

        def encode_chunks(chunks):
            metrics["phase"] = "embedding"
            tick = time.perf_counter()
            try:
                with self.encoder_lock:
                    vectors = encoder.encode([chunk.payload for chunk in chunks])
                metrics["embeddedChunks"] += len(chunks)
                return vectors
            finally:
                metrics["inferenceSeconds"] += time.perf_counter() - tick

        def measured_source(path, kind, chunks=None):
            iterator = iter(self._passages(path, kind) if chunks is None else chunks)
            try:
                while True:
                    self._check_cancel()
                    tick = time.perf_counter()
                    try:
                        chunk = next(iterator)
                    except StopIteration:
                        return
                    finally:
                        metrics["extractionSeconds"] += time.perf_counter() - tick
                    metrics["decodedChunks"] += 1
                    yield chunk
            finally:
                close = getattr(iterator, "close", None)
                if close:
                    close()

        def walked():
            iterator = iter(plan["paths"])
            try:
                while True:
                    metrics["phase"] = "scanning"
                    tick = time.perf_counter()
                    try:
                        path = next(iterator)
                    except StopIteration:
                        return
                    finally:
                        metrics["scanSeconds"] += time.perf_counter() - tick
                    yield path
            finally:
                close = getattr(iterator, "close", None)
                if close:
                    close()

        def backfill_text(path: Path, kind: str, stat) -> bool:
            """Store an unchanged file's words. False when its passages no longer line up, so it is indexed again."""
            name = str(path)
            metrics["phase"] = "reading text"
            progress({"stage": "index", "scanned": scanned, "processed": processed, "unchanged": unchanged, "failed": failed, "path": name, "message": f"Reading the words in {path.name}"})
            tick = time.perf_counter()
            try:
                with self.lock:
                    self.texts.clear_staging()
                count = 0
                if kind == "image":
                    with self.lock:
                        self.texts.stage([(0, recognizer.image_text(path))])
                    count = 1
                elif kind == "text":
                    for chunk in self._passages(path, kind):
                        self._check_cancel()
                        with self.lock:
                            self.texts.stage([(count, chunk.words)])
                        count += 1
                with self.lock:
                    indexed = self.db.execute("SELECT COUNT(*) FROM chunks WHERE path=?", (name,)).fetchone()[0]
                if kind == "text" and count != indexed:
                    with self.lock:
                        self.texts.clear_staging()
                    return False
                check_file(path, stat)
                with self.lock:
                    with self.db:
                        self.texts.publish_staging(name, path.name)
                return True
            except Cancelled:
                raise
            except Exception:
                # Unreadable now: keep its vectors, and match it by name only.
                with self.lock:
                    with self.db:
                        self.texts.clear_staging()
                        self.texts.replace(name, path.name, [])
                return True
            finally:
                metrics["extractionSeconds"] += time.perf_counter() - tick

        def warn(path: Path, exc: Exception):
            nonlocal failed
            failed += 1
            progress({"stage": "warning", "path": str(path), "message": str(exc), "failed": failed})

        def check_file(path: Path, original):
            self._check_cancel()
            after = path.stat()
            # Atomic replacements can preserve size and modification time.
            # Inode/device/ctime also detect changes while awaiting a batch.
            if self._stat_signature(after) != self._stat_signature(original):
                raise UserError("File changed while indexing; run indexing again when it is saved.")

        def row_for(name: str, position: int, chunk: Chunk, vector: list[float]) -> tuple:
            identifier = sha256(f"{name}\0{position}".encode()).hexdigest()
            packed = array("f", vector)
            if sys.byteorder != "little":
                packed.byteswap()
            return (identifier, name, position, chunk.snippet, chunk.location, len(vector), packed.tobytes())

        def published(path: Path, kind: str, old, first_chunk: tuple, chunk_count: int):
            nonlocal processed
            processed += 1
            metrics["writtenChunks"] += chunk_count
            name = str(path)
            item = {"id": sha256(name.encode()).hexdigest(), "path": name, "title": path.name, "kind": kind, "snippet": first_chunk[0], "location": first_chunk[1], "score": 0.0}
            progress({"stage": "index", "item": item, "deletedPaths": [name] if old else [], "scanned": scanned, "processed": processed, "unchanged": unchanged, "failed": failed, "fileChunksCompleted": chunk_count})

        def flush(kind: str):
            work = pending[kind]
            if not work:
                return
            self._check_cancel()
            chunks = [chunk for item in work for chunk in item[3]]
            try:
                vectors = encode_chunks(chunks)
            except (Cancelled, ModelError):
                raise
            except Exception as exc:
                raise ModelError(f"Batch inference failed: {exc}") from exc
            self._check_cancel()
            if len(vectors) != len(chunks):
                raise ModelError("The model returned the wrong number of embeddings.")
            vectors = [normalized(vector) for vector in vectors]
            if len({len(vector) for vector in vectors}) != 1:
                raise ModelError("The model returned inconsistent embedding dimensions.")
            # Validate the entire inference result before publishing any file.
            # Each file then gets its own stat check and atomic transaction.
            offset = 0
            for path, stat, old, file_chunks in work:
                file_vectors = vectors[offset:offset + len(file_chunks)]
                offset += len(file_chunks)
                try:
                    check_file(path, stat)
                    name = str(path)
                    metrics["phase"] = "saving"
                    tick = time.perf_counter()
                    try:
                        rows = [row_for(name, position, chunk, vector) for position, (chunk, vector) in enumerate(zip(file_chunks, file_vectors))]
                        with self.lock:
                            with self.db:
                                self.db.execute("DELETE FROM chunks WHERE path=?", (name,))
                                self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?)", (name, kind, stat.st_mtime_ns, stat.st_size, self._model_key()))
                                self.db.executemany("INSERT INTO chunks VALUES (?,?,?,?,?,?,?)", rows)
                                self.texts.replace(name, path.name, ((position, chunk.words) for position, chunk in enumerate(file_chunks)))
                                self.file_reuse.remember(path, stat, kind)
                                self._remember_image_size(name, kind)
                    finally:
                        metrics["writeSeconds"] += time.perf_counter() - tick
                    first = file_chunks[0]
                    published(path, kind, old, (first.snippet, first.location), len(rows))
                except (Cancelled, ModelError):
                    raise
                except Exception as exc:
                    warn(path, exc)
            pending[kind] = []

        def flush_all():
            for kind in pending:
                flush(kind)

        lookahead = None
        try:
            model_key = self._model_key()
            compatible_keys = self._compatible_model_keys()
            metrics["phase"] = "scanning"
            tick = time.perf_counter()
            plan = self._plan_index(compatible_keys, targets, progress, inaccessible)
            metrics["scanSeconds"] += time.perf_counter() - tick
            with self.lock:
                current_texts = self.texts.current_paths()
                current_images = self._current_images()
                empty_files = {row[0]: (row[1], row[2]) for row in self.db.execute(
                    "SELECT path, mtime, size FROM empty_files WHERE version=?", (TEXT_VERSION,))}
            metrics.update(totalFiles=plan["total"], filesToProcess=plan["toProcess"])
            ahead = [path for path in plan["paths"] if kind_for(path) in Lookahead.KINDS and str(path) in plan["likely"]]
            if ahead and os.environ.get("DOCUFIND_LOOKAHEAD", "1") != "0":
                def read_ahead(path):
                    # As many chunks as the loop below reads before it decides how to batch the file.
                    chunks = self._passages(path, kind_for(path))
                    head = [chunk for _, chunk in zip(range(2), chunks)]
                    return head, chunks
                lookahead = Lookahead(ahead, read_ahead)
            progress({"stage": "plan", "totalFiles": plan["total"], "filesToProcess": plan["toProcess"],
                      **({"largeFolders": self.large_folders, "autoSkipped": dict(self.auto_skipped)} if targets is None else {})})
            for path in walked():
                self._check_cancel()
                name, kind = str(path), kind_for(path)
                seen.add(name)
                scanned += 1
                source = None
                try:
                    tick = time.perf_counter()
                    try:
                        stat = path.stat()
                        with self.lock:
                            old = self.db.execute("SELECT * FROM files WHERE path=?", (name,)).fetchone()
                    finally:
                        metrics["scanSeconds"] += time.perf_counter() - tick
                    if is_cloud_only(stat):
                        # Reading it would make iCloud download it; an earlier entry stays as it was.
                        continue
                    if empty_files.get(name) == (stat.st_mtime_ns, stat.st_size):
                        unchanged += 1
                        continue
                    unchanged_candidate = (old and old["model_key"] in compatible_keys
                                           and (old["mtime"], old["size"]) == (stat.st_mtime_ns, stat.st_size))
                    if unchanged_candidate and kind in ("image", "text") and name not in current_images:
                        unchanged_candidate = False  # Read in an earlier way (photo size, text extraction): read again.
                    if unchanged_candidate:
                        with self.lock:
                            unchanged_candidate = self.file_reuse.matches_signature(path, stat)
                    if unchanged_candidate and self._needs_text(path, current_texts):
                        # Keep the vectors; read the words once so they can be matched as written.
                        unchanged_candidate = backfill_text(path, kind, stat)
                        if unchanged_candidate:
                            processed += 1
                            progress({"stage": "index", "scanned": scanned, "processed": processed, "unchanged": unchanged, "failed": failed, "path": name})
                            continue
                    if unchanged_candidate:
                        unchanged += 1
                        if scanned % 50 == 0:
                            progress({"stage": "index", "scanned": scanned, "processed": processed, "unchanged": unchanged, "failed": failed, "path": name})
                        continue
                    progress({"stage": "index", "scanned": scanned, "processed": processed, "unchanged": unchanged, "failed": failed, "path": name, "message": f"Embedding {path.name}"})
                    metrics["phase"] = "checking copies"
                    tick = time.perf_counter()
                    try:
                        try:
                            match = self.file_reuse.match(path, stat, kind, model_key, self._check_cancel)
                        except OSError:
                            # A failed fingerprint is not a decoder failure;
                            # unchanged target bytes can still be indexed.
                            check_file(path, stat)
                            match = None
                    finally:
                        metrics["reuseSeconds"] += time.perf_counter() - tick
                    if match is not None and kind in ("image", "text") and match[0] not in current_images:
                        match = None  # A copy read in an earlier way: read this one afresh.
                    if match is not None:
                        check_file(path, stat)
                        metrics["phase"] = "saving"
                        tick = time.perf_counter()
                        try:
                            with self.lock:
                                with self.db:
                                    snippet, location, count = self.file_reuse.clone(match, path, stat, kind, model_key)
                                    self.texts.copy(match[0], name, path.name)
                                    self._remember_image_size(name, kind)
                        finally:
                            metrics["writeSeconds"] += time.perf_counter() - tick
                        metrics["reusedFiles"] += 1
                        metrics["reusedChunks"] += count
                        published(path, kind, old, (snippet, location), count)
                        continue
                    # A no-op update never loads the model. Once work is found,
                    # setup errors fail once rather than warning for every file.
                    if encoder is None:
                        encoder = self._encoder(progress)
                        if isinstance(encoder, CoreMLEncoder):
                            metrics["phase"] = "loading"
                            tick = time.perf_counter()
                            try:
                                with self.encoder_lock:
                                    encoder.load()
                            finally:
                                metrics["loadSeconds"] += time.perf_counter() - tick
                        model_key = self._model_key()
                        compatible_keys = self._compatible_model_keys()
                    metrics["phase"] = "extracting"
                    # Give common 5–16 chunk documents a chance to share packed
                    # Neural Engine runs with their neighbours.
                    # This is a CPU text lookahead bound, not a larger model batch.
                    small_limit = min(32, 4 * self._batch_size(encoder, kind)) if kind == "text" else 1
                    ready = lookahead.take(path, stat) if lookahead and kind in Lookahead.KINDS else None
                    if ready is not None:
                        metrics["readAheadFiles"] = metrics.get("readAheadFiles", 0) + 1
                        head, rest = ready
                        source = measured_source(path, kind, rest)
                    else:
                        source = measured_source(path, kind)
                        head = []
                        for _ in range(small_limit + 1):
                            self._check_cancel()
                            chunk = next(source, None)
                            if chunk is None:
                                break
                            head.append(chunk)
                    if not head:
                        # Nothing to index: blank, or no passage reads as language. Remembered until the
                        # file changes; an older entry for it (indexed before these rules) is removed.
                        with self.lock:
                            with self.db:
                                self.db.execute("INSERT OR REPLACE INTO empty_files VALUES (?,?,?,?)",
                                                (name, stat.st_mtime_ns, stat.st_size, TEXT_VERSION))
                            if old:
                                self._delete_paths([name])
                        metrics["emptyFiles"] = metrics.get("emptyFiles", 0) + 1
                        progress({"stage": "index", "scanned": scanned, "processed": processed, "unchanged": unchanged, "failed": failed,
                                  "path": name, "message": f"No text to index in {path.name}",
                                  **({"deletedPaths": [name]} if old else {})})
                        continue
                    if len(head) <= small_limit:
                        # Give text up to 64 chunks of global length sorting.
                        # Images and
                        # audio keep the smaller decoded-payload queue limits.
                        queue_size = min(64, 8 * self._batch_size(encoder, kind)) if kind == "text" else self._batch_size(encoder, kind)
                        queued_chunks = sum(len(item[3]) for item in pending[kind])
                        if queued_chunks + len(head) > queue_size:
                            flush(kind)
                        pending[kind].append((path, stat, old, head))
                        if sum(len(item[3]) for item in pending[kind]) >= queue_size:
                            flush(kind)
                        continue
                    flush_all()

                    def prefixed(head=head, raw_source=source):
                        try:
                            yield from head
                            yield from raw_source
                        finally:
                            raw_source.close()

                    source = prefixed()
                    if os.environ.get("DOCUFIND_PREFETCH", "1") != "0":
                        metrics["prefetchEnabled"] = True
                        source = self._prefetched_chunks(source, self._batch_size(encoder, kind), self._check_cancel)

                    # Staging is a bounded SQLite TEMP table, one transaction
                    # per file. Cancellation/failure roll it back; old committed
                    # vectors remain intact until the final atomic replacement.
                    with self.lock:
                        self.db.execute("DELETE FROM staging")
                        self.texts.clear_staging()
                    first_chunk = (head[0].snippet, head[0].location)
                    row_count = 0
                    for chunks, vectors in self._encoded_batches(path, kind, encoder, self._check_cancel, source, encode_chunks):
                        metrics["phase"] = "saving"
                        tick = time.perf_counter()
                        try:
                            rows = [row_for(name, row_count + i, chunk, vector) for i, (chunk, vector) in enumerate(zip(chunks, vectors))]
                            row_count += len(rows)
                            with self.lock:
                                self.db.executemany("INSERT INTO staging VALUES (?,?,?,?,?,?,?)", rows)
                                self.texts.stage((row_count - len(rows) + i, chunk.words) for i, chunk in enumerate(chunks))
                        finally:
                            metrics["writeSeconds"] += time.perf_counter() - tick
                        progress({"stage": "index", "path": name, "scanned": scanned, "processed": processed,
                                  "unchanged": unchanged, "failed": failed, "fileChunksCompleted": row_count,
                                  "message": f"Embedded {row_count} chunks in {path.name}"})
                    check_file(path, stat)
                    tick = time.perf_counter()
                    try:
                        with self.lock:
                            with self.db:
                                self.db.execute("DELETE FROM chunks WHERE path=?", (name,))
                                self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?)", (name, kind, stat.st_mtime_ns, stat.st_size, self._model_key()))
                                self.db.execute("INSERT INTO chunks SELECT * FROM staging")
                                self.db.execute("DELETE FROM staging")
                                self.texts.publish_staging(name, path.name)
                                self.file_reuse.remember(path, stat, kind)
                                self._remember_image_size(name, kind)
                    finally:
                        metrics["writeSeconds"] += time.perf_counter() - tick
                    published(path, kind, old, first_chunk, row_count)
                except (Cancelled, ModelError):
                    raise
                except Exception as exc:
                    self._clear_staging()
                    warn(path, exc)
                finally:
                    close = getattr(source, "close", None)
                    if close:
                        close()
            flush_all()
            self._check_cancel()
            # Files of the same size and type that were indexed separately get a content fingerprint,
            # so identical copies show as one result. Cheap: only files with a same-size twin are read.
            metrics["phase"] = "checking copies"
            metrics["fingerprintedFiles"] += self.file_reuse.fingerprint_twins(self.lock, self._check_cancel)
            with self.lock:
                # Only files that are really gone, or now excluded, leave the index. Anything that
                # can't be checked (an unreadable folder, a missing volume) keeps its entry.
                candidates = [row[0] for row in self.db.execute("SELECT path FROM files")
                              if row[0] not in seen and not any(within(Path(row[0]), blocked) for blocked in inaccessible)
                              and (targets is None or any(within(Path(row[0]), target) for target in targets))]
            deleted = [path for path in candidates if self._gone(Path(path))]
            with self.lock:
                self._delete_paths(deleted)
            if deleted:
                progress({"stage": "index", "deletedPaths": deleted})
            metrics.update(elapsedSeconds=time.perf_counter() - started, completedFiles=processed,
                           unchangedFiles=unchanged, failedFiles=failed, phase="complete")
            return {**self.status(), "indexing": False, "processed": processed, "unchanged": unchanged, "failed": failed, "scanned": scanned, "cancelled": False, "deletedPaths": deleted}
        except Cancelled:
            metrics.update(elapsedSeconds=time.perf_counter() - started, completedFiles=processed,
                           unchangedFiles=unchanged, failedFiles=failed, phase="cancelled")
            return {**self.status(), "indexing": False, "processed": processed, "unchanged": unchanged, "failed": failed, "scanned": scanned, "cancelled": True}
        except Exception as exc:
            self.last_error = str(exc)
            raise
        finally:
            if lookahead:
                lookahead.close()
            pending.clear()
            try:
                self._clear_staging()
            finally:
                self.indexing = False

    def audio_preview(self, path: str, start: float = 0, end: float = 30, bins: int = 160, clip: bool = False) -> dict:
        """Waveform peaks for a recording, and optionally its matched passage as a short WAV.

        The app plays the original file at the passage's timestamps when macOS can decode it.
        A clip is only written for formats it cannot open, such as Ogg/Opus, using the same
        decoder as indexing. Clips live in the private data folder; only the newest few are kept.
        """
        import numpy as np
        import soundfile as sf
        source = Path(path).expanduser().resolve()
        if not source.is_file() or kind_for(source) != "audio":
            raise UserError("Choose a recording to play.")
        bins = max(16, min(int(bins), 512))
        stat = source.stat()
        # The same request again (a replay, a card redrawn) is answered at once while its clip is still there.
        cache = self.__dict__.setdefault("_audio_previews", {})
        key = (str(source), stat.st_mtime_ns, float(start), float(end), bins, bool(clip))
        hit = cache.get(key)
        if hit and (not hit["clip"] or Path(hit["clip"]).exists()):
            return dict(hit)
        with readable_audio(source) as audio:
            rate, frames = audio.samplerate, len(audio)
            if frames <= 0 or rate <= 0:
                raise UserError("This recording is empty.")
            first = int(max(0.0, float(start)) * rate)
            last = int(min(float(end) * rate, frames))
            if last <= first:
                first, last = max(0, min(first, frames - 1)), min(frames, max(first, 0) + 30 * rate)
            samples = None
            if source.suffix.lower() in SLOW_SEEK_AUDIO:
                # One pass from the start: a seek inside Ogg decodes from the beginning again, so the bins' seeks
                # below took seconds. The loudness of each bin and the clip come from the same pass.
                sums, counts, parts, position = np.zeros(bins), np.zeros(bins), [], 0
                for block in audio.blocks(blocksize=rate * 5, dtype="float32", always_2d=True):
                    n = len(block)
                    index = np.minimum(np.arange(position, position + n) * bins // frames, bins - 1)
                    sums += np.bincount(index, weights=np.mean(np.square(block), axis=1), minlength=bins)[:bins]
                    counts += np.bincount(index, minlength=bins)[:bins]
                    if clip and position < last and position + n > first:
                        parts.append(block[max(0, first - position):min(n, last - position)])
                    position += n
                peaks = np.sqrt(sums / np.maximum(counts, 1)).astype(np.float32)
                if clip:
                    samples = np.concatenate(parts) if parts else np.zeros((0, audio.channels), np.float32)
            else:
                peaks = np.zeros(bins, dtype=np.float32)
                for index in range(bins):
                    lo, hi = index * frames // bins, (index + 1) * frames // bins
                    if hi > lo:
                        audio.seek(lo)
                        # Loudness (RMS) rather than peak: mastered music peaks near full scale everywhere.
                        block = audio.read(hi - lo, dtype="float32", always_2d=True)
                        peaks[index] = float(np.sqrt(np.mean(np.square(block))))
                if clip:
                    audio.seek(first)
                    samples = audio.read(last - first, dtype="float32", always_2d=True)
        top = float(peaks.max()) or 1.0
        result = {"duration": frames / rate, "peaks": [round(float(v) / top, 3) for v in peaks],
                  "clip": None, "clipStart": first / rate, "clipEnd": last / rate}
        if samples is None:
            cache[key] = dict(result)
            return result
        folder = self.data_dir / "previews"
        folder.mkdir(mode=0o700, exist_ok=True)
        name = sha256(f"{source}:{stat.st_mtime_ns}:{first}:{last}".encode()).hexdigest()[:24] + ".wav"
        target = folder / name
        if not target.exists():
            sf.write(str(target), samples, rate, subtype="PCM_16")
            os.chmod(target, 0o600)
        for old in sorted(folder.glob("*.wav"), key=lambda item: item.stat().st_mtime, reverse=True)[4:]:
            old.unlink(missing_ok=True)
        result["clip"] = str(target)
        cache[key] = dict(result)
        return result

    def items(self, offset: int = 0, limit: int = 500) -> dict:
        offset, limit = max(0, int(offset)), max(1, min(int(limit), 2000))
        model_keys = self._compatible_model_keys()
        placeholders = ",".join("?" for _ in model_keys)
        with self.lock:
            rows = self.db.execute(f"SELECT f.path,f.kind,c.snippet,c.location FROM files f JOIN chunks c ON c.path=f.path AND c.position=0 WHERE f.model_key IN ({placeholders}) ORDER BY f.path LIMIT ? OFFSET ?", (*model_keys, limit, offset)).fetchall()
            total = self.db.execute(f"SELECT COUNT(*) FROM files WHERE model_key IN ({placeholders})", model_keys).fetchone()[0]
        items = [with_page({"id": sha256(row["path"].encode()).hexdigest(), "path": row["path"], "title": Path(row["path"]).name, "kind": row["kind"], "snippet": row["snippet"], "location": row["location"], "score": 0.0}) for row in rows]
        return {"items": items, "total": total, "offset": offset, "nextOffset": offset + len(items) if offset + len(items) < total else None}

    def search(self, text: str | None = None, path: str | None = None, kind: str = "all", limit: int = 20, progress: Callable[[dict], None] = lambda event: None) -> dict:
        if kind not in {"all", "text", "image", "audio"}:
            raise UserError("Search kind must be all, text, image, or audio.")
        if not ((text and text.strip()) or path):
            raise UserError("Type a query or choose an image, audio, or text file.")
        limit = max(1, min(int(limit), 100))
        model_keys = self._compatible_model_keys()
        placeholders = ",".join("?" for _ in model_keys)
        with self.lock:
            count = self.db.execute(f"SELECT COUNT(*) FROM files WHERE model_key IN ({placeholders})", model_keys).fetchone()[0]
        if count == 0:
            return {"items": [], "message": "Choose folders and start indexing to search your files."}
        with self.encoder_lock:
            # Loads the model here, never alongside another thread's first load.
            encoder = self._encoder(progress)
            if hasattr(encoder, "load"):
                encoder.load()
        vectors = []
        if text and text.strip():
            query_text = text.strip()
            cache_key = (self._query_profile(encoder), "text", query_text)
            vector = self._cached_query(cache_key)
            if vector is None:
                with self.encoder_lock:
                    encoded = encoder.encode([query_text])
                if len(encoded) != 1:
                    raise ModelError("The model returned the wrong number of embeddings.")
                vector = normalized(encoded[0])
                self._remember_query((self._query_profile(encoder), "text", query_text), vector)
            vectors.append(vector)
        if path:
            query_path = Path(path).expanduser().resolve()
            query_kind = kind_for(query_path)
            if not query_path.is_file() or not query_kind:
                raise UserError("Choose a readable text/PDF, image, or audio file as the query.")
            signature = self._query_file_signature(query_path)
            cache_key = (self._query_profile(encoder), "file", str(query_path), signature)
            vector = self._cached_query(cache_key)
            if vector is None:
                # Mean normalized chunk vectors retain the existing long-file
                # query semantics while processing bounded homogeneous batches.
                accumulator = None
                n = 0
                for _, batch_vectors in self._encoded_batches(query_path, query_kind, encoder):
                    for chunk_vector in batch_vectors:
                        if accumulator is None:
                            accumulator = [0.0] * len(chunk_vector)
                        accumulator = [a + b for a, b in zip(accumulator, chunk_vector)]
                        n += 1
                if not n:
                    raise UserError("The query file contains no readable content.")
                if self._query_file_signature(query_path) != signature:
                    raise UserError("The query file changed while reading it. Save it and search again.")
                vector = normalized(accumulator)
                self._remember_query((self._query_profile(encoder), "file", str(query_path), signature), vector)
            vectors.append(vector)
        model_keys = self._compatible_model_keys()
        placeholders = ",".join("?" for _ in model_keys)
        dimension = len(vectors[0])
        if any(len(v) != dimension for v in vectors):
            raise ModelError("The model returned inconsistent embedding dimensions.")
        query = normalized(sum(v[i] for v in vectors) for i in range(dimension))
        # Words matched as written lift a file above ones that are only close in meaning.
        exact = ExactQuery(text)
        boosts: dict[str, float] = {}
        hits: dict[str, dict] = {}
        required: set[str] | None = None
        message = None
        if exact.phrases:
            with self.lock:
                found = [self.texts.find(phrase) for phrase in exact.phrases]
            if exact.required:
                common = set.intersection(*(set(f) for f in found))
                if common:
                    required = common
                    hits = {path: found[0][path] for path in common}
                else:
                    message = "No file contains " + " and ".join(f"“{p}”" for p in exact.required) + " as written. These are the closest in meaning."
            else:
                # A file named like the query beats passages that merely mention it, more so for single
                # file-name-like queries ("README", "IMG_1234"); a passage containing the words gets a smaller lift.
                filename_like = " " not in exact.phrases[0].strip()
                for path, entry in found[0].items():
                    boost = max(0.06 if entry["position"] is not None and exact.distinctive else 0.0,
                                (0.15 if filename_like else 0.08) if entry["name"] else 0.0)
                    if boost:
                        boosts[path], hits[path] = boost, entry
        # NumPy is an inference dependency; scanning the exact cosine index in
        # bounded batches avoids loading an entire home folder's vectors at once.
        import numpy as np
        query_array = np.asarray(query, dtype=np.float32)
        best: dict[str, dict] = {}
        filter_data = self.options["skipMachineFiles"]
        sql = f"SELECT c.*,f.kind FROM chunks c JOIN files f USING(path) WHERE f.model_key IN ({placeholders})"
        parameters: list[Any] = list(model_keys)
        if kind != "all":
            sql += " AND f.kind=?"
            parameters.append(kind)
        with self.lock:
            cursor = self.db.execute(sql, parameters)
            # At 2048 dimensions each block holds at most 8 MiB of vectors;
            # concatenate packed blobs once instead of allocating one NumPy
            # array object per chunk. Larger blocks reduce SQLite/BLAS overhead.
            batch_rows = max(1, min(1024, (8 * 1024 * 1024) // (dimension * 4)))
            while rows := cursor.fetchmany(batch_rows):
                compatible = [r for r in rows if r["dimensions"] == dimension]
                if not compatible:
                    continue
                matrix = np.frombuffer(b"".join(r["vector"] for r in compatible), dtype="<f4").reshape(len(compatible), dimension)
                scores = matrix @ query_array
                # Only passages that can still make the results go through the Python loop below: the best few
                # hundred by score (ties included, so the order stays stable) plus every file matched as written.
                candidates = range(len(compatible))
                keep = max(limit * 40, 800)
                if len(compatible) > keep:
                    threshold = np.partition(scores, len(scores) - keep)[len(scores) - keep]
                    chosen = set(np.flatnonzero(scores >= threshold).tolist())
                    if boosts:
                        chosen.update(i for i, r in enumerate(compatible) if r["path"] in boosts)
                    candidates = sorted(chosen)
                for i in candidates:
                    row, score = compatible[i], scores[i]
                    if required is not None and row["path"] not in required:
                        continue
                    score = max(-1.0, min(1.0, float(score)))
                    if row["path"] not in best or score > best[row["path"]]["score"]:
                        # Passages indexed before the language check tightened (a template reduced to "|")
                        # still sit in the index; keep them out of results without re-reading every file.
                        if filter_data and row["kind"] == "text" and not looks_like_language(row["snippet"] or ""):
                            continue
                        best[row["path"]] = {"id": sha256(row["path"].encode()).hexdigest(), "path": row["path"], "title": Path(row["path"]).name, "kind": row["kind"], "snippet": row["snippet"], "score": score, "location": row["location"], "position": row["position"],
                                             "rank": score + boosts.get(row["path"], 0.0) - short_passage_penalty(row["kind"], row["snippet"])}
                # Keep only top files after each batch: lower scores cannot enter
                # the final top-k unless a later chunk improves that file.
                # Identical copies collapse into one result below, so keep extra candidates.
                if len(best) > limit * 8:
                    best = {item["path"]: item for item in heapq.nsmallest(limit * 3, best.values(), key=lambda item: (-item["rank"], item["path"]))}
            items = sorted(best.values(), key=lambda item: (-item["rank"], item["path"]))[:limit * 3]
            for item in items:
                del item["rank"]
                hit = hits.get(item["path"])
                if hit is None:
                    continue
                # Show the passage with the words, not the one closest in meaning.
                item["exact"] = "text" if hit["position"] is not None else "name"
                item["matched"] = exact.phrases[0]
                if hit["position"] is not None:
                    row = self.db.execute("SELECT location FROM chunks WHERE path=? AND position=?", (item["path"], hit["position"])).fetchone()
                    if row is not None:
                        item["location"] = row[0]
                    if item["kind"] == "image":
                        item["recognizedText"] = excerpt(hit["text"], exact.phrases[0], 160)
                    else:
                        item["snippet"] = excerpt(hit["text"], exact.phrases[0])
        items = self._collapse_copies(items)[:limit]
        for item in items:
            with_page(item)
        result = {"items": items, "exactPhrases": exact.phrases}
        if message:
            result["message"] = message
        return result

    # MARK: Model

    def download_model(self, progress: Callable[[dict], None] = lambda event: None) -> dict:
        """Fetches the search model and prepares it for this Mac (compiled and checked) ahead of the first index."""
        encoder = self._encoder(progress)
        if isinstance(encoder, CoreMLEncoder):
            if not model_download.verified(encoder.cache):
                encoder.download()
            encoder.load()
        return self.status()

    def update_paths(self, paths: list[str], progress: Callable[[dict], None] = lambda event: None) -> dict:
        """Live updates from the app's file watcher. The caller reserves indexing first."""
        if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
            self.indexing = False
            raise UserError("Changed paths must be a list of local paths.")
        return self.index(progress, reserved=True, paths=paths)

    def close(self) -> None:
        try:
            self._release_encoder()
            recognizer.close()
        finally:
            with self.lock:
                self.db.close()
