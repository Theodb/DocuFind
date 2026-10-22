#!/usr/bin/env python3
"""JSON-lines bridge used by the native Mac app. Requires Python 3.11+."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys
import threading
import traceback

from docufind import Engine, UserError


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, help="Local private index and model cache (or DOCUFIND_DATA_DIR)")
    args = parser.parse_args()
    if sys.version_info < (3, 11):
        parser.error("Python 3.11 or newer is required.")
    # Third-party libraries/custom model code may print to stdout. Keep the
    # original stream exclusively for protocol messages, redirect all incidental
    # Python stdout to stderr before any model imports can happen.
    protocol = sys.stdout
    sys.stdout = sys.stderr
    write_lock = threading.Lock()

    def emit(request_id, event, payload):
        with write_lock:
            protocol.write(json.dumps({"id": request_id, "event": event, **payload}, ensure_ascii=False, allow_nan=False) + "\n")
            protocol.flush()

    engine = Engine(args.data_dir)
    print("Local worker ready.", file=sys.stderr, flush=True)
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="docufind")
    # While files are indexed, searches use their own thread so they keep working.
    # Otherwise everything shares one queue: two threads importing the model's
    # libraries at the same moment can deadlock.
    searcher = ThreadPoolExecutor(max_workers=1, thread_name_prefix="docufind-search")

    def execute(request: dict):
        identifier, action = request.get("id"), request.get("action")
        progress = lambda event: emit(identifier, "progress", event)
        try:
            if action == "configure":
                print("Resolving local processing settings…", file=sys.stderr, flush=True)
                result = engine.configure(request.get("roots", []), request.get("device", "auto"), request.get("skipped"), request.get("neuralEngine"), request.get("fileTypes"), request.get("indexingOptions"))
                print("Local processing settings ready.", file=sys.stderr, flush=True)
            elif action == "index":
                result = engine.index(progress=progress, reserved=True)
                result["indexing"] = False
            elif action == "download_model":
                result = engine.download_model(progress)
            elif action == "index_paths":
                result = engine.update_paths(request.get("paths", []), progress)
                result["indexing"] = False
            elif action == "refine":
                result = engine.refine(request.get("text"), request.get("items", []), progress)
            elif action == "search":
                result = engine.search(request.get("text"), request.get("path"), request.get("kind", "all"), request.get("limit", 20), progress)
            elif action == "audio_preview":
                result = engine.audio_preview(request["path"], request.get("start", 0), request.get("end", 30), request.get("bins", 160), bool(request.get("clip", False)))
            elif action == "items":
                result = engine.items(request.get("offset", 0), request.get("limit", 500))
            elif action == "remove_root":
                result = engine.remove_root(request["path"])
            else:
                raise UserError(f"Unknown action: {action}")
            emit(identifier, "result", result)
        except Exception as exc:
            if not isinstance(exc, UserError):
                traceback.print_exc(file=sys.stderr)
            emit(identifier, "error", {"message": str(exc), "action": action})

    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            identifier = None
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise UserError("Each request must be a JSON object.")
                identifier, action = request.get("id"), request.get("action")
                if action == "status":
                    emit(identifier, "result", engine.status())
                elif action == "cancel":
                    engine.cancel_event.set()
                    emit(identifier, "result", {"cancelling": engine.indexing, "message": "Stopping after the current model operation."})
                elif action == "shutdown":
                    engine.cancel_event.set()
                    emit(identifier, "result", {"shuttingDown": True})
                    break
                else:
                    if action in {"index", "index_paths"}:
                        engine.reserve_index()
                    elif engine.indexing and action in {"configure", "remove_root"}:
                        raise UserError("Indexing is running. Stop it first or wait for completion.")
                    concurrent = action in {"search", "refine", "items", "audio_preview"} and engine.indexing
                    pool = searcher if concurrent else executor
                    pool.submit(execute, request)
            except Exception as exc:
                emit(identifier, "error", {"message": str(exc)})
    finally:
        engine.cancel_event.set()
        executor.shutdown(wait=True, cancel_futures=False)
        searcher.shutdown(wait=True, cancel_futures=False)
        engine.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
