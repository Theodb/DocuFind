#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${DOCUFIND_BUILD_DIR:-$(cd "$PROJECT_ROOT/../.." && pwd)/work/docufind-build}"
ICONSET="$BUILD_ROOT/DocuFind.iconset"
mkdir -p "$PROJECT_ROOT/Resources" "$BUILD_ROOT/module-cache"
xcrun swift -module-cache-path "$BUILD_ROOT/module-cache" "$PROJECT_ROOT/scripts/make-icon.swift" "$ICONSET"
if ! /usr/bin/iconutil --convert icns --output "$PROJECT_ROOT/Resources/DocuFind.icns" "$ICONSET"; then
    # PNG-backed ICNS is the native container format, including Retina variants.
    python3 - "$ICONSET" "$PROJECT_ROOT/Resources/DocuFind.icns" <<'PY'
from pathlib import Path
import struct
import sys

iconset, destination = map(Path, sys.argv[1:])
variants = [
    (b"icp4", "icon_16x16.png"), (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"), (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"), (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"), (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"), (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
]
chunks = []
for code, filename in variants:
    png = (iconset / filename).read_bytes()
    chunks.append(code + struct.pack(">I", len(png) + 8) + png)
payload = b"".join(chunks)
destination.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY
fi
echo "Updated Resources/DocuFind.icns"
