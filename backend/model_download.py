"""Downloads the search model, the Core ML version of BidirLM-Omni, reporting progress in bytes.

Used by setup.sh, which runs it alongside the package install so both finish together, and by the
encoder when the model is still missing at first use. It imports only huggingface_hub, never PyTorch.

As a script: model_download.py <cache folder>. It prints "::docufind model <received> <total>" lines.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import time
from typing import Callable

MODEL_ID = "BidirLM/BidirLM-Omni-2.5B-Embedding"
REPO = "BidirLM/BidirLM-Omni-2.5B-Embedding-CoreML"
# The published commit the app downloads: the Core ML conversion, version 1. A new conversion means a new pin.
REVISION = "935e338555aed99949ea4e970f8aa0ea6cbb00e4"
MODEL_REVISION = REVISION
FILES = "files.json"
# The model card's banner and video live in the repository too; the app has no use for them.
CARD_ASSETS = "assets"


def folder(cache: Path) -> Path:
    return cache / "coreml"


def _listed(cache: Path) -> dict | None:
    try:
        files = json.loads((folder(cache) / FILES).read_text())
    except (OSError, ValueError):
        return None
    return files if isinstance(files, dict) and files else None


def _marker(cache: Path) -> Path:
    return folder(cache) / f".verified-{REVISION}"


def downloaded(cache: Path) -> bool:
    """Whether every file the manifest lists is present at its listed size."""
    files = _listed(cache)
    if files is None:
        return False
    base = folder(cache)
    try:
        return all((base / name).stat().st_size == entry["bytes"] for name, entry in files.items())
    except (OSError, KeyError, TypeError):
        return False


def verified(cache: Path) -> bool:
    return downloaded(cache) and _marker(cache).is_file()


def verify(cache: Path) -> None:
    """Checks every file against its SHA-256, once; a damaged file is removed so the next download replaces it."""
    files = _listed(cache)
    if files is None:
        raise OSError("The search model is incomplete. Check your internet connection and try again.")
    base = folder(cache)
    for name, entry in files.items():
        digest = hashlib.sha256()
        try:
            with open(base / name, "rb") as handle:
                for block in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(block)
        except OSError as exc:
            raise OSError(f"The search model is incomplete ({name} is missing). Check your internet connection and try again.") from exc
        if digest.hexdigest() != entry.get("sha256"):
            (base / name).unlink(missing_ok=True)
            raise OSError(f"A search model file ({name}) was damaged in transfer and was removed. Try again to download it.")
    _marker(cache).write_text(json.dumps({"repo": REPO, "revision": REVISION}) + "\n")


def download(cache: Path, report: Callable[[int, int], None], interval: float = 0.25) -> None:
    """Fetches every file of the published revision. report(received, total) is called at most every interval seconds."""
    if verified(cache):
        files = _listed(cache) or {}
        total = sum(entry["bytes"] for entry in files.values())
        report(total, total)
        return
    os.environ["HF_HOME"] = str(cache / "huggingface")
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    # Plain HTTPS, which times out and resumes; the Xet transfer can wait forever on a silent connection.
    os.environ["HF_HUB_DISABLE_XET"] = "1"
    from huggingface_hub import HfApi, constants, snapshot_download
    from tqdm.auto import tqdm

    constants.HF_HUB_DISABLE_XET = True   # also when the library was imported before this ran

    base = folder(cache)
    base.mkdir(parents=True, exist_ok=True)
    listing = [item for item in HfApi().list_repo_tree(REPO, revision=REVISION, recursive=True)
               if getattr(item, "size", None) is not None and not item.path.startswith(f"{CARD_ASSETS}/")]
    total = sum(item.size for item in listing)
    # Files already complete from an interrupted download count as done.
    present = sum(item.size for item in listing if (base / item.path).is_file() and (base / item.path).stat().st_size == item.size)
    remaining = max(total - present, 1)
    lock = threading.Lock()
    state = {"transferred": 0, "sent": 0.0}

    class Progress(tqdm):
        """Counts the bytes received from the network. The bytes written to disk arrive in bursts, so they can't drive a bar."""

        def __init__(self, *args, **kwargs):
            self.transfer = kwargs.get("desc") == "Downloading bytes"
            kwargs["disable"] = True
            super().__init__(*args, **kwargs)

        def update(self, n=1):
            if not self.transfer or not n:
                return
            with lock:
                state["transferred"] += int(n)
                now = time.monotonic()
                if now - state["sent"] < interval:
                    return
                state["sent"] = now
                share = min(state["transferred"] / remaining, 0.99)
            report(present + int(remaining * share), total)

    snapshot_download(REPO, revision=REVISION, local_dir=str(base), tqdm_class=Progress, ignore_patterns=[f"{CARD_ASSETS}/*"])
    if not downloaded(cache):
        raise OSError("The search model download did not complete. Check your internet connection and try again.")
    report(min(present + int(remaining * 0.99), total), total)
    verify(cache)
    report(total, total)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: model_download.py <cache folder>", file=sys.stderr)
        return 2
    cache = Path(sys.argv[1])
    cache.mkdir(parents=True, exist_ok=True)
    download(cache, lambda received, total: print(f"::docufind model {received} {total}", flush=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
