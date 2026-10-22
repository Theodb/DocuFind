"""Reuse live indexed chunks for byte-identical local file copies.

Fingerprints are computed lazily only when another indexed file has the same
size and decoder. No duplicate vectors or deleted-file content are retained.
Call database operations under the owning Engine's lock.
"""
from __future__ import annotations

from hashlib import sha256
from contextlib import nullcontext
from pathlib import Path
import sqlite3


def signature(stat) -> tuple:
    return (stat.st_dev, stat.st_ino, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size)


def decoder_for(path: Path, kind: str) -> str:
    # The extension selects PDF handling and some platform media fallbacks.
    return f"{kind}:{path.suffix.lower()}"


def digest_file(path: Path, original, cancel=lambda: None) -> str:
    digest = sha256()
    with path.open("rb") as stream:
        while True:
            cancel()
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    cancel()
    if signature(path.stat()) != signature(original):
        raise OSError("File changed while checking duplicate content.")
    return digest.hexdigest()


class FileReuse:
    def __init__(self, db: sqlite3.Connection, lock=None):
        self.db = db
        self.lock = lock if lock is not None else nullcontext()
        # Fingerprints taken by match() for files that had no copy yet, keyed by path, with their signature.
        self._computed: dict[str, tuple[tuple, str]] = {}
        db.executescript("""
            CREATE TABLE IF NOT EXISTS file_reuse(
                path TEXT PRIMARY KEY, decoder TEXT NOT NULL,
                device INTEGER NOT NULL, inode INTEGER NOT NULL,
                mtime INTEGER NOT NULL, ctime INTEGER NOT NULL,
                size INTEGER NOT NULL, digest TEXT);
            CREATE INDEX IF NOT EXISTS file_reuse_candidates
                ON file_reuse(decoder,size);
            CREATE INDEX IF NOT EXISTS file_reuse_digests
                ON file_reuse(decoder,size,digest);
            CREATE TRIGGER IF NOT EXISTS file_reuse_delete
                AFTER DELETE ON files BEGIN
                DELETE FROM file_reuse WHERE path=OLD.path;
                END;
            DELETE FROM file_reuse WHERE path NOT IN (SELECT path FROM files);
        """)
        db.create_function("docufind_chunk_id", 2,
                           lambda path, position: sha256(f"{path}\0{position}".encode()).hexdigest(),
                           deterministic=True)
        db.commit()

    def remember(self, path: Path, stat, kind: str, digest: str | None = None) -> None:
        # A fingerprint computed while looking for a copy (and finding none) is kept, so a later copy can match it.
        computed = self._computed.pop(str(path), None)
        if digest is None and computed is not None and computed[0] == signature(stat):
            digest = computed[1]
        self.db.execute("INSERT OR REPLACE INTO file_reuse VALUES (?,?,?,?,?,?,?,?)",
                        (str(path), decoder_for(path, kind), *signature(stat), digest))

    def matches_signature(self, path: Path, stat) -> bool:
        """Reject changed file generations when full metadata is available.

        Older indexes have no reuse row. They retain their existing mtime/size
        fast path until a successful publication records the full signature.
        """
        row = self.db.execute("SELECT device,inode,mtime,ctime,size FROM file_reuse WHERE path=?",
                              (str(path),)).fetchone()
        return row is None or tuple(row) == signature(stat)

    def match(self, path: Path, stat, kind: str, model_key: str,
              cancel=lambda: None) -> tuple[str, str] | None:
        arguments = (decoder_for(path, kind), stat.st_size, model_key, str(path))
        with self.lock:
            candidate = self.db.execute("""
                SELECT 1 FROM file_reuse r JOIN files f USING(path)
                WHERE r.decoder=? AND r.size=? AND f.model_key=? AND r.path<>?
                  AND EXISTS (SELECT 1 FROM chunks c WHERE c.path=r.path)
                LIMIT 1
            """, arguments).fetchone()
        if candidate is None:
            return None
        wanted = digest_file(path, stat, cancel)
        self._computed[str(path)] = (signature(stat), wanted)
        with self.lock:
            known = self.db.execute("""
                SELECT r.path FROM file_reuse r JOIN files f USING(path)
                WHERE r.decoder=? AND r.size=? AND f.model_key=? AND r.path<>?
                  AND r.digest=? AND EXISTS (SELECT 1 FROM chunks c WHERE c.path=r.path)
                LIMIT 1
            """, (*arguments, wanted)).fetchone()
        if known is not None:
            return known[0], wanted
        # Classification is best-effort and bounded per new file. A miss simply
        # uses normal inference. Known fingerprints always use the index above.
        with self.lock:
            candidates = self.db.execute("""
                SELECT r.* FROM file_reuse r JOIN files f USING(path)
                WHERE r.decoder=? AND r.size=? AND f.model_key=? AND r.path<>?
                  AND r.digest IS NULL AND EXISTS (SELECT 1 FROM chunks c WHERE c.path=r.path)
                ORDER BY r.path LIMIT 16
            """, arguments).fetchall()
        for row in candidates:
            cancel()
            digest = row["digest"]
            if digest is None:
                source = Path(row["path"])
                try:
                    source_stat = source.stat()
                    recorded = tuple(row[key] for key in ("device", "inode", "mtime", "ctime", "size"))
                    if signature(source_stat) != recorded:
                        continue
                    digest = digest_file(source, source_stat, cancel)
                except OSError:
                    continue
                with self.lock:
                    self.db.execute("""UPDATE file_reuse SET digest=? WHERE path=?
                        AND device=? AND inode=? AND mtime=? AND ctime=? AND size=?""",
                        (digest, row["path"], *recorded))
            if digest == wanted:
                return row["path"], wanted
        return None

    def clone(self, match: tuple[str, str], path: Path, stat, kind: str,
              model_key: str) -> tuple[str, str, int]:
        source, digest = match
        if source == str(path):
            raise ValueError("A duplicate source must be a different file.")
        # Validate the live index source inside the same atomic publication.
        source_row = self.db.execute("SELECT model_key FROM files WHERE path=?", (source,)).fetchone()
        first = self.db.execute("SELECT snippet,location FROM chunks WHERE path=? ORDER BY position LIMIT 1", (source,)).fetchone()
        count = self.db.execute("SELECT COUNT(*) FROM chunks WHERE path=?", (source,)).fetchone()[0]
        if source_row is None or source_row[0] != model_key or first is None or count == 0:
            raise ValueError("Duplicate source is no longer available in the active index.")
        name = str(path)
        self.db.execute("DELETE FROM chunks WHERE path=?", (name,))
        self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?)",
                        (name, kind, stat.st_mtime_ns, stat.st_size, model_key))
        self.db.execute("""
            INSERT INTO chunks(id,path,position,snippet,location,dimensions,vector)
            SELECT docufind_chunk_id(?,position),?,position,snippet,location,dimensions,vector
            FROM chunks WHERE path=?
        """, (name, name, source))
        self.remember(path, stat, kind, digest)
        return first[0], first[1], count

    def copies(self, paths: list[str]) -> dict[str, list[str]]:
        """For each path with known identical copies in the index, the other copies' paths, newest first."""
        found: dict[str, list[str]] = {}
        for path in paths:
            row = self.db.execute("SELECT decoder, size, digest FROM file_reuse WHERE path=? AND digest IS NOT NULL", (path,)).fetchone()
            if row is None:
                continue
            others = [r[0] for r in self.db.execute("""
                SELECT r.path FROM file_reuse r JOIN files f USING(path)
                WHERE r.decoder=? AND r.size=? AND r.digest=? AND r.path<>? ORDER BY r.mtime DESC, r.path""", (*row, path))]
            if others:
                found[path] = others
        return found

    def fingerprint_twins(self, lock, cancel=lambda: None) -> int:
        """Fingerprint indexed files that share a decoder and size with another one but have no digest yet."""
        with lock:
            rows = self.db.execute("""
                SELECT r.path, r.device, r.inode, r.mtime, r.ctime, r.size FROM file_reuse r JOIN files f USING(path)
                WHERE r.digest IS NULL AND EXISTS (SELECT 1 FROM file_reuse o WHERE o.decoder=r.decoder AND o.size=r.size AND o.path<>r.path)
            """).fetchall()
        done = 0
        for path, *recorded in rows:
            cancel()
            source = Path(path)
            try:
                stat = source.stat()
                if signature(stat) != tuple(recorded):
                    continue  # Changed since it was indexed; the next update reads it again.
                digest = digest_file(source, stat, cancel)
            except OSError:
                continue
            with lock:
                with self.db:
                    self.db.execute("""UPDATE file_reuse SET digest=? WHERE path=? AND device=? AND inode=? AND mtime=? AND ctime=? AND size=?""",
                                    (digest, path, *recorded))
            done += 1
        return done
