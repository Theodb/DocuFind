"""Machine-made files, long-file limit and reading order."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import indexing_rules
from docufind import Engine, UserError, normalized


class CountingEncoder:
    def __init__(self, device, cache, progress):
        self.device, self.loaded, self.calls = "ane", True, 0

    def encode(self, inputs):
        self.calls += len(inputs)
        return [normalized([str(text).lower().count("red"), 0.01]) for text in inputs]


class RulesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.files = Path(self.tmp.name).resolve() / "documents"
        self.files.mkdir()
        self.engine = Engine(Path(self.tmp.name) / "private", encoder_factory=CountingEncoder)
        self.engine.configure([str(self.files)])

    def tearDown(self):
        self.engine.close()
        self.tmp.cleanup()

    def write(self, name, text="red"):
        path = self.files / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def indexed(self):
        return sorted(str(Path(row[0]).relative_to(self.files)) for row in self.engine.db.execute("SELECT path FROM files"))

    def test_models_fixtures_and_tokenizer_files_are_skipped(self):
        self.write("notes/plan.md")
        self.write("models/qwen/config.json", "{}")
        self.write("models/qwen/README.md")
        self.write("models/qwen/model.safetensors", "x")
        self.write("models/qwen/sub/notes.txt")
        self.write("lib/tests/fixtures/sample.txt")
        self.write("tokenizer/merges.txt", "Ġ t\nĠ a")
        self.write("tokenizer/readme.txt")
        self.engine.index()
        self.assertEqual(self.indexed(), ["notes/plan.md", "tokenizer/readme.txt"])
        skipped = self.engine.status()["autoSkipped"]
        self.assertEqual(skipped, {"model folders": 1, "test fixtures": 1, "tokenizer files": 1})

    def test_turning_the_option_off_and_on(self):
        self.write("tokenizer/merges.txt", "Ġ t")
        self.engine.configure([str(self.files)], options={"skipMachineFiles": False})
        self.engine.index()
        self.assertEqual(self.indexed(), ["tokenizer/merges.txt"])
        result = self.engine.configure([str(self.files)], options={"skipMachineFiles": True})
        self.assertEqual([Path(p).name for p in result["deletedPaths"]], ["merges.txt"])
        with self.assertRaises(UserError):
            self.engine.configure([str(self.files)], options={"skipMachineFiles": "no"})
        with self.assertRaises(UserError):
            self.engine.configure([str(self.files)], options={"unknown": True})

    def test_long_text_files_stop_at_the_limit_and_stay_unchanged(self):
        self.write("journal.txt", "red line of a long journal\\n" * 40000)
        self.engine.index()
        chunks = self.engine.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        self.assertEqual(chunks, indexing_rules.LONG_FILE_PASSAGES)
        self.assertEqual(self.engine.index_metrics["shortenedFiles"], 1)
        self.assertEqual(self.engine.index()["unchanged"], 1)
        self.engine.configure([str(self.files)], options={"limitLongFiles": False})
        self.engine.db.execute("DELETE FROM files")
        self.engine.index()
        self.assertGreater(self.engine.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0], indexing_rules.LONG_FILE_PASSAGES)

    def test_personal_places_before_generated_ones_newest_first(self):
        root = Path.home()
        key = lambda rel, mtime: indexing_rules.priority(root / rel, root, mtime)
        ordered = sorted([("Documents/run/outputs/a.txt", 9), ("Documents/notes.txt", 1), ("Desktop/new.txt", 5), ("misc/b.txt", 7)],
                         key=lambda e: key(*e))
        self.assertEqual([e[0] for e in ordered], ["Desktop/new.txt", "Documents/notes.txt", "misc/b.txt", "Documents/run/outputs/a.txt"])

    def test_options_merge_with_defaults(self):
        self.assertEqual(indexing_rules.options({"limitLongFiles": False, "other": True}),
                         {"skipMachineFiles": True, "limitLongFiles": False, "importantFirst": True})
        reopened = None
        self.engine.configure([str(self.files)], options={"importantFirst": False})
        try:
            reopened = Engine(Path(self.tmp.name) / "private", encoder_factory=CountingEncoder)
            self.assertFalse(reopened.options["importantFirst"])
        finally:
            if reopened:
                reopened.close()


if __name__ == "__main__":
    unittest.main()


class TextReadingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.folder = Path(self.tmp.name).resolve()

    def tearDown(self):
        self.tmp.cleanup()

    def test_html_keeps_only_what_a_browser_shows(self):
        from docufind import html_text
        page = self.folder / "page.html"
        page.write_text("""<html><head><title>Camping notes</title><style>body { color: red }</style>
            <script>var fire = 1;</script></head><body>
            {{- if eq $icon "fire" -}}<svg viewBox="0 0 24 24"><path d="M12 2c1.5 3.2-.8 4.6-2.1 6.9 18.227 18.227 0 0 1-9.256 1.98"/></svg>{{- end -}}
            <h1>Lighting a camp fire</h1><p>Gather dry wood &amp; kindling first.</p></body></html>""")
        text = html_text(page)
        self.assertIn("Camping notes", text)
        self.assertIn("Lighting a camp fire", text)
        self.assertIn("Gather dry wood & kindling first.", text)
        for hidden in ("viewBox", "18.227", "var fire", "color: red", "{{", "$icon"):
            self.assertNotIn(hidden, text)

    def test_cloud_only_files_are_recognised(self):
        from types import SimpleNamespace
        from docufind import is_cloud_only
        self.assertTrue(is_cloud_only(SimpleNamespace(st_flags=0x40000000)))
        self.assertFalse(is_cloud_only(SimpleNamespace(st_flags=0)))
        self.assertFalse(is_cloud_only(SimpleNamespace()))

    def test_language_check(self):
        from docufind import looks_like_language
        self.assertTrue(looks_like_language("Gather dry wood and kindling first, then light the fire from below."))
        self.assertTrue(looks_like_language("Un feu de camp se prépare avec du bois sec et des brindilles."))
        self.assertTrue(looks_like_language("def light(fire):\n    return fire.start(wood=dry, kindling=True)"))
        self.assertFalse(looks_like_language(".281a18.227 18.227 0 0 1-9.256 1.98 18.227 18.227 0 0 1-1.595-.168l4.185 26.8 11.42 1.832zm-4.234"))
        self.assertFalse(looks_like_language("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg== " * 3))
        self.assertFalse(looks_like_language("12, 45.2, 33.1, 9.0, 18.7, 22.4, 31.0, 8.8, 14.2, 17.9, 21.3, 11.1"))
        # Dataset records (JSON lines) are data, even though they hold words.
        self.assertFalse(looks_like_language('{"id": 1, "text": "bonjour tout le monde", "label": "O"} ' * 5))
        # Short passages need a few letters: a template reduced to a separator says nothing.
        self.assertTrue(looks_like_language("Fire drill"))
        self.assertFalse(looks_like_language("|"))
        self.assertFalse(looks_like_language("— · 12"))

    def test_data_passages_are_skipped_and_older_texts_read_again(self):
        engine = Engine(self.folder / "private", encoder_factory=CountingEncoder)
        try:
            files = self.folder / "documents"
            files.mkdir()
            engine.configure([str(files)])
            (files / "icons.html").write_text("<p>red icon set</p><svg><path d='" + "18.227 0 0 1-9.256 1.98 " * 400 + "'/></svg>")
            (files / "mixed.txt").write_text("A red note about building camp fires safely. " * 60 + "\n\n" + "0.5 1.25 3.75 -2.5 " * 400)
            engine.index()
            texts = [row[0] for row in engine.db.execute("SELECT text FROM chunk_texts WHERE position >= 0")]
            self.assertTrue(texts)
            self.assertFalse(any("18.227" in t for t in texts))
            # At most the passage where the prose ends and the numbers begin, which is still mostly words.
            self.assertLessEqual(sum("3.75 -2.5 0.5" in t for t in texts), 1)
            self.assertGreater(engine.index_metrics.get("skippedPassages", 0), 0)
            self.assertEqual(engine.index()["unchanged"], 2)
            # Texts read before this version are read again once.
            with engine.lock, engine.db:
                engine.db.execute("DELETE FROM text_versions")
            self.assertEqual(engine.index()["processed"], 2)
            self.assertEqual(engine.index()["unchanged"], 2)
        finally:
            engine.close()


class RefineTests(unittest.TestCase):
    def test_the_closest_part_of_a_passage_becomes_the_snippet(self):
        from docufind import passage_windows, shifted_location
        tmp = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        try:
            folder = Path(tmp.name).resolve() / "documents"
            folder.mkdir()
            engine = Engine(Path(tmp.name) / "private", encoder_factory=CountingEncoder)
            engine.configure([str(folder)])
            call = ("Agent: hello, you are now registered with us, thank you for calling. " * 6
                    + "Client: there is red smoke coming out of the boiler room and I called the firefighters. "
                    + "Agent: noted, a technician will come tomorrow morning to check the meters. " * 6)
            (folder / "call.txt").write_text(call)
            engine.index()
            item = engine.search("red")["items"][0]
            self.assertTrue(item["snippet"].startswith("Agent: hello"))
            refined = engine.refine("red", [item])["items"][0]
            self.assertIn("red smoke", refined["snippet"])
            self.assertNotEqual(refined["location"], item["location"])
            windows = passage_windows(call)
            self.assertGreater(len(windows), 2)
            self.assertTrue(all(call[offset:offset + 20].strip()[:10] in window for offset, window in windows))
            self.assertEqual(shifted_location("Page 3, character 120", 50), "Page 3, character 170")
            engine.close()
        finally:
            tmp.cleanup()
