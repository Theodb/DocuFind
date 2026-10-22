"""Text recognition through the app's Vision helper (docufind-ocr).

The helper reads the text in pictures and in scanned PDF pages, on this Mac.
It runs as one long-lived process, started on first use. Without it (tests, or
a worker started outside the app) recognition is skipped and returns "".
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import threading


class TextRecognizer:
    def __init__(self, helper: str | None = None):
        self.helper = helper if helper is not None else os.environ.get("DOCUFIND_OCR_HELPER", "")
        self._process: subprocess.Popen | None = None
        self._lock = threading.Lock()

    @property
    def available(self) -> bool:
        return bool(self.helper) and os.access(self.helper, os.X_OK)

    def _start(self) -> subprocess.Popen:
        if self._process is None or self._process.poll() is not None:
            self._process = subprocess.Popen([self.helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                             stderr=subprocess.DEVNULL, text=True, bufsize=1)
        return self._process

    def _ask(self, request: dict) -> str:
        if not self.available:
            return ""
        with self._lock:
            for attempt in range(2):
                process = self._start()
                try:
                    process.stdin.write(json.dumps(request) + "\n")
                    process.stdin.flush()
                    line = process.stdout.readline()
                except (BrokenPipeError, OSError):
                    line = ""
                if line:
                    reply = json.loads(line)
                    return reply.get("text") or ""
                # The helper quit (a damaged file can crash Vision); start again once.
                self._close_locked()
            return ""

    def image_text(self, path: Path) -> str:
        return self._ask({"kind": "image", "path": str(path)})

    def pdf_page_text(self, path: Path, page: int) -> str:
        """Text of a 1-based PDF page, read from its rendered image."""
        return self._ask({"kind": "pdf", "path": str(path), "page": page})

    def _close_locked(self) -> None:
        process, self._process = self._process, None
        if process is not None:
            try:
                process.stdin.close()
                process.wait(timeout=2)
                process.stdout.close()
            except Exception:
                process.kill()

    def close(self) -> None:
        with self._lock:
            self._close_locked()


recognizer = TextRecognizer()
