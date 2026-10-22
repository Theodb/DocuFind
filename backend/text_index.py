"""Exact-word index: the text of every chunk, plus each file's name, in SQLite FTS5.

Embeddings find meaning; this finds strings as written (invoice numbers, error
codes, names). Rows mirror the chunk positions of the vector index, so a word
match can point to the same page or passage. Position -1 holds the file name.
Call database operations under the owning Engine's lock.
"""
from __future__ import annotations

import re
import sqlite3
from typing import Iterable

TEXT_INDEX_VERSION = 1
NAME_POSITION = -1
_SEPARATORS = re.compile(r"[_\-.\s]+")
_WORD = re.compile(r"\w+")
_DISTINCTIVE = re.compile(r"\d|[_\-./@#:]|[a-z][A-Z]")
_QUOTED = re.compile(r'"([^"]+)"|“([^”]+)”')


def name_text(name: str) -> str:
    """The file name as written and split at separators, so "tax_return-2024.pdf" matches "tax return 2024"."""
    return f"{name} {_SEPARATORS.sub(' ', name)}"


def fts_phrase(text: str) -> str:
    return '"' + text.replace('"', '""') + '"'


class ExactQuery:
    """What to look for as written.

    Quoted phrases are required: files without them are left out. Otherwise the
    whole query counts when it looks like something typed exactly (several words,
    digits, punctuation, mixed case or a capitalized name). A single plain word
    only counts in file names, where it is a strong hint; in passages,
    meaning ranks better.
    """

    def __init__(self, text: str | None):
        text = (text or "").strip()
        self.required = [a or b for a, b in _QUOTED.findall(text) if (a or b).strip()]
        words = _WORD.findall(text)
        self.phrase = None
        self.distinctive = False
        if not self.required and words and len(words) <= 8:
            self.phrase = text
            self.distinctive = len(words) >= 2 or bool(_DISTINCTIVE.search(text)) or text[:1].isupper()

    @property
    def phrases(self) -> list[str]:
        return self.required or ([self.phrase] if self.phrase else [])


class TextIndex:
    def __init__(self, db: sqlite3.Connection, prefix: str = "", files_table: str = "files"):
        self.db = db
        self.texts, self.fts, self.marks = f"{prefix}chunk_texts", f"{prefix}chunk_fts", f"{prefix}file_texts"
        t, f, m = self.texts, self.fts, self.marks
        db.executescript(f"""
            CREATE TABLE IF NOT EXISTS {t}(id INTEGER PRIMARY KEY, path TEXT NOT NULL, position INTEGER NOT NULL, text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS {t}_path ON {t}(path);
            CREATE VIRTUAL TABLE IF NOT EXISTS {f} USING fts5(text, content='{t}', content_rowid='id',
                tokenize="unicode61 remove_diacritics 2 tokenchars '_'");
            CREATE TRIGGER IF NOT EXISTS {t}_insert AFTER INSERT ON {t} BEGIN
                INSERT INTO {f}(rowid, text) VALUES (NEW.id, NEW.text); END;
            CREATE TRIGGER IF NOT EXISTS {t}_delete AFTER DELETE ON {t} BEGIN
                INSERT INTO {f}({f}, rowid, text) VALUES ('delete', OLD.id, OLD.text); END;
            CREATE TABLE IF NOT EXISTS {m}(path TEXT PRIMARY KEY, version INTEGER NOT NULL);
            CREATE TRIGGER IF NOT EXISTS {m}_files_delete AFTER DELETE ON {files_table} BEGIN
                DELETE FROM {t} WHERE path=OLD.path;
                DELETE FROM {m} WHERE path=OLD.path; END;
            CREATE TEMP TABLE IF NOT EXISTS {prefix}staging_texts(position INTEGER NOT NULL, text TEXT NOT NULL);
        """)
        self.staging = f"temp.{prefix}staging_texts"
        db.commit()

    def current(self, path: str) -> bool:
        row = self.db.execute(f"SELECT version FROM {self.marks} WHERE path=?", (path,)).fetchone()
        return row is not None and row[0] >= TEXT_INDEX_VERSION

    def current_paths(self) -> set[str]:
        return {row[0] for row in self.db.execute(f"SELECT path FROM {self.marks} WHERE version>=?", (TEXT_INDEX_VERSION,))}

    def delete(self, paths: Iterable[str]) -> None:
        for path in paths:
            self.db.execute(f"DELETE FROM {self.texts} WHERE path=?", (path,))
            self.db.execute(f"DELETE FROM {self.marks} WHERE path=?", (path,))

    def replace(self, path: str, name: str, rows: Iterable[tuple[int, str]]) -> None:
        """Store a file's chunk texts and name. Call inside the publishing transaction."""
        self.delete([path])
        self.db.execute(f"INSERT INTO {self.texts}(path, position, text) VALUES (?,?,?)", (path, NAME_POSITION, name_text(name)))
        self.db.executemany(f"INSERT INTO {self.texts}(path, position, text) VALUES (?,?,?)",
                            ((path, position, text) for position, text in rows if text and text.strip()))
        self.db.execute(f"INSERT OR REPLACE INTO {self.marks} VALUES (?,?)", (path, TEXT_INDEX_VERSION))

    def stage(self, rows: Iterable[tuple[int, str]]) -> None:
        self.db.executemany(f"INSERT INTO {self.staging} VALUES (?,?)", ((p, t) for p, t in rows if t and t.strip()))

    def clear_staging(self) -> None:
        self.db.execute(f"DELETE FROM {self.staging}")

    def publish_staging(self, path: str, name: str) -> None:
        self.replace(path, name, [])
        self.db.execute(f"INSERT INTO {self.texts}(path, position, text) SELECT ?, position, text FROM {self.staging}", (path,))
        self.clear_staging()

    def copy(self, source: str, path: str, name: str) -> None:
        self.replace(path, name, [])
        self.db.execute(f"INSERT INTO {self.texts}(path, position, text) SELECT ?, position, text FROM {self.texts} WHERE path=? AND position>=0", (path, source))

    def find(self, phrase: str, limit: int = 5000) -> dict[str, dict]:
        """Files containing the phrase as written: the best passage, and whether the name matched."""
        found: dict[str, dict] = {}
        try:
            rows = self.db.execute(f"""
                SELECT t.path, t.position, t.text FROM {self.fts} JOIN {self.texts} t ON t.id={self.fts}.rowid
                WHERE {self.fts} MATCH ? ORDER BY rank LIMIT ?""", (fts_phrase(phrase), limit)).fetchall()
        except sqlite3.OperationalError:
            return found  # A phrase with no searchable words.
        for path, position, text in rows:
            entry = found.setdefault(path, {"name": False, "position": None, "text": None})
            if position == NAME_POSITION:
                entry["name"] = True
            elif entry["position"] is None:
                entry["position"], entry["text"] = position, text
        return found


def excerpt(text: str, phrase: str, width: int = 280) -> str:
    """A snippet centred on the first place the phrase's words appear."""
    flat = " ".join(text.split())
    words = _WORD.findall(phrase)
    pattern = r"\W+".join(re.escape(word) for word in words) if words else re.escape(phrase)
    match = re.search(pattern, flat, re.IGNORECASE)
    if not match:
        return flat[:width]
    start = max(0, match.start() - width // 3)
    if start:
        space = flat.find(" ", start)
        start = space + 1 if 0 <= space < match.start() else start
    snippet = flat[start:start + width]
    return ("…" if start else "") + snippet
