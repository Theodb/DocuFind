"""Which files are worth reading, and in what order.

Decided from names and folder contents alone, before any file is opened:
- Machine-made files are skipped: folders that hold a downloaded model (a config.json next to
  weights or tokenizer files), test fixtures, and tokenizer vocabularies such as merges.txt.
- Very long plain-text files (logs, dumps) are read only up to a limit of passages.
- Files people are likely to look for come first: their own folders and recent files, ahead of
  output, cache and log folders and deeply nested paths.
"""
from __future__ import annotations

import os
from pathlib import Path

DEFAULT_OPTIONS = {"skipMachineFiles": True, "limitLongFiles": True, "importantFirst": True}
LONG_FILE_PASSAGES = 200  # About 360,000 characters of plain text.

# Tokenizer vocabularies and merge tables: text files, but word pieces rather than language.
MACHINE_FILE_NAMES = frozenset({"merges.txt", "vocab.txt", "vocab.bpe.txt", "bpe_codes.txt", "spm.vocab.txt",
                                "sentencepiece.bpe.txt", "added_tokens.txt", "special_tokens_map.txt"})
# Inputs and expected outputs kept next to tests.
FIXTURE_FOLDERS = frozenset({"fixtures", "__fixtures__", "testdata", "test_data", "test-data", "__snapshots__"})
# A folder holding a model: its configuration together with weights or tokenizer files.
MODEL_WEIGHT_SUFFIXES = (".safetensors", ".gguf", ".onnx", ".pt", ".pth", ".ckpt", ".tflite", ".mlmodel", ".npz", ".msgpack", ".h5")
MODEL_FILE_NAMES = frozenset({"pytorch_model.bin", "tokenizer.json", "tokenizer_config.json", "model.safetensors.index.json",
                              "generation_config.json", "preprocessor_config.json", "special_tokens_map.json"})
# Folders whose contents are usually produced by programs rather than written by people.
GENERATED_FOLDERS = frozenset({"logs", "log", "tmp", "temp", "cache", "caches", "build", "dist", "out", "output", "outputs",
                               "results", "runs", "checkpoints", "wandb", "mlruns", "lightning_logs", "target", "artifacts"})
PERSONAL_FOLDERS = ("Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies")


def options(value) -> dict:
    """Saved options merged over the defaults; unknown keys are ignored."""
    merged = dict(DEFAULT_OPTIONS)
    if isinstance(value, dict):
        merged.update({key: bool(on) for key, on in value.items() if key in DEFAULT_OPTIONS})
    return merged


def is_model_folder(files: list[str]) -> bool:
    names = set(files)
    if "config.json" not in names:
        return False
    return bool(names & MODEL_FILE_NAMES) or any(name.lower().endswith(MODEL_WEIGHT_SUFFIXES) for name in files)


def machine_file(name: str) -> bool:
    return name.lower() in MACHINE_FILE_NAMES


class FolderCache:
    """Whether a folder holds a model, listing each folder at most once."""

    def __init__(self):
        self._known: dict[Path, bool] = {}

    def model_folder(self, folder: Path, files: list[str] | None = None) -> bool:
        if folder not in self._known:
            if files is None:
                try:
                    files = os.listdir(folder)
                except OSError:
                    files = []
            self._known[folder] = is_model_folder(files)
        return self._known[folder]


def machine_made(path: Path, root: Path, folders: FolderCache) -> str | None:
    """Why an existing file counts as machine-made, or None."""
    if machine_file(path.name):
        return "tokenizer files"
    relative = path.relative_to(root).parts[:-1]
    if any(part.lower() in FIXTURE_FOLDERS for part in relative):
        return "test fixtures"
    for depth in range(len(relative), 0, -1):
        if folders.model_folder(root.joinpath(*relative[:depth])):
            return "model folders"
    return None


def priority(path: Path, root: Path, mtime: int) -> tuple:
    """Sort key: personal places first, generated or deeply nested places last, newest first within each."""
    home = Path.home()
    parts = path.relative_to(root).parts[:-1]
    if any(part.lower() in GENERATED_FOLDERS for part in parts) or len(parts) > 8:
        tier = 2
    else:
        try:
            top = path.relative_to(home).parts[0]
        except (ValueError, IndexError):
            top = ""
        tier = 0 if top in PERSONAL_FOLDERS or root != home else 1
    return (tier, -mtime)
