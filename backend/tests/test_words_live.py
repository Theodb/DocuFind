"""Exact words, text recognition, and live updates of changed paths."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from docufind import Engine, UserError, normalized
import ocr
from text_index import ExactQuery, excerpt, name_text

HAS_NUMPY = importlib.util.find_spec("numpy") is not None


class WordEncoder:
    """Vectors from a few words, so meaning and exact matches can be told apart."""
    words = ("red", "blue")

    def __init__(self, device, cache, progress):
        self.device, self.loaded, self.calls = "ane", True, 0

    def encode(self, inputs):
        self.calls += len(inputs)
        return [normalized([str(text).lower().count(word) for word in self.words] + [0.01]) for text in inputs]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.base = Path(self.tmp.name).resolve()
        self.files = self.base / "documents"
        self.files.mkdir()
        self.engine = Engine(self.base / "private", encoder_factory=WordEncoder)
        self.engine.configure([str(self.files)])

    def tearDown(self):
        self.engine.close()
        self.tmp.cleanup()

    def write(self, name, text, folder=None):
        path = (folder or self.files) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def paths(self, result):
        return [Path(item["path"]).name for item in result["items"]]


class ExactQueryTests(unittest.TestCase):
    def test_which_queries_count_as_typed_exactly(self):
        self.assertTrue(ExactQuery("INV-2024-0042").distinctive)
        self.assertTrue(ExactQuery("payment declined").distinctive)
        self.assertTrue(ExactQuery("Deschamps").distinctive)
        self.assertFalse(ExactQuery("invoice").distinctive)
        self.assertEqual(ExactQuery('the "blue whale" photo').required, ["blue whale"])
        self.assertEqual(ExactQuery("a very long description with far more than eight separate words in it").phrases, [])

    def test_names_split_at_separators_and_excerpt_centres_on_words(self):
        self.assertIn("tax return 2024 pdf", name_text("tax_return-2024.pdf"))
        text = "x " * 300 + "the code E-4012 appeared" + " y" * 300
        self.assertIn("E-4012", excerpt(text, "e-4012"))


@unittest.skipUnless(HAS_NUMPY, "NumPy required for vector search")
class ExactWordTests(Base):
    def test_exact_phrase_outranks_closer_meaning(self):
        self.write("near.txt", "red red red red, the closest in meaning")
        self.write("invoice.txt", "blue paper. Invoice INV-2024-0042 total 318.50 " + "filler " * 50)
        self.engine.index()
        result = self.engine.search("red INV-2024-0042")
        self.assertEqual(self.paths(result)[0], "near.txt")
        result = self.engine.search("INV-2024-0042")
        self.assertEqual(self.paths(result)[0], "invoice.txt")
        self.assertEqual(result["items"][0]["exact"], "text")
        self.assertIn("INV-2024-0042", result["items"][0]["snippet"])

    def test_quoted_phrase_is_required(self):
        self.write("whale.txt", "a blue whale in the sea")
        self.write("sky.txt", "blue blue blue sky")
        self.engine.index()
        self.assertEqual(self.paths(self.engine.search('"blue whale"')), ["whale.txt"])
        missing = self.engine.search('"green whale"')
        self.assertIn("as written", missing["message"])
        self.assertEqual(len(missing["items"]), 2)

    def test_file_name_matches_and_page_numbers(self):
        self.write("tax_return-2024.txt", "red")
        self.write("other.txt", "red red")
        self.engine.index()
        top = self.engine.search("tax return 2024")["items"][0]
        self.assertEqual((Path(top["path"]).name, top["exact"]), ("tax_return-2024.txt", "name"))

    def test_older_index_reads_words_without_embedding_again(self):
        self.write("note.txt", "error E-4012 when paying")
        self.engine.index()
        with self.engine.lock, self.engine.db:
            self.engine.db.execute("DELETE FROM chunk_texts")
            self.engine.db.execute("DELETE FROM file_texts")
        self.assertEqual(self.engine.search("E-4012")["items"][0].get("exact"), None)
        calls = self.engine.encoder.calls
        result = self.engine.index()
        self.assertEqual((result["processed"], result["unchanged"]), (1, 0))
        self.assertEqual(self.engine.encoder.calls, calls)
        self.assertEqual(self.engine.search("E-4012")["items"][0]["exact"], "text")
        self.assertEqual(self.engine.index()["unchanged"], 1)

    def test_deleted_files_leave_the_word_index(self):
        path = self.write("gone.txt", "error E-4012")
        self.engine.index()
        path.unlink()
        self.engine.index()
        self.assertEqual(self.engine.db.execute("SELECT COUNT(*) FROM chunk_texts").fetchone()[0], 0)


@unittest.skipUnless(HAS_NUMPY, "NumPy required for vector search")
class RecognitionTests(Base):
    def helper(self):
        """A stand-in for the Vision helper that 'reads' a fixed sentence."""
        script = self.base / "fake-ocr"
        # Through env: a "#!" line can't name an interpreter whose path has a space (Application Support), and the
        # stand-in only needs the standard library.
        script.write_text("#!/usr/bin/env python3\n" + textwrap.dedent("""
            import json, sys
            for line in sys.stdin:
                request = json.loads(line)
                text = "Payment declined E-4012" if request["kind"] == "image" else f"Scanned page {request['page']} blue lease clause"
                print(json.dumps({"text": text}), flush=True)
        """))
        script.chmod(0o755)
        return ocr.TextRecognizer(str(script))

    @unittest.skipUnless(importlib.util.find_spec("PIL"), "Pillow required for image decoding")
    def test_text_in_pictures_and_scanned_pages_is_found(self):
        from PIL import Image
        Image.new("RGB", (200, 100), (255, 255, 255)).save(self.files / "screenshot.png")
        Image.new("RGB", (200, 100), (255, 255, 255)).save(self.files / "scan.pdf")
        recognizer = self.helper()
        try:
            with patch("docufind.recognizer", recognizer):
                result = self.engine.index()
                self.assertEqual(result["failed"], 0)
                top = self.engine.search("E-4012")["items"][0]
                self.assertEqual((top["title"], top["exact"]), ("screenshot.png", "text"))
                self.assertIn("E-4012", top["recognizedText"])
                page = self.engine.search("blue lease clause")["items"][0]
                self.assertEqual((page["title"], page["page"]), ("scan.pdf", 1))
        finally:
            recognizer.close()

    def test_missing_helper_reads_nothing(self):
        self.assertEqual(ocr.TextRecognizer("").image_text(Path("/nope.png")), "")


@unittest.skipUnless(HAS_NUMPY, "NumPy required for vector search")
class LiveUpdateTests(Base):
    def test_changed_paths_are_indexed_and_removed(self):
        self.write("first.txt", "red")
        self.engine.index()
        added = self.write("folder/new.txt", "blue")
        self.engine.reserve_index()
        result = self.engine.update_paths([str(added.parent)])
        self.assertEqual(result["processed"], 1)
        self.assertEqual(self.engine.status()["indexedCount"], 2)
        # Unchanged files elsewhere are not even looked at.
        self.assertEqual(result["scanned"], 1)
        # A file removed inside a reported folder leaves too.
        sibling = self.write("folder/sibling.txt", "red")
        self.engine.reserve_index()
        self.engine.update_paths([str(added.parent)])
        sibling.unlink()
        self.engine.reserve_index()
        self.assertEqual(self.engine.update_paths([str(added.parent)])["deletedPaths"], [str(sibling)])
        added.unlink()
        added.parent.rmdir()
        self.engine.reserve_index()
        result = self.engine.update_paths([str(added.parent)])
        self.assertEqual(result["deletedPaths"], [str(added)])
        self.assertEqual(self.engine.status()["indexedCount"], 1)

    def test_a_parent_folder_change_never_removes_files(self):
        # A watcher can report a folder above the chosen ones, such as the home folder.
        kept = self.write("photos/kept.txt", "red")
        self.engine.index()
        self.engine.reserve_index()
        result = self.engine.update_paths([str(self.base), str(self.files.parent)])
        self.assertEqual(result["deletedPaths"], [])
        self.assertEqual(self.engine.status()["indexedCount"], 1)
        self.assertTrue(kept.exists())

    def test_files_that_cannot_be_checked_keep_their_entries(self):
        path = self.write("locked/note.txt", "red")
        self.engine.index()
        real_lstat = os.lstat
        def denied(target, *args, **kwargs):
            if str(target).startswith(str(path.parent)):
                raise PermissionError(1, "Operation not permitted", str(target))
            return real_lstat(target, *args, **kwargs)
        with patch("docufind.os.walk", lambda *a, **k: iter(())), patch("docufind.os.lstat", denied):
            self.assertEqual(self.engine.index()["deletedPaths"], [])
        self.assertEqual(self.engine.status()["indexedCount"], 1)

    def test_skipped_folders_and_large_folder_hints(self):
        for number in range(30):
            self.write(f"projects/dataset/{number}.txt", "red")
        self.write("notes/today.md", "blue")
        self.write("settings.json", "red")
        self.engine.index()
        self.assertEqual(self.engine.status()["indexedCount"], 31)  # JSON is skipped.
        from docufind import large_folders
        hints = large_folders([Path(row[0]) for row in self.engine.db.execute("SELECT path FROM files")], self.engine.roots, minimum=10)
        self.assertEqual(hints, [{"path": str(self.files / "projects" / "dataset"), "files": 30}])
        result = self.engine.configure([str(self.files)], skipped=[str(self.files / "projects")])
        self.assertEqual(len(result["deletedPaths"]), 30)
        self.assertEqual(self.engine.index()["unchanged"], 1)
        self.assertEqual(self.engine.status()["skipped"], [str(self.files / "projects")])

    @unittest.skipUnless(importlib.util.find_spec("PIL"), "Pillow required for image decoding")
    def test_photos_from_an_older_size_are_embedded_again_once(self):
        from PIL import Image
        Image.new("RGB", (1600, 900), (200, 30, 30)).save(self.files / "photo.png")
        self.write("note.txt", "red")
        self.engine.index()
        # As if indexed by an earlier version at 1024 pixels.
        with self.engine.lock, self.engine.db:
            self.engine.db.execute("UPDATE image_sizes SET size=1024")
        calls = self.engine.encoder.calls
        result = self.engine.index()
        self.assertEqual((result["processed"], result["unchanged"]), (1, 1))
        self.assertEqual(self.engine.encoder.calls, calls + 1)  # The photo only, not the text.
        self.assertEqual(self.engine.index()["unchanged"], 2)

    def test_source_code_and_data_are_off_until_turned_on(self):
        self.write("script.py", "red = 1")
        self.write("table.csv", "red,blue")
        self.write("note.md", "red")
        self.assertEqual(self.engine.index()["processed"], 1)
        self.assertEqual(self.engine.status()["fileTypes"], {"code": False, "data": False})
        self.engine.configure([str(self.files)], file_types={"code": True})
        self.assertEqual(self.engine.index()["processed"], 1)
        self.assertEqual(self.engine.status()["indexedCount"], 2)
        result = self.engine.configure([str(self.files)], file_types={"code": False})
        self.assertEqual([Path(p).name for p in result["deletedPaths"]], ["script.py"])
        with self.assertRaises(UserError):
            self.engine.configure([str(self.files)], file_types={"code": "yes"})

    def test_a_file_named_like_the_query_beats_a_passage_mentioning_it(self):
        self.write("README.md", "Setup steps for the project and how to run it.")
        self.write("notes.txt", "Remember to update the README before the release, and the README links.")
        self.engine.index()
        top = self.engine.search(text="README")["items"][0]
        self.assertEqual((Path(top["path"]).name, top["exact"]), ("README.md", "name"))

    def test_identical_copies_with_other_names_show_as_one_result(self):
        original = self.write("reports/plan.txt", "red red budget plan")
        self.write("backup/Plan (copy).txt", "red red budget plan")
        self.write("other.txt", "red note")
        self.engine.index()
        # As if both copies had been indexed separately, without a fingerprint.
        with self.engine.lock, self.engine.db:
            self.engine.db.execute("UPDATE file_reuse SET digest=NULL")
        self.engine.index()
        self.assertEqual(self.engine.index_metrics["fingerprintedFiles"], 2)
        items = self.engine.search("red")["items"]
        names = [Path(item["path"]).name for item in items]
        self.assertEqual(sorted(names), ["other.txt", "plan.txt"] if names.count("plan.txt") else ["Plan (copy).txt", "other.txt"])
        merged = next(item for item in items if "copies" in item)
        self.assertEqual(len(merged["copies"]), 1)
        self.assertEqual({merged["path"], merged["copies"][0]}, {str(original), str(self.files / "backup/Plan (copy).txt")})
        # A copy that changes is a different file again.
        (self.files / "backup/Plan (copy).txt").write_text("red red budget plan, revised")
        self.engine.index()
        self.assertEqual(len(self.engine.search("red")["items"]), 3)

    def test_recent_files_are_indexed_first(self):
        for number, name in enumerate(["old.txt", "middle.txt", "new.txt"]):
            path = self.write(name, "red")
            os.utime(path, (1_700_000_000 + number, 1_700_000_000 + number))
        order = []
        self.engine.index(lambda event: order.append(Path(event["item"]["path"]).name) if "item" in event else None)
        self.assertEqual(order, ["new.txt", "middle.txt", "old.txt"])

    def test_hidden_outside_and_private_paths_are_ignored(self):
        hidden = self.write(".hidden/secret.txt", "red")
        outside = self.write("outside.txt", "red", folder=self.base)
        self.engine.reserve_index()
        result = self.engine.update_paths([str(hidden), str(outside), str(self.engine.db_path)])
        self.assertEqual(result["processed"], 0)

    def test_search_works_while_indexing(self):
        self.write("first.txt", "red")
        self.engine.index()
        self.engine.reserve_index()
        try:
            self.assertEqual(self.paths(self.engine.search("red")), ["first.txt"])
        finally:
            self.engine.indexing = False

    def test_paths_must_be_a_list(self):
        self.engine.reserve_index()
        with self.assertRaises(UserError):
            self.engine.update_paths("not a list")
        self.assertFalse(self.engine.indexing)


if __name__ == "__main__":
    unittest.main()
