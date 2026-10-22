# Local embedding backend

The native app starts `worker.py` as a private child process. Inference, extracted file contents, and cosine ranking stay on this Mac. Initial dependency installation and the first model download require internet access. Search and indexing never send file contents to an inference service.

## Setup and launch

Use Python 3.11–3.13 for compatible dependency wheels; Python 3.12 is recommended and was verified with the real model. If no suitable Python is installed (or `DOCUFIND_PYTHON` points at an unsupported one), `setup.sh` runs `fetch_python.sh`, which downloads a pinned, SHA-256-verified standalone Python 3.12 from [python-build-standalone](https://github.com/astral-sh/python-build-standalone) into a `python/` folder beside the virtual environment. The worker itself accepts Python 3.11 or newer. `setup.sh` installs Python packages into a virtual environment. When `DOCUFIND_MODEL_CACHE` is set, as the app does, it also downloads the pinned model into that cache with `model_download.py`, alongside the packages, and prints `::docufind` progress lines; otherwise the model downloads, with progress, when it is first used. It checks for free disk space first. On Apple Silicon with Python 3.12/3.13, setup selects `requirements-macos-arm64.lock.txt`, the exact dependency versions verified with the real model. Python 3.11 and other platforms use the compatible ranges in `requirements.txt`; those combinations were not verified with the real model. Setup reuses a supported existing virtual environment without requiring a separately discoverable base interpreter.

The native app keeps its data in `~/Library/Application Support/DocuFind`. For development, an `DocuFindLocal` folder placed beside `DocuFind.app` is used instead, so a build can share an existing runtime and model. `DOCUFIND_DATA_DIR` overrides both.

```bash
./backend/setup.sh
"$HOME/Library/Application Support/DocuFind/venv/bin/python" backend/worker.py
```

For a custom installation or testing location:

```bash
DOCUFIND_PYTHON=/path/to/python3.12 \
DOCUFIND_VENV_DIR=/path/to/venv \
./backend/setup.sh
/path/to/venv/bin/python backend/worker.py --data-dir /path/to/private-data
```

`DOCUFIND_DATA_DIR` is equivalent to `--data-dir`; the argument takes priority. The default data location is `~/Library/Application Support/DocuFind`. Its `index.sqlite3` contains file paths, text snippets and normalized embeddings. The model is stored beneath `models/coreml`. Treat the index like the source files: snippets can contain personal information. The SQLite file is created with permissions `0600`. Deleting this data directory clears the backend index and downloaded model.

### The model

The model is [BidirLM-Omni-2.5B-Embedding](https://huggingface.co/BidirLM/BidirLM-Omni-2.5B-Embedding), a shared 2048-dimensional representation for text, images and audio, run on the Neural Engine through Core ML. DocuFind downloads its Core ML version, [`BidirLM/BidirLM-Omni-2.5B-Embedding-CoreML`](https://huggingface.co/BidirLM/BidirLM-Omni-2.5B-Embedding-CoreML), pinned by `model_download.REVISION`: about 3.3 GB, checked file by file against the SHA-256 values in its `files.json`. PyTorch, Transformers and Sentence Transformers are not needed. It requires Apple silicon and macOS 15 or later.

`omni_coreml.py` does everything around the four Core ML models (text layers 1–14 and 15–28, the photo part, the audio part) with NumPy: tokens, photo patches, the audio spectrum, positions, and the packed sequence layout. Texts of up to 512 tokens share 512-token runs, up to eight at a time; a text of up to 640 tokens gets its own run; longer texts are embedded in parts and averaged. Photos are resized once to fit 768 pixels, with sides in multiples of 32. Recordings are read in 30-second windows. Core ML compiles the models for this Mac on first use, into `models/coreml/compiled`.

On its first load on a Mac, the model embeds the published check samples and compares them with the PyTorch model's vectors for them; it is used only at 0.995 agreement or better. `tools/coreml` builds the published model from the PyTorch one and validates it end to end.

| Variable | Values / default |
| --- | --- |
| `DOCUFIND_PREFETCH` | `0` disables long-file extraction prefetch; enabled otherwise |

## Indexed content

- UTF-8 plain text, Markdown, common source files, CSV/TSV, JSON, YAML, XML/HTML and logs: overlapping chunks of at most 1800 characters, with 250-character overlap. Raw markup is included; HTML is not rendered.
- PDF: extracted text per page, then the same text chunking. Password-protected and image-only PDFs are skipped with an explanation. OCR is not included.
- Images: JPEG, PNG, WebP, GIF (first frame), BMP, TIFF, HEIC/HEIF. Pillow decodes images and corrects EXIF orientation. HEIC/HEIF can fall back to the built-in macOS image converter. Images are reduced to a maximum side of 1024 pixels before embedding.
- Audio: WAV, MP3, FLAC, OGG, AIFF, M4A/AAC, CAF and OPUS, subject to available decoders. libsndfile streams the recording in 30-second windows with 5-second overlap. macOS AudioToolbox can convert formats unavailable in libsndfile into a temporary WAV. Temporary decoded files are deleted afterwards. The model processor resamples to 16 kHz.

Folder selection persists. The app must explicitly configure roots and start indexing; opening the app or calling `status` never loads/downloads the model. Indexing checks modification time, size and model/chunking version, so unchanged files reuse their vectors. Each file is replaced atomically only after all its chunks embed successfully. Cancellation and model failures preserve the previous good file entry. Deleted files are removed after a completed scan; unavailable volumes and unreadable folders retain their last good entries.

### Bounded indexing pipeline

Small text documents share homogeneous cross-file batches, including documents with multiple chunks. With text batch `B` (32), the scheduler treats up to `min(4 × B, 32)` chunks as a small document and queues at most `min(8 × B, 64)` text chunks across at most 64 files, so the model can pack them into shared runs. Images and single-window audio use smaller modality-specific queues. Larger files stream through their own batches.

Long-file extraction prepares at most one batch ahead on a single producer thread while inference consumes the current batch. There can also be one chunk inside a decoder call and a bounded initial classification lookahead. The producer owns and closes the extractor; cancellation stops queueing, and a platform decoder already inside an OS call finishes privately before cleanup. Set `DOCUFIND_PREFETCH=0` to compare sequential extraction when diagnosing a workload.

Validated vectors are published in one transaction per file. Long files stage their vectors in a SQLite TEMP table that can spill to private temporary disk. The final file signature checks device, inode, modification time, change time, and size, including changes while queued. Partial results never replace the file's prior good vectors. Unsupported extensions are filtered before per-file symlink checks, avoiding metadata reads for files that cannot be indexed.

### Exact file-copy reuse

Before extraction or model loading, changed files can reuse chunks from a byte-identical live index entry with the same extension-selected decoder, byte size, and exact numerical model key. A cheap candidate lookup avoids hashing unique sizes/formats. SHA-256 reads use 1 MiB blocks with cancellation and file-signature checks. Known fingerprints use an indexed lookup; classification reads at most 16 previously unhashed sources per target. A missed or unreadable candidate falls back to normal extraction and inference.

Cloning publishes the target file and its own chunk IDs atomically. Fingerprints describe committed vectors, so a known fingerprint remains useful even if its original file has subsequently changed but has not yet been reindexed. The `file_reuse` table references live indexed files, stores no source content or separate vector cache, and removes metadata when its file row is deleted. Existing indexes gain this metadata as files are successfully published; old entries are not guessed to be exact copies. Reuse never modifies source files.

There is no file-count cap. Symlinks, hidden files/folders, system directories, the current user's `Library`, application/framework bundles, Photos libraries, credential directories, package caches, virtual environments and the app's own data directory are excluded. Whole-home indexing therefore covers ordinary personal folders, not every byte on the disk. Add external volumes as separate roots. Grant Full Disk Access to DocuFind for protected personal folders; macOS may apply additional restrictions to the Python child process.

Search scans the normalized stored vectors in bounded batches and computes exact cosine similarity. Results contain the best matching chunk per file. Scores are cosine values in `[-1, 1]`, not probabilities. A long audio/document query averages its normalized chunk vectors; a query containing both text and a file averages their normalized representations. Index growth can make exact retrieval slower; an approximate nearest-neighbor index is a possible future optimization.

## JSON-lines protocol

Write one JSON object per line to stdin. Every emitted line contains the request `id` and an `event` of `progress`, `result`, or `error`. Diagnostic logs go to stderr. Heavy operations run serially; `status`, `cancel`, and `shutdown` are handled while indexing runs. Wait for configure's result before requesting index. A search during active indexing returns a busy error.

| Action | Additional request fields | Result |
| --- | --- | --- |
| `status` | none | `ready`, `indexing`, `indexedCount`, `chunkCount`, `roots`, `device`, `model`, `modelRevision`, `modelReady`, `modelDownloaded`, `missingDependencies`, `staleIndexCount`, `compatibleModelKeys`, `indexMetrics`, `error` |
| `configure` | `roots: [absolutePaths]`, `skipped?`, `fileTypes?`, `indexingOptions?` | status plus `deletedPaths` for entries removed by the new selection |
| `download_model` | none | status, after the model is downloaded and verified; `download` progress events report bytes |
| `index` | none | status plus `processed`, `unchanged`, `failed`, `scanned`, `cancelled`, optional `deletedPaths` |
| `cancel` | none | `cancelling`; stops cooperatively between extraction/inference operations |
| `search` | `text?`, `path?`, `kind?: all/text/image/audio`, `limit?: 1…100` | `items`, optional empty-index `message` |
| `items` | `offset?: 0`, `limit?: 1…2000` | representative `items` per file, `total`, `offset`, `nextOffset` or null |
| `remove_root` | `path` | status plus `deletedPaths` |
| `shutdown` | none | `shuttingDown`; cancels indexing and exits after the current operation |

`ready` means required modules are installed; `modelReady` means a model instance is actually loaded. Dependency/version errors may still occur when loading and are reported with setup guidance.

### Index progress and diagnostics

Index progress retains `scanned`, `processed`, `unchanged`, and `failed`. `processed` counts files committed in this run, not the lifetime index total. A long file emits `fileChunksCompleted` after each embedded/staged batch, before its final committed `item`. Before work starts, a `plan` progress event reports `totalFiles` and `filesToProcess`, so the native UI can show “X of Y files” and an estimated time left. It coalesces ordinary updates at four per second.

Progress, the final result, and `status` expose an `indexMetrics` snapshot:

| Fields | Meaning |
| --- | --- |
| `elapsedSeconds`, `phase` | Latest run elapsed time and current/last processing phase |
| `scanSeconds`, `extractionSeconds`, `inferenceSeconds`, `writeSeconds`, `loadSeconds`, `reuseSeconds` | Measured stage durations, including duplicate checks separately from inference |
| `decodedChunks`, `embeddedChunks` | Chunks extracted or submitted successfully to the model; later publication can still fail or be cancelled |
| `writtenChunks`, `completedFiles` | Chunks and files committed this run, including exact-copy reuse |
| `unchangedFiles`, `failedFiles` | Files skipped as unchanged or reported as failed |
| `reusedFiles`, `reusedChunks` | Committed copies that reused vectors without model inference |
| `prefetchEnabled`, `stageTimesCanOverlap` | Whether prefetch was used and whether stage durations can overlap |

Metric fields contain no file paths, snippets, or query content. Existing `item`, `path`, and warning fields still carry file information needed by the UI. Extraction and inference may overlap, so stage durations are not an additive breakdown of wall time. Counts and rates are workload observations, not a promised full-library throughput. See [INDEXING-PERFORMANCE.md](../docs/benchmarks/INDEXING-PERFORMANCE.md) for end-to-end indexing measurements, separately from the earlier [model calibration](../docs/benchmarks/PERFORMANCE.md).

Every item contains `id`, `path`, `title`, `kind`, `snippet`, `score`, and optional `location`. `id` is a stable SHA-256 of the canonical file path. `location` identifies a text character, PDF page, image, or audio time range. During indexing, a successfully committed file emits a progress event containing `item`; replaced/deleted files emit `deletedPaths`. `items` pages through the whole index. Errors contain an actionable `message` and, when available, `action`.

```json
{"id":"configure-1","action":"configure","roots":["/Users/me/Documents"]}
{"id":"index-1","action":"index"}
{"id":"query-1","action":"search","text":"A dog barking outside","kind":"all","limit":20}
{"id":"query-2","action":"search","path":"/Users/me/Desktop/reference.png","kind":"all","limit":20}
```

Each request above must be sent after the previous request finishes, except `status`/`cancel` during indexing. The backend's exact semantic ranking is consumed by the app.

## Verification

```bash
python3 -m unittest discover -s backend/tests -v
```

The unit suite injects a deterministic test-only encoder to verify persistence, updates/deletions, cancellation, search, modality filters, exclusions, chunking and protocol behavior without downloading weights. NumPy is needed for the vector search test; that test is skipped if NumPy is absent. Production always uses the real model.

To check the real model end to end against the PyTorch one (developers only; needs the PyTorch model and its dependencies):

```bash
python tools/coreml/validate.py --cache <PyTorch model cache> --model "$HOME/Library/Application Support/DocuFind/models/coreml" --photos <folder of photos>
```

It requires 0.995 agreement or better for every text, photo and recording, and the same best match for every search. The unit suite also covers multi-document batching, atomic rollback, bounded extraction prefetch, duplicate reuse and cleanup, metadata-read filtering, progress metrics, and the model download and check.
