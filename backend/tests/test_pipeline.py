"""Pipeline invariants: true batching must preserve atomicity and query semantics."""
from __future__ import annotations

from array import array
import importlib.util
import os
import sqlite3
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from docufind import Cancelled, Chunk, CoreMLEncoder, Engine, MODEL_KEY, ModelError, UserError, normalized


class RecordingEncoder:
    def __init__(self, device, cache, progress):
        self.device, self.loaded = "ane", True
        self.calls = []
        self.dispatches = []
        self.batch_sizes = {"text": 3, "image": 3, "audio": 1}
        self.on_encode = None
        self.dimensions = 3
        self.model_key = MODEL_KEY

    def batch_size_for(self, kind):
        return self.batch_sizes[kind]

    def encode(self, inputs):
        self.dispatches.append(list(inputs))
        kind = "image" if str(inputs[0]).startswith("image:") else "audio" if str(inputs[0]).startswith("audio:") else "text"
        size = self.batch_size_for(kind)
        result = []
        for start in range(0, len(inputs), size):
            microbatch = list(inputs[start:start + size])
            self.calls.append(microbatch)
            if self.on_encode:
                self.on_encode(microbatch)
            result.extend(normalized([str(value).lower().count("red"), str(value).lower().count("blue"), 0.01] + [0.1] * (self.dimensions - 3)) for value in microbatch)
        return result


class PipelineFixture(unittest.TestCase):
    def setUp(self):
        # /private/tmp is intentionally excluded from whole-Mac indexing.
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.base = Path(self.tmp.name).resolve()
        self.files = self.base / "files"
        self.files.mkdir()
        self.engine = Engine(self.base / "data", encoder_factory=RecordingEncoder)
        self.engine.configure([str(self.files)])

    def tearDown(self):
        self.engine.close()
        self.tmp.cleanup()

    def write(self, name, text="red"):
        path = self.files / name
        path.write_text(text)
        return path

    def snapshot(self):
        return [tuple(row) for row in self.engine.db.execute("SELECT * FROM chunks ORDER BY id")]

    def assert_clean_staging(self):
        self.assertEqual(self.engine.db.execute("SELECT COUNT(*) FROM staging").fetchone()[0], 0)
        self.assertFalse(self.engine.db.in_transaction)
        self.assertFalse(self.engine.indexing)


class PipelineTests(PipelineFixture):
    def test_device_and_neural_engine_settings_from_older_apps_are_ignored(self):
        encoder = self.engine._encoder(lambda event: None)
        calls = []
        encoder.unload = lambda: calls.append("unload")
        self.engine._query_cache[("synthetic",)] = (1.0, 0.0)
        # The model always runs on the Neural Engine, so these choices keep the loaded model and its cached queries.
        for device, neural in (("auto", None), ("mps", True), ("cpu", False)):
            self.engine.configure([str(self.files)], device, neural=neural)
        self.assertIs(self.engine.encoder, encoder)
        self.assertEqual(calls, [])
        self.assertEqual(self.engine._query_cache, {("synthetic",): (1.0, 0.0)})
        self.assertEqual(self.engine.status()["device"], "ane")

    def test_close_unloads_encoder_once_and_is_idempotent(self):
        encoder = self.engine._encoder(lambda event: None)
        calls = []
        encoder.unload = lambda: calls.append("unload")
        self.engine._query_cache[("synthetic",)] = (1.0, 0.0)
        self.engine.close()
        self.engine.close()
        self.assertEqual(calls, ["unload"])
        self.assertIsNone(self.engine.encoder)
        self.assertEqual(self.engine._query_cache, {})
        with self.assertRaises(sqlite3.ProgrammingError):
            self.engine.db.execute("SELECT 1")

    def test_cleanup_accepts_legacy_encoders_without_callable_unload(self):
        encoder = self.engine._encoder(lambda event: None)
        self.assertFalse(hasattr(encoder, "unload"))
        self.engine._release_encoder()
        encoder = self.engine._encoder(lambda event: None)
        encoder.unload = "not a cleanup function"
        self.engine.close()
        self.engine.close()
        self.assertIsNone(self.engine.encoder)

    def test_close_still_closes_database_when_encoder_cleanup_raises(self):
        encoder = self.engine._encoder(lambda event: None)
        calls = []

        def fail():
            calls.append("unload")
            raise RuntimeError("cleanup failed")

        encoder.unload = fail
        with self.assertRaisesRegex(RuntimeError, "cleanup failed"):
            self.engine.close()
        self.engine.close()
        self.assertEqual(calls, ["unload"])
        self.assertIsNone(self.engine.encoder)
        with self.assertRaises(sqlite3.ProgrammingError):
            self.engine.db.execute("SELECT 1")

    def test_same_size_atomic_replacement_with_preserved_mtime_is_reindexed(self):
        path = self.write("document.txt", "red garden")
        self.engine.index()
        original = path.stat()
        replacement = self.write("replacement.bin", "blue ocean")
        os.utime(replacement, ns=(original.st_atime_ns, original.st_mtime_ns))
        replacement.replace(path)
        self.assertEqual((path.stat().st_mtime_ns, path.stat().st_size), (original.st_mtime_ns, original.st_size))
        result = self.engine.index()
        self.assertEqual((result["processed"], result["unchanged"], result["failed"]), (1, 0, 0))
        self.assertEqual(self.engine.db.execute("SELECT snippet FROM chunks WHERE path=?", (str(path),)).fetchone()[0], "blue ocean")
        self.assertTrue(self.engine.file_reuse.matches_signature(path, path.stat()))
        self.assert_clean_staging()

    def test_legacy_row_without_reuse_metadata_remains_unchanged_without_inference(self):
        path = self.write("legacy.txt", "red garden")
        self.engine.index()
        self.engine.db.execute("DELETE FROM file_reuse WHERE path=?", (str(path),))
        self.engine.db.commit()
        self.engine.encoder.calls.clear()
        with patch("docufind.extract", side_effect=AssertionError("Legacy unchanged file should not decode")):
            result = self.engine.index()
        self.assertEqual((result["processed"], result["unchanged"], result["failed"]), (0, 1, 0))
        self.assertEqual(self.engine.encoder.calls, [])
        self.assert_clean_staging()

    def test_encoder_cancellation_preserves_pending_files_and_unpruned_deletions(self):
        paths = [self.write(f"{number}.txt", f"red original unique {number}") for number in range(3)]
        self.engine.index()
        before = self.snapshot()
        paths[-1].unlink()
        for path in paths[:-1]:
            path.write_text(f"blue changed unique {path.stem}")

        def cancel(inputs):
            raise Cancelled()

        self.engine.encoder.on_encode = cancel
        result = self.engine.index()
        self.assertTrue(result["cancelled"])
        self.assertEqual(result["failed"], 0)
        self.assertEqual(self.snapshot(), before)
        self.assert_clean_staging()

    def test_scan_skips_metadata_reads_for_unsupported_files(self):
        supported = self.write("supported.txt", "red")
        unsupported = [self.write(f"asset-{number}.bin", "not indexed") for number in range(40)]
        self.write(".hidden.txt", "not indexed")
        linked = self.files / "linked.txt"
        linked.symlink_to(supported)
        inspected = []
        original = Path.is_symlink
        def inspect(path):
            inspected.append(path)
            return original(path)
        with patch.object(Path, "is_symlink", inspect):
            found = list(self.engine._walk(lambda event: None, []))
        self.assertEqual(found, [supported])
        self.assertEqual(set(inspected), {supported, linked})
        self.assertTrue(set(unsupported).isdisjoint(inspected))

    def test_status_reports_the_neural_engine_without_loading_the_model(self):
        self.engine.encoder_factory = CoreMLEncoder
        with patch("docufind.missing_dependencies", return_value=[]), patch("docufind.neural_engine_available", return_value=(True, "")), \
                patch.object(CoreMLEncoder, "load", side_effect=AssertionError("Status must not load the model")) as load:
            status = self.engine.status()
        self.assertEqual(status["device"], "ane")
        self.assertTrue(status["ready"])
        self.assertFalse(status["modelReady"])
        self.assertFalse(status["modelDownloaded"])
        self.assertIsNone(self.engine.encoder)
        load.assert_not_called()

    def test_status_explains_a_mac_without_the_neural_engine_path(self):
        self.engine.encoder_factory = CoreMLEncoder
        with patch("docufind.missing_dependencies", return_value=[]), \
                patch("docufind.neural_engine_available", return_value=(False, "DocuFind needs macOS 15 or later on Apple silicon.")):
            status = self.engine.status()
        self.assertFalse(status["ready"])
        self.assertIn("macOS 15", status["error"])

    def test_short_documents_batch_across_files_in_order(self):
        for number in range(8):
            path = self.write(f"{number}.txt", f"red document {number}")
            os.utime(path, (1_700_000_000 + number, 1_700_000_000 + number))
        result = self.engine.index()
        self.assertEqual(result["processed"], 8)
        self.assertEqual([len(call) for call in self.engine.encoder.calls], [3, 3, 2])
        self.assertEqual([len(call) for call in self.engine.encoder.dispatches], [8])
        self.assertEqual([value for call in self.engine.encoder.calls for value in call], [f"red document {number}" for number in reversed(range(8))])  # Newest first.
        self.assertEqual(self.engine.status()["chunkCount"], 8)
        self.assert_clean_staging()

    def test_text_lookahead_has_at_most_64_files(self):
        for number in range(65):
            self.write(f"{number:03}.txt", f"red {number}")
        encoder = self.engine._encoder(lambda event: None)
        encoder.batch_sizes["text"] = 1000
        result = self.engine.index()
        self.assertEqual(result["processed"], 65)
        self.assertEqual([len(call) for call in encoder.dispatches], [64, 1])
        self.assert_clean_staging()

    def test_images_and_documents_use_separate_cross_file_batches(self):
        for number in range(5):
            self.write(f"image-{number}.png", f"image {number}")
            self.write(f"text-{number}.txt", f"text {number}")
        def content(path, kind):
            yield Chunk(f"{kind}:{path.name}", path.name, kind)
        with patch("docufind.extract", content):
            self.engine.index()
        calls = self.engine.encoder.calls
        self.assertEqual([len(call) for call in calls], [3, 3, 2, 2])
        self.assertTrue(all(len({value.split(":")[0] for value in call}) == 1 for call in calls))
        self.assertEqual(sum(len(call) for call in calls), 10)

    def test_long_file_batches_are_bounded_ordered_and_commit_once(self):
        self.write("long.txt")
        produced = []
        at_encode = []
        statements = []
        def content(path, kind):
            for number in range(35):
                produced.append(number)
                yield Chunk(f"red {number}", f"chunk {number}", f"offset {number}")
        encoder = self.engine._encoder(lambda event: None)
        encoder.on_encode = lambda inputs: at_encode.append(len(produced))
        self.engine.db.set_trace_callback(statements.append)
        with patch("docufind.extract", content), patch.dict(os.environ, {"DOCUFIND_PREFETCH": "0"}):
            self.engine.index()
        self.engine.db.set_trace_callback(None)
        self.assertEqual([len(call) for call in encoder.calls], [3] * 11 + [2])
        self.assertEqual(at_encode[0], 13)
        self.assertTrue(all(count <= max(13, 3 * (index + 1)) for index, count in enumerate(at_encode)))
        rows = self.engine.db.execute("SELECT position,snippet FROM chunks ORDER BY position").fetchall()
        self.assertEqual([tuple(row) for row in rows], [(i, f"chunk {i}") for i in range(35)])
        # Final publish, pruning, and cleanup only; never one commit per chunk.
        self.assertLessEqual(statements.count("COMMIT"), 3)
        self.assert_clean_staging()

    def test_small_multichunk_documents_share_full_batches_atomically(self):
        paths = [self.write(f"{number}.pdf", f"red unique {number}") for number in range(4)]
        def content(path, kind):
            for position in range(2):
                yield Chunk(f"red {path.stem}:{position}", f"{path.stem}:{position}", str(position))
        with patch("docufind.extract", content):
            result = self.engine.index()
        self.assertEqual([len(call) for call in self.engine.encoder.dispatches], [8])
        self.assertEqual([len(call) for call in self.engine.encoder.calls], [3, 3, 2])
        self.assertEqual((result["processed"], result["chunkCount"]), (4, 8))
        for path in paths:
            rows = self.engine.db.execute("SELECT position,snippet FROM chunks WHERE path=? ORDER BY position", (str(path),)).fetchall()
            self.assertEqual([tuple(row) for row in rows], [(number, f"{path.stem}:{number}") for number in range(2)])
        self.assertEqual(result["indexMetrics"]["embeddedChunks"], 8)
        self.assertEqual(result["indexMetrics"]["writtenChunks"], 8)
        self.assert_clean_staging()

    def test_multichunk_cross_file_cancel_preserves_entire_previous_files(self):
        paths = [self.write(f"{number}.pdf", f"red old unique {number}") for number in range(3)]
        def content(path, kind):
            for position in range(2):
                text = path.read_text()
                yield Chunk(f"{text}:{position}", f"{text}:{position}", str(position))
        with patch("docufind.extract", content):
            self.engine.index()
            before = self.snapshot()
            for path in paths:
                path.write_text(f"blue new unique {path.stem}")
            self.engine.encoder.on_encode = lambda inputs: self.engine.cancel_event.set()
            result = self.engine.index()
        self.assertTrue(result["cancelled"])
        self.assertEqual(self.snapshot(), before)
        self.assert_clean_staging()

    def test_multichunk_changed_file_keeps_all_its_previous_chunks(self):
        paths = [self.write(f"{number}.pdf", f"red old unique {number}") for number in range(3)]
        def content(path, kind):
            for position in range(2):
                text = path.read_text()
                yield Chunk(f"{text}:{position}", f"{text}:{position}", str(position))
        with patch("docufind.extract", content):
            self.engine.index()
            before = [tuple(row) for row in self.engine.db.execute("SELECT * FROM chunks WHERE path=? ORDER BY position", (str(paths[1]),))]
            for path in paths:
                path.write_text(f"blue new unique {path.stem}")
            self.engine.encoder.on_encode = lambda inputs: paths[1].write_text("changed again while queued")
            result = self.engine.index()
        after = [tuple(row) for row in self.engine.db.execute("SELECT * FROM chunks WHERE path=? ORDER BY position", (str(paths[1]),))]
        self.assertEqual((result["processed"], result["failed"]), (2, 1))
        self.assertEqual(after, before)
        self.assert_clean_staging()

    def test_long_file_prefetch_overlaps_inference_and_closes_extractor(self):
        self.write("long.txt")
        inference_started, decoded_ahead, closed = threading.Event(), threading.Event(), threading.Event()
        produced = []
        def content(path, kind):
            try:
                for number in range(36):
                    if number == 13:
                        self.assertTrue(inference_started.wait(1), "Decoder should overlap inference after the bounded initial lookahead")
                    produced.append(number)
                    if number == 14:
                        decoded_ahead.set()
                    yield Chunk(f"red {number}", str(number), str(number))
            finally:
                closed.set()
        encoder = self.engine._encoder(lambda event: None)
        def infer(inputs):
            if len(encoder.calls) == 4:
                inference_started.set()
                self.assertTrue(decoded_ahead.wait(1), "Next chunks were not decoded during inference")
            self.assertLessEqual(len(produced), max(13, len(encoder.calls) * 3 + 4))
        encoder.on_encode = infer
        with patch("docufind.extract", content):
            result = self.engine.index()
        self.assertEqual(result["chunkCount"], 36)
        self.assertTrue(result["indexMetrics"]["prefetchEnabled"])
        self.assertTrue(closed.wait(1))
        self.assert_clean_staging()

    def test_prefetch_failure_rolls_back_file_and_closes_source(self):
        path = self.write("long.txt", "red old")
        self.engine.index()
        before = self.snapshot()
        path.write_text("blue changed")
        closed = threading.Event()
        def content(path, kind):
            try:
                for number in range(30):
                    yield Chunk(f"blue {number}", str(number), str(number))
                raise UserError("decoder failed after several chunks")
            finally:
                closed.set()
        with patch("docufind.extract", content):
            result = self.engine.index()
        self.assertEqual((result["processed"], result["failed"]), (0, 1))
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(closed.wait(1))
        self.assert_clean_staging()

    def test_chunk_progress_metrics_are_content_free_and_increase(self):
        self.write("long.txt")
        def content(path, kind):
            for number in range(26):
                yield Chunk(f"red private fixture {number}", str(number), str(number))
        events = []
        with patch("docufind.extract", content):
            result = self.engine.index(events.append)
        steps = [event for event in events if "fileChunksCompleted" in event and "item" not in event]
        self.assertEqual([event["fileChunksCompleted"] for event in steps], [3, 6, 9, 12, 15, 18, 21, 24, 26])
        self.assertEqual(result["indexMetrics"]["completedFiles"], 1)
        self.assertEqual(result["indexMetrics"]["embeddedChunks"], 26)
        self.assertEqual(result["indexMetrics"]["decodedChunks"], 26)
        for field in ("scanSeconds", "extractionSeconds", "inferenceSeconds", "writeSeconds", "elapsedSeconds"):
            self.assertGreater(result["indexMetrics"][field], 0)
        self.assertNotIn("private", str(result["indexMetrics"]))

    def test_cancel_after_later_batch_keeps_entire_old_file(self):
        path = self.write("long.txt", "red old")
        self.engine.index()
        before = self.snapshot()
        path.write_text("blue new")
        encoder = self.engine.encoder
        encoder.calls.clear()
        encoder.on_encode = lambda inputs: self.engine.cancel_event.set() if len(encoder.calls) == 2 else None
        def content(path, kind):
            for number in range(30):
                yield Chunk(f"blue {number}", str(number), str(number))
        with patch("docufind.extract", content):
            result = self.engine.index()
        self.assertTrue(result["cancelled"])
        self.assertEqual(self.snapshot(), before)
        self.assert_clean_staging()

    def test_dimension_change_in_later_batch_rolls_back_whole_file(self):
        path = self.write("long.txt", "red old")
        self.engine.index()
        before = self.snapshot()
        path.write_text("blue new")
        encoder = self.engine.encoder
        encoder.calls.clear()
        encoder.on_encode = lambda inputs: setattr(encoder, "dimensions", 4) if len(encoder.calls) == 2 else None
        def content(path, kind):
            for number in range(30):
                yield Chunk(f"blue {number}", str(number), str(number))
        with patch("docufind.extract", content):
            with self.assertRaisesRegex(ModelError, "inconsistent embedding dimensions"):
                self.engine.index()
        self.assertEqual(self.snapshot(), before)
        self.assert_clean_staging()

    def test_cross_file_cancel_preserves_all_old_files_and_deletions(self):
        paths = [self.write(f"{number}.txt", "red old") for number in range(4)]
        self.engine.index()
        before = self.snapshot()
        paths[-1].unlink()
        for path in paths[:-1]:
            path.write_text("blue changed")
        self.engine.encoder.on_encode = lambda inputs: self.engine.cancel_event.set()
        result = self.engine.index()
        self.assertTrue(result["cancelled"])
        self.assertEqual(self.snapshot(), before)
        self.assert_clean_staging()

    def test_bad_batch_cardinality_keeps_previous_cross_file_vectors(self):
        paths = [self.write(f"{number}.txt", "red old") for number in range(3)]
        self.engine.index()
        before = self.snapshot()
        for path in paths:
            path.write_text("blue new")
        with patch.object(self.engine.encoder, "encode", return_value=[[1, 0, 0]]):
            with self.assertRaisesRegex(ModelError, "wrong number"):
                self.engine.index()
        self.assertEqual(self.snapshot(), before)
        self.assert_clean_staging()

    def test_batch_model_failure_does_not_publish_any_queued_file(self):
        paths = [self.write(f"{number}.txt", "red old") for number in range(3)]
        self.engine.index()
        before = self.snapshot()
        for path in paths:
            path.write_text("blue new")
        with patch.object(self.engine.encoder, "encode", side_effect=ModelError("device failed")):
            with self.assertRaisesRegex(ModelError, "device failed"):
                self.engine.index()
        self.assertEqual(self.snapshot(), before)
        self.assert_clean_staging()

    def test_file_changed_during_cross_file_encode_keeps_its_old_vectors(self):
        paths = [self.write(f"{number}.txt", "red old") for number in range(3)]
        self.engine.index()
        before = {row[1]: row for row in self.snapshot()}
        for path in paths:
            path.write_text("blue new")
        self.engine.encoder.on_encode = lambda inputs: paths[1].write_text("blue changed again while indexing")
        result = self.engine.index()
        self.assertEqual((result["processed"], result["failed"]), (2, 1))
        after = {row[1]: row for row in self.snapshot()}
        self.assertEqual(before[str(paths[1])], after[str(paths[1])])
        self.assertNotEqual(before[str(paths[0])], after[str(paths[0])])
        self.assert_clean_staging()

    def test_atomic_replacement_with_same_mtime_size_keeps_queued_old_vectors(self):
        paths = [self.write(f"{number}.txt", "red old") for number in range(3)]
        self.engine.index()
        before = {row[1]: row for row in self.snapshot()}
        for path in paths:
            path.write_text("red!")
        def replace(inputs):
            original = paths[0].stat()
            replacement = self.files / "replacement.tmp"
            replacement.write_text("blue")
            os.utime(replacement, ns=(original.st_atime_ns, original.st_mtime_ns))
            replacement.replace(paths[0])
        self.engine.encoder.on_encode = replace
        result = self.engine.index()
        after = {row[1]: row for row in self.snapshot()}
        self.assertEqual((result["processed"], result["failed"]), (2, 1))
        self.assertEqual(before[str(paths[0])], after[str(paths[0])])
        self.assert_clean_staging()

    def test_atomic_replacement_same_metadata_rolls_back_long_file(self):
        path = self.write("long.txt", "red old")
        self.engine.index()
        before = self.snapshot()
        path.write_text("red!")
        replaced = []
        def replace(inputs):
            if replaced:
                return
            original = path.stat()
            replacement = self.files / "replacement.tmp"
            replacement.write_text("blue")
            os.utime(replacement, ns=(original.st_atime_ns, original.st_mtime_ns))
            replacement.replace(path)
            replaced.append(True)
        self.engine.encoder.on_encode = replace
        def content(path, kind):
            for number in range(30):
                yield Chunk(f"red {number}", str(number), str(number))
        with patch("docufind.extract", content):
            result = self.engine.index()
        self.assertEqual((result["processed"], result["failed"]), (0, 1))
        self.assertEqual(self.snapshot(), before)
        self.assert_clean_staging()

    def test_cleanup_error_still_clears_indexing_flag(self):
        path = self.write("file.txt", "red old")
        self.engine.index()
        before = self.snapshot()
        path.write_text("blue changed")
        self.engine.encoder.on_encode = lambda inputs: self.engine.cancel_event.set()
        with patch.object(self.engine, "_clear_staging", side_effect=OSError("cleanup IO failure")):
            with self.assertRaisesRegex(OSError, "cleanup IO failure"):
                self.engine.index()
        self.assertFalse(self.engine.indexing)
        self.assertEqual(self.snapshot(), before)

    def test_no_op_update_does_not_even_create_encoder(self):
        self.write("same.txt")
        self.engine.index()
        reopened = Engine(self.base / "data", encoder_factory=RecordingEncoder)
        try:
            with patch.object(reopened, "_encoder", side_effect=AssertionError("No inference required")):
                self.assertEqual(reopened.index()["unchanged"], 1)
            self.assertIsNone(reopened.encoder)
        finally:
            reopened.close()

    def test_decode_failure_does_not_discard_other_queued_files(self):
        for name in ("a.txt", "b.txt", "c.txt"):
            self.write(name)
        def content(path, kind):
            if path.name == "b.txt":
                raise UserError("broken document")
            yield Chunk("red", path.name, "Content")
        with patch("docufind.extract", content):
            result = self.engine.index()
        self.assertEqual((result["processed"], result["failed"]), (2, 1))
        self.assertEqual([len(call) for call in self.engine.encoder.calls], [2])


@unittest.skipUnless(importlib.util.find_spec("numpy"), "NumPy required for exact search")
class QueryCacheTests(PipelineFixture):
    def setUp(self):
        super().setUp()
        self.write("red.txt", "red red")
        self.engine.index()
        self.engine.encoder.calls.clear()

    def test_same_query_filters_and_limits_reuse_embedding(self):
        self.engine.search(text=" red ", kind="all", limit=1)
        self.engine.search(text="red", kind="image", limit=20)
        self.engine.search(text="red", kind="text", limit=100)
        self.assertEqual(self.engine.encoder.calls, [["red"]])

    def test_query_file_signature_invalidates_even_same_size_mtime_replace(self):
        path = self.write("query.txt", "red!")
        original = path.stat()
        self.engine.search(path=str(path))
        self.engine.search(path=str(path), kind="audio")
        self.assertEqual(len(self.engine.encoder.calls), 1)
        replacement = self.write("replacement.txt", "blue")
        os.utime(replacement, ns=(original.st_atime_ns, original.st_mtime_ns))
        replacement.replace(path)
        self.engine.search(path=str(path))
        self.assertEqual(len(self.engine.encoder.calls), 2)
        path.unlink()
        with self.assertRaises(UserError):
            self.engine.search(path=str(path))

    def test_profile_and_dimensions_changes_invalidate_query(self):
        self.engine.search(text="red")
        self.engine.encoder.model_key += ":new-profile"
        self.engine.db.execute("UPDATE files SET model_key=?", (self.engine.encoder.model_key,))
        self.engine.db.commit()
        self.engine.search(text="red")
        self.assertEqual(len(self.engine.encoder.calls), 2)
        self.engine.encoder.dimensions = 4
        self.engine.search(text="red")
        self.assertEqual(len(self.engine.encoder.calls), 3)

    def test_cache_is_bounded_lru(self):
        for number in range(33):
            self.engine.search(text=f"red {number}")
        self.assertEqual(len(self.engine._query_cache), 32)
        count = len(self.engine.encoder.calls)
        self.engine.search(text="red 32")
        self.assertEqual(len(self.engine.encoder.calls), count)
        self.engine.search(text="red 0")
        self.assertEqual(len(self.engine.encoder.calls), count + 1)

    def test_query_file_uses_bounded_batches(self):
        path = self.write("query.txt")
        def content(path, kind):
            for number in range(8):
                yield Chunk(f"red {number}", str(number), str(number))
        with patch("docufind.extract", content):
            self.engine.search(path=str(path))
        self.assertEqual([len(call) for call in self.engine.encoder.calls], [3, 3, 2])

    def test_identical_copies_fold_without_fingerprints(self):
        vector = array("f", normalized([1, 0, 0.01])).tobytes()
        passage = "Gather dry wood and kindling first, then light the fire from below and keep water close by."
        copies = [str(self.files / name) for name in ("a/notes.txt", "b/notes copy.txt")]
        other = str(self.files / "c/other.txt")
        with self.engine.db:
            self.engine.db.execute("DELETE FROM chunks")
            self.engine.db.execute("DELETE FROM files")
            self.engine.db.executemany("INSERT INTO files VALUES (?,?,?,?,?)",
                                       [(copies[0], "text", 0, 500, MODEL_KEY), (copies[1], "text", 0, 500, MODEL_KEY), (other, "text", 0, 900, MODEL_KEY)])
            self.engine.db.executemany("INSERT INTO chunks VALUES (?,?,?,?,?,?,?)",
                                       [(name, name, 0, passage, "Character 1", 3, vector) for name in copies + [other]])
        items = self.engine.search(text="campfire", limit=10)["items"]
        # Same size and passage: one result listing the copy. A different size stays its own result.
        self.assertEqual(len(items), 2)
        folded = next(item for item in items if item["path"] in copies)
        self.assertEqual(folded["copies"], [path for path in copies if path != folded["path"]])

    def test_exact_search_tie_order_is_stable_across_scan_blocks(self):
        vector = array("f", normalized([1, 0, 0.01])).tobytes()
        names = [str(self.files / f"{number:04}.txt") for number in range(1100)]
        with self.engine.db:
            self.engine.db.execute("DELETE FROM chunks")
            self.engine.db.execute("DELETE FROM files")
            self.engine.db.executemany("INSERT INTO files VALUES (?,?,?,?,?)", [(name, "text", 0, 0, MODEL_KEY) for name in reversed(names)])
            self.engine.db.executemany("INSERT INTO chunks VALUES (?,?,?,?,?,?,?)", [(name, name, 0, "red", "Content", 3, vector) for name in reversed(names)])
        result = self.engine.search(text="red", limit=10)
        self.assertEqual([item["path"] for item in result["items"]], names[:10])


if __name__ == "__main__":
    unittest.main()
