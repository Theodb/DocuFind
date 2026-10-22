from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model_download
from docufind import (CoreMLEncoder, Engine, MODEL_ID, MODEL_KEY, MODEL_REVISION,
                      ModelError, UserError, audio_spans, normalized, split_text,
                      text_file_chunks, extract)


class TestEncoder:
    """Only injected by tests; production has no synthetic embedding mode."""
    def __init__(self, device, cache, progress):
        self.device, self.loaded, self.calls = "ane", True, 0
        self.on_encode = None
    def encode(self, inputs):
        self.calls += len(inputs)
        if self.on_encode:
            self.on_encode()
        return [normalized([str(text).lower().count("red"), str(text).lower().count("blue"), 0.01]) for text in inputs]


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.base = Path(self.tmp.name).resolve()
        self.files = self.base / "documents"
        self.files.mkdir()
        self.engine = Engine(self.base / "private", encoder_factory=TestEncoder)
        self.engine.configure([str(self.files)])

    def tearDown(self):
        self.engine.close()
        self.tmp.cleanup()

    def write(self, name, text):
        path = self.files / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_incremental_persistence_update_and_deletion(self):
        red = self.write("red.txt", "red red")
        blue = self.write("blue.md", "blue blue")
        events = []
        result = self.engine.index(events.append)
        self.assertEqual(result["processed"], 2)
        self.assertEqual(len([event for event in events if "item" in event]), 2)
        calls = self.engine.encoder.calls
        self.assertEqual(self.engine.index()["unchanged"], 2)
        self.assertEqual(self.engine.encoder.calls, calls)
        red.write_text("blue changed")
        blue.unlink()
        result = self.engine.index()
        self.assertEqual(result["processed"], 1)
        self.assertEqual(result["deletedPaths"], [str(blue)])
        self.assertEqual(self.engine.status()["indexedCount"], 1)
        reopened = Engine(self.base / "private", encoder_factory=TestEncoder)
        try:
            self.assertEqual(reopened.status()["roots"], [str(self.files)])
            self.assertEqual(reopened.items()["items"][0]["snippet"], "blue changed")
        finally:
            reopened.close()

    @unittest.skipUnless(importlib.util.find_spec("numpy"), "NumPy required for vector search")
    def test_index_reports_planned_work_before_processing(self):
        self.write("red.txt", "red red")
        self.write("blue.md", "blue blue")
        self.write("notes.bin", "ignored")
        events = []
        self.engine.index(events.append)
        plan = [event for event in events if event.get("stage") == "plan"]
        self.assertEqual((plan[0]["totalFiles"], plan[0]["filesToProcess"]), (2, 2))
        self.assertLess(events.index(plan[0]), next(i for i, event in enumerate(events) if "item" in event))
        self.write("red.txt", "red red red")
        events = []
        self.engine.index(events.append)
        plan = [event for event in events if event.get("stage") == "plan"][0]
        self.assertEqual((plan["totalFiles"], plan["filesToProcess"]), (2, 1))

    def test_cosine_search_chunks_dedupes_and_filters(self):
        self.write("red.txt", "red " * 2000)
        self.write("blue.txt", "blue blue")
        self.engine.index()
        result = self.engine.search(text="red", limit=10)
        self.assertEqual(result["items"][0]["title"], "red.txt")
        self.assertGreater(result["items"][0]["score"], 0.99)
        self.assertEqual(len(result["items"]), 2)
        self.assertEqual(self.engine.search(text="red", kind="audio")["items"], [])
        self.assertEqual(self.engine.search(path=str(self.files / "blue.txt"))["items"][0]["title"], "blue.txt")

    def test_cancellation_preserves_old_file_atomically(self):
        target = self.write("red.txt", "red")
        self.engine.index()
        before = self.engine.items()["items"]
        target.write_text("blue " * 2000)
        self.engine.encoder.on_encode = self.engine.cancel_event.set
        result = self.engine.index()
        self.assertTrue(result["cancelled"])
        self.assertFalse(self.engine.indexing)
        self.assertEqual(before, self.engine.items()["items"])

    def test_model_failure_does_not_replace_good_vectors(self):
        target = self.write("red.txt", "red")
        self.engine.index()
        target.write_text("blue")
        def fail():
            raise ModelError("device failed")
        self.engine.encoder.on_encode = fail
        with self.assertRaises(ModelError):
            self.engine.index()
        self.assertFalse(self.engine.indexing)
        self.assertEqual(self.engine.items()["items"][0]["snippet"], "red")

    def test_hidden_cache_venv_and_symlink_exclusions(self):
        self.write("ordinary.txt", "red")
        self.write(".secret.txt", "blue")
        self.write(".ssh/key.txt", "blue")
        self.write("node_modules/library.txt", "blue")
        self.write("venv/library.txt", "blue")
        self.write("application.app/Contents/item.txt", "blue")
        (self.files / "link.txt").symlink_to(self.files / "ordinary.txt")
        self.engine.index()
        self.assertEqual([item["title"] for item in self.engine.items()["items"]], ["ordinary.txt"])

    def test_root_deduplication_removal_and_validation(self):
        self.write("a.txt", "red")
        nested = self.files / "nested"
        nested.mkdir()
        self.engine.configure([str(nested), str(self.files), str(self.files)])
        self.assertEqual(self.engine.status()["roots"], [str(self.files)])
        self.engine.index()
        result = self.engine.remove_root(str(self.files))
        self.assertEqual(result["indexedCount"], 0)
        self.assertEqual(result["deletedPaths"], [str(self.files / "a.txt")])
        with self.assertRaises(UserError):
            self.engine.configure([str(self.files / "missing")])
        with self.assertRaises(UserError):
            self.engine.reserve_index()

    def test_paginated_items_are_representative_per_file(self):
        self.write("one.txt", "red " * 2000)
        self.write("two.txt", "blue")
        self.engine.index()
        first = self.engine.items(limit=1)
        second = self.engine.items(offset=first["nextOffset"], limit=1)
        self.assertEqual(first["total"], 2)
        self.assertGreater(self.engine.status()["chunkCount"], 2)
        self.assertIsNone(second["nextOffset"])
        self.assertNotEqual(first["items"][0]["id"], second["items"][0]["id"])

    def test_changed_model_version_requires_reindex(self):
        self.write("a.txt", "red")
        self.engine.index()
        self.engine.db.execute("UPDATE files SET model_key='old-revision'")
        self.engine.db.commit()
        self.assertEqual(self.engine.status()["indexedCount"], 0)
        self.assertEqual(self.engine.items()["items"], [])
        self.assertEqual(self.engine.index()["processed"], 1)

    def test_inaccessible_folder_does_not_prune_good_index(self):
        target = self.write("protected/item.txt", "red")
        self.engine.index()
        def inaccessible_walk(root, followlinks, onerror):
            onerror(PermissionError(13, "Permission denied", str(target.parent)))
            return iter([])
        with patch("docufind.os.walk", inaccessible_walk):
            self.engine.index()
        self.assertEqual(self.engine.status()["indexedCount"], 1)

    def test_blank_file_skipped_and_later_file_indexed(self):
        self.write("blank.txt", " \n" * 10000)
        self.write("red.txt", "red")
        result = self.engine.index()
        # A blank file isn't a failure: it has nothing to index, and isn't read again until it changes.
        self.assertEqual(result["failed"], 0)
        self.assertEqual(result["processed"], 1)
        self.assertEqual(self.engine.index_metrics["emptyFiles"], 1)
        self.assertEqual(self.engine.index()["unchanged"], 2)


class AdapterTests(unittest.TestCase):
    def test_core_ml_model_downloads_once_checks_once_and_normalizes(self):
        calls = {"checks": 0, "loads": 0}
        agreement = {"value": 0.999}

        class OmniModel:
            manifest = {"check": {"minimumAgreement": 0.995}}
            def __init__(self, folder, progress=None):
                calls["loads"] += 1
                self.folder = folder
                if progress:
                    progress("text_first", 0.0, 0.6)
                    progress("vision", 0.6, 0.4)
            def self_check(self):
                calls["checks"] += 1
                return agreement["value"]
            def encode_texts(self, texts):
                return [[3.0, 4.0] for _ in texts]
            def encode_image(self, image):
                return [0.0, 2.0]
            def encode_audio(self, samples, rate):
                calls["rate"] = rate
                return [5.0, 0.0]

        import numpy as np
        state = {"downloaded": False}
        def download(cache, report):
            state["downloaded"] = True
            model_download.folder(cache).mkdir(parents=True, exist_ok=True)
            report(10, 10)
        with tempfile.TemporaryDirectory() as directory, patch("docufind.missing_dependencies", return_value=[]), \
                patch("docufind.neural_engine_available", return_value=(True, "")), patch.dict(sys.modules, {"omni_coreml": types.SimpleNamespace(OmniModel=OmniModel)}), \
                patch("docufind.model_download.verified", side_effect=lambda cache: state["downloaded"]), \
                patch("docufind.model_download.download", side_effect=download) as fetched:
            cache = Path(directory) / "models"
            events = []
            encoder = CoreMLEncoder("auto", cache, events.append)
            vectors = encoder.encode(["hello", object(), {"array": np.zeros(16), "sampling_rate": 44100}, "again"])
            np.testing.assert_allclose(vectors, [[0.6, 0.8], [0.0, 1.0], [1.0, 0.0], [0.6, 0.8]], atol=1e-7)
            self.assertEqual(calls["rate"], 44100)
            self.assertEqual(fetched.call_count, 1)
            self.assertTrue(any(event.get("stage") == "download" for event in events))
            self.assertTrue(encoder.check_marker.is_file())
            # Preparation reports a rising fraction for the setup bar, naming each part, and ends at 1 once checked.
            preparation = [event for event in events if event.get("stage") == "model" and "progress" in event]
            fractions = [event["progress"] for event in preparation]
            self.assertEqual(fractions, sorted(fractions))
            self.assertEqual(fractions[-1], 1.0)
            self.assertEqual({event["part"] for event in preparation}, {"text", "photos", "checking it", "ready"})
            # Later launches use the checked download without fetching or checking again.
            CoreMLEncoder("auto", cache, lambda _: None).encode(["cached query"])
            self.assertEqual((fetched.call_count, calls["checks"], calls["loads"]), (1, 1, 2))
            encoder.check_marker.unlink()
            agreement["value"] = 0.9
            with self.assertRaisesRegex(ModelError, "differ from the published ones"):
                CoreMLEncoder("auto", cache, lambda _: None).load()
            with patch("docufind.neural_engine_available", return_value=(False, "DocuFind needs macOS 15 or later on Apple silicon.")):
                with self.assertRaisesRegex(ModelError, "macOS 15"):
                    CoreMLEncoder("auto", cache, lambda _: None).load()

    def test_audio_windows_cover_end_without_duplicate_tail(self):
        self.assertEqual(list(audio_spans(61 * 16000, 16000)), [(0, 480000), (400000, 880000), (800000, 976000)])
        self.assertEqual(list(audio_spans(30, 1)), [(0, 30)])
        self.assertEqual(list(audio_spans(0, 16000)), [])

    def test_text_chunks_overlap_and_are_bounded(self):
        text = "one two three four " * 1000
        chunks = list(split_text(text))
        self.assertTrue(all(len(chunk) <= 1800 for chunk, _ in chunks))
        self.assertEqual(chunks[0][1], 0)
        self.assertLess(chunks[1][1], len(chunks[0][0]))

    def test_rolling_text_reader_preserves_terminal_content(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "long.txt"
            path.write_text("red " * 20000 + "terminal_unique_phrase")
            chunks = list(text_file_chunks(path))
            self.assertIn("terminal_unique_phrase", chunks[-1].payload)
            self.assertTrue(all(len(chunk.payload) <= 1800 for chunk in chunks))

    def test_invalid_embeddings_rejected(self):
        for vector in ([], [0, 0], [float("nan"), 1], [float("inf")]):
            with self.assertRaises(ModelError):
                normalized(vector)


class ProtocolTests(unittest.TestCase):
    def test_status_and_settings_work_without_model_or_network(self):
        with tempfile.TemporaryDirectory() as directory:
            backend = Path(__file__).resolve().parents[1]
            process = subprocess.Popen([sys.executable, str(backend / "worker.py"), "--data-dir", str(Path(directory) / "data")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                def request(value):
                    process.stdin.write(json.dumps(value) + "\n")
                    process.stdin.flush()
                    return json.loads(process.stdout.readline())
                status = request({"id": "s", "action": "status"})
                self.assertEqual(status["event"], "result")
                self.assertFalse(status["modelReady"])
                self.assertEqual(status["modelRevision"], MODEL_REVISION)
                configured = request({"id": "c", "action": "configure", "roots": [directory]})
                self.assertEqual(configured["roots"], [str(Path(directory).resolve())])
                self.assertFalse(configured["modelReady"])
                self.assertEqual(request({"id": "e", "action": "search", "text": "red"})["items"], [])
                self.assertEqual(request({"id": "bad", "action": "unknown"})["event"], "error")
                self.assertTrue(request({"id": "q", "action": "shutdown"})["shuttingDown"])
                self.assertEqual(process.wait(timeout=10), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdin.close()
                process.stdout.close()
                process.stderr.close()


class ExtractionTests(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec("PIL"), "Pillow required for image decoding")
    def test_image_decodes_content_and_limits_resolution(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.png"
            Image.new("RGB", (2400, 1200), (255, 0, 0)).save(path)
            chunks = list(extract(path, "image"))
            self.assertEqual(len(chunks), 1)
            # Resized once, from the original, to fit 768 with sides in multiples of 32; the snippet keeps the original size.
            self.assertEqual(chunks[0].payload.size, (768, 384))
            self.assertEqual(chunks[0].payload.getpixel((0, 0)), (255, 0, 0))
            self.assertIn("2400 × 1200", chunks[0].snippet)
            import omni_coreml
            self.assertEqual(omni_coreml.resize_image(chunks[0].payload).size, (768, 384))

    @unittest.skipUnless(importlib.util.find_spec("pypdf"), "pypdf required for PDF extraction")
    def test_pdf_extracts_text_with_page_location(self):
        from pypdf import PdfWriter
        from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.pdf"
            writer = PdfWriter()
            page = writer.add_blank_page(width=300, height=300)
            font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"), NameObject("/BaseFont"): NameObject("/Helvetica")})
            page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)})})
            content = DecodedStreamObject()
            content.set_data(b"BT /F1 12 Tf 20 250 Td (A red bicycle by the river) Tj ET")
            page[NameObject("/Contents")] = writer._add_object(content)
            writer.write(path)
            chunks = list(extract(path, "text"))
            self.assertIn("red bicycle", chunks[0].payload)
            self.assertTrue(chunks[0].location.startswith("Page 1"))

    @unittest.skipUnless(importlib.util.find_spec("soundfile"), "soundfile required for audio decoding")
    def test_audio_streams_complete_recording_as_overlapping_windows(self):
        import numpy as np
        import soundfile as sf
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.wav"
            sf.write(path, np.zeros((61 * 16000, 2), dtype=np.float32), 16000)
            chunks = list(extract(path, "audio"))
            self.assertEqual(len(chunks), 3)
            self.assertEqual([len(chunk.payload["array"]) for chunk in chunks], [480000, 480000, 176000])
            self.assertEqual(chunks[0].payload["array"].ndim, 1)
            self.assertEqual(chunks[-1].location, "50.0–61.0 seconds")


    @unittest.skipUnless(importlib.util.find_spec("soundfile"), "soundfile required for audio decoding")
    def test_audio_preview_returns_peaks_and_matched_passage(self):
        import numpy as np
        import soundfile as sf
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tone.wav"
            samples = np.concatenate([np.zeros(16000 * 2), 0.5 * np.ones(16000 * 2)]).astype(np.float32)
            sf.write(path, samples, 16000)
            engine = Engine(Path(directory) / "data", encoder_factory=TestEncoder)
            try:
                self.assertIsNone(engine.audio_preview(str(path), 1.0, 3.0, bins=40)["clip"])
                self.assertFalse((Path(directory) / "data" / "previews").exists())
                preview = engine.audio_preview(str(path), 1.0, 3.0, bins=40, clip=True)
                self.assertAlmostEqual(preview["duration"], 4.0)
                self.assertEqual(len(preview["peaks"]), 40)
                self.assertEqual(preview["peaks"][0], 0.0)
                self.assertEqual(preview["peaks"][-1], 1.0)
                self.assertEqual((preview["clipStart"], preview["clipEnd"]), (1.0, 3.0))
                clip, rate = sf.read(preview["clip"])
                self.assertEqual((len(clip), rate), (32000, 16000))
                self.assertTrue(Path(preview["clip"]).is_relative_to((Path(directory) / "data").resolve()))
                with self.assertRaises(UserError):
                    engine.audio_preview(str(Path(directory) / "missing.wav"))
            finally:
                engine.close()

if __name__ == "__main__":
    unittest.main()
