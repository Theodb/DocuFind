from pathlib import Path
import os
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import patch

from file_reuse import FileReuse, digest_file


class FileReuseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.db = sqlite3.connect(":memory:")
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            CREATE TABLE files(path TEXT PRIMARY KEY,kind TEXT,mtime INTEGER,size INTEGER,model_key TEXT);
            CREATE TABLE chunks(id TEXT PRIMARY KEY,path TEXT,position INTEGER,snippet TEXT,location TEXT,dimensions INTEGER,vector BLOB);
        """)
        self.reuse = FileReuse(self.db)

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def source(self, name="first.txt", data=b"the red garden", key="model"):
        path = self.base / name
        path.write_bytes(data)
        stat = path.stat()
        with self.db:
            self.db.execute("INSERT INTO files VALUES (?,?,?,?,?)", (str(path), "text", stat.st_mtime_ns, stat.st_size, key))
            for position in range(3):
                self.db.execute("INSERT INTO chunks VALUES (?,?,?,?,?,?,?)", (f"{name}-{position}", str(path), position, f"snippet{position}", f"offset{position}", 2, b"12345678"))
            self.reuse.remember(path, stat, "text")
        return path

    def test_unique_size_does_not_read_file(self):
        self.source()
        path = self.base / "unique.txt"
        path.write_bytes(b"unique")
        with patch("file_reuse.digest_file", side_effect=AssertionError("Should not hash a unique size")):
            self.assertIsNone(self.reuse.match(path, path.stat(), "text", "model"))

    def test_hashing_and_cancel_callbacks_release_owner_lock_but_sql_is_guarded(self):
        original = self.source()
        path = self.base / "copy.txt"
        path.write_bytes(original.read_bytes())
        # A nonrecursive lock makes an accidental outer lock observable even
        # from this thread; status-like work must be able to acquire it.
        owner = threading.Lock()
        self.reuse = FileReuse(self.db, owner)
        statements, hash_paths, callbacks = [], [], []
        self.db.set_trace_callback(lambda sql: statements.append((sql, owner.locked())))
        def cancel():
            self.assertTrue(owner.acquire(blocking=False), "Cancellation ran while the database owner lock was held")
            try:
                callbacks.append(True)
                self.db.execute("SELECT COUNT(*) FROM files").fetchone()
            finally:
                owner.release()
        def hash_without_owner(path, stat, callback):
            self.assertFalse(owner.locked(), "File I/O must not block status on the database lock")
            hash_paths.append(path)
            return digest_file(path, stat, callback)
        try:
            with patch("file_reuse.digest_file", side_effect=hash_without_owner):
                first = self.reuse.match(path, path.stat(), "text", "model", cancel)
                second = self.reuse.match(path, path.stat(), "text", "model", cancel)
        finally:
            self.db.set_trace_callback(None)
        self.assertEqual(first, second)
        self.assertEqual(first[0], str(original))
        self.assertEqual(hash_paths, [path, original, path])
        self.assertTrue(callbacks)
        self.assertTrue(statements)
        self.assertTrue(all(locked for _, locked in statements), "A reuse SQL operation escaped the owner lock")
        self.assertTrue(any("UPDATE file_reuse" in sql for sql, _ in statements))

    def test_full_signature_rejects_edits_with_preserved_mtime_and_size(self):
        path = self.source(data=b"red garden")
        original = path.stat()
        self.assertTrue(self.reuse.matches_signature(path, original))
        path.write_bytes(b"blue ocean")
        os.utime(path, ns=(original.st_atime_ns, original.st_mtime_ns))
        current = path.stat()
        self.assertEqual((current.st_mtime_ns, current.st_size), (original.st_mtime_ns, original.st_size))
        self.assertFalse(self.reuse.matches_signature(path, current))

    def test_legacy_missing_signature_keeps_existing_fast_path(self):
        path = self.base / "legacy.txt"
        path.write_bytes(b"legacy")
        self.assertTrue(self.reuse.matches_signature(path, path.stat()))

    def test_identical_copy_reuses_live_vectors_and_unique_ids(self):
        original = self.source()
        path = self.base / "copy.txt"
        path.write_bytes(original.read_bytes())
        with self.db:
            match = self.reuse.match(path, path.stat(), "text", "model")
            self.assertIsNotNone(match)
            self.assertEqual(self.reuse.clone(match, path, path.stat(), "text", "model"), ("snippet0", "offset0", 3))
        self.assertEqual(self.db.execute("SELECT COUNT(DISTINCT id) FROM chunks").fetchone()[0], 6)
        self.assertEqual([tuple(row) for row in self.db.execute("SELECT position,snippet,location,dimensions,vector FROM chunks WHERE path=? ORDER BY position", (str(original),))],
                         [tuple(row) for row in self.db.execute("SELECT position,snippet,location,dimensions,vector FROM chunks WHERE path=? ORDER BY position", (str(path),))])

    def test_same_size_different_bytes_do_not_match(self):
        self.source(data=b"red garden")
        path = self.base / "copy.txt"
        path.write_bytes(b"blue ocean")
        self.assertIsNone(self.reuse.match(path, path.stat(), "text", "model"))

    def test_format_and_model_are_part_of_identity(self):
        original = self.source()
        for name, key in (("copy.md", "model"), ("copy.txt", "other")):
            path = self.base / name
            path.write_bytes(original.read_bytes())
            with patch("file_reuse.digest_file", side_effect=AssertionError("Different decoder/profile must not hash")):
                self.assertIsNone(self.reuse.match(path, path.stat(), "text", key))

    def test_source_changed_before_first_hash_is_not_reused(self):
        original = self.source(data=b"red garden")
        original.write_bytes(b"blue ocean")
        path = self.base / "copy.txt"
        path.write_bytes(b"blue ocean")
        self.assertIsNone(self.reuse.match(path, path.stat(), "text", "model"))

    def test_source_digest_describes_committed_vectors_after_source_changes(self):
        original = self.source(data=b"red garden")
        path = self.base / "copy.txt"
        path.write_bytes(b"red garden")
        with self.db:
            self.assertIsNotNone(self.reuse.match(path, path.stat(), "text", "model"))
        original.write_bytes(b"blue ocean")
        self.assertIsNotNone(self.reuse.match(path, path.stat(), "text", "model"))

    def test_removing_source_drops_reuse_metadata(self):
        original = self.source()
        with self.db:
            self.db.execute("DELETE FROM files WHERE path=?", (str(original),))
            self.db.execute("DELETE FROM chunks WHERE path=?", (str(original),))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM file_reuse").fetchone()[0], 0)

    def test_failed_clone_is_atomic_under_caller_transaction(self):
        original = self.source()
        path = self.base / "copy.txt"
        path.write_bytes(original.read_bytes())
        with self.assertRaisesRegex(RuntimeError, "rollback"):
            with self.db:
                match = self.reuse.match(path, path.stat(), "text", "model")
                self.reuse.clone(match, path, path.stat(), "text", "model")
                raise RuntimeError("rollback")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM files").fetchone()[0], 1)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0], 3)

    def test_hash_cancellation_and_changed_input_are_rejected(self):
        path = self.base / "large.txt"
        path.write_bytes(b"abc")
        original = path.stat()
        def changed():
            path.write_bytes(b"different")
        with self.assertRaisesRegex(OSError, "changed"):
            digest_file(path, original, changed)
        class Cancelled(Exception):
            pass
        with self.assertRaises(Cancelled):
            digest_file(path, path.stat(), lambda: (_ for _ in ()).throw(Cancelled()))

    def test_unknown_candidate_work_is_bounded_and_known_digests_are_indexed(self):
        sources = [self.source(f"{number:02}.txt", f"{number:04}".encode()) for number in range(18)]
        path = self.base / "target.txt"
        path.write_bytes(b"0017")
        with patch("file_reuse.digest_file", wraps=digest_file) as read:
            self.assertIsNone(self.reuse.match(path, path.stat(), "text", "model"))
            self.assertEqual(read.call_count, 17)  # Target plus at most 16 unknown sources.
        with self.db:
            self.reuse.remember(sources[-1], sources[-1].stat(), "text", digest_file(sources[-1], sources[-1].stat()))
        with patch("file_reuse.digest_file", wraps=digest_file) as read:
            match = self.reuse.match(path, path.stat(), "text", "model")
            self.assertEqual(match[0], str(sources[-1]))
            self.assertEqual(read.call_count, 1)


if __name__ == "__main__":
    unittest.main()
