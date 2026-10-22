from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model_download

FILES = {"omni.json": b'{"version": 1}', "embeddings.npy": b"e" * 4000, "text_first.mlpackage/Data/weights.bin": b"w" * 6000}


def listing() -> list:
    return [types.SimpleNamespace(path=name, size=len(data)) for name, data in FILES.items()] + [types.SimpleNamespace(path="text_first.mlpackage"), types.SimpleNamespace(path="assets/docufind.mp4", size=10_000_000)]


def manifest() -> bytes:
    return json.dumps({name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} for name, data in FILES.items()}).encode()


def place(cache: Path, files: dict[str, bytes]) -> None:
    for name, data in files.items():
        path = model_download.folder(cache) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def hub(snapshot_download) -> dict:
    return {"huggingface_hub": types.SimpleNamespace(snapshot_download=snapshot_download,
                                                     HfApi=lambda: types.SimpleNamespace(list_repo_tree=lambda *a, **k: listing()),
                                                     constants=types.SimpleNamespace())}


class ModelDownloadTests(unittest.TestCase):
    def test_downloaded_needs_every_listed_file_at_its_size(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            self.assertFalse(model_download.downloaded(cache))
            place(cache, {"files.json": manifest(), **{k: v for k, v in FILES.items() if k != "embeddings.npy"}})
            self.assertFalse(model_download.downloaded(cache))
            place(cache, {"embeddings.npy": b"e" * 10})
            self.assertFalse(model_download.downloaded(cache))
            place(cache, FILES)
            self.assertTrue(model_download.downloaded(cache))
            self.assertFalse(model_download.verified(cache))

    def test_progress_rises_holds_below_complete_until_verified(self):
        total = sum(len(data) for data in FILES.values())
        def snapshot_download(repo, revision, local_dir, tqdm_class, ignore_patterns=None):
            self.assertEqual((repo, revision), (model_download.REPO, model_download.REVISION))
            files = tqdm_class(desc="Fetching 3 files", total=3)
            files.update(3)  # Not bytes: ignored.
            transfer = tqdm_class(desc="Downloading bytes", total=total)
            for _ in range(12):  # More than the files' size: progress must still stop short of complete.
                transfer.update(total // 10)
            place(Path(local_dir).parent, {"files.json": manifest(), **FILES})

        reports = []
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, hub(snapshot_download)):
            model_download.download(Path(directory), lambda received, total: reports.append((received, total)), interval=0)
            self.assertTrue(model_download.verified(Path(directory)))
        received = [r for r, _ in reports]
        self.assertEqual(received, sorted(received))
        self.assertTrue(all(t == total for _, t in reports))
        self.assertLessEqual(received[-2], int(total * 0.99))
        self.assertEqual(received[-1], total)

    def test_files_already_present_count_as_done(self):
        reports = []
        def snapshot_download(repo, revision, local_dir, tqdm_class, ignore_patterns=None):
            place(Path(local_dir).parent, {"files.json": manifest(), **FILES})
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, hub(snapshot_download)):
            place(Path(directory), {"embeddings.npy": FILES["embeddings.npy"]})
            model_download.download(Path(directory), lambda received, total: reports.append(received), interval=0)
        self.assertGreaterEqual(reports[0], len(FILES["embeddings.npy"]))

    def test_damaged_file_is_removed_and_reported(self):
        def snapshot_download(repo, revision, local_dir, tqdm_class, ignore_patterns=None):
            place(Path(local_dir).parent, {"files.json": manifest(), **FILES, "embeddings.npy": b"x" * 4000})
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, hub(snapshot_download)):
            with self.assertRaisesRegex(OSError, "damaged"):
                model_download.download(Path(directory), lambda received, total: None)
            self.assertFalse((model_download.folder(Path(directory)) / "embeddings.npy").exists())
            self.assertFalse(model_download.verified(Path(directory)))

    def test_incomplete_download_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, hub(lambda *a, **k: None)):
            with self.assertRaisesRegex(OSError, "did not complete"):
                model_download.download(Path(directory), lambda received, total: None)

    def test_already_verified_reports_complete_without_network(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, {"huggingface_hub": None}):
            cache = Path(directory)
            place(cache, {"files.json": manifest(), **FILES})
            model_download.verify(cache)
            reports = []
            model_download.download(cache, lambda received, total: reports.append((received, total)))
            total = sum(len(data) for data in FILES.values())
            self.assertEqual(reports, [(total, total)])


if __name__ == "__main__":
    unittest.main()
