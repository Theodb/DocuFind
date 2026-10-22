#!/bin/bash
# Downloads the pinned Sparkle release (automatic updates) into vendor/Sparkle and
# checks it against a hard-coded SHA-256. Does nothing when it is already there.
#
# To move to a newer Sparkle, change SPARKLE_VERSION, download the tarball from
# https://github.com/sparkle-project/Sparkle/releases, and replace SPARKLE_SHA256
# with the output of `shasum -a 256 Sparkle-<version>.tar.xz`.
set -euo pipefail

SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$PROJECT_ROOT/vendor/Sparkle"
MARKER="$DESTINATION/.docufind-sparkle-version"

if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$SPARKLE_VERSION $SPARKLE_SHA256" \
      && -d "$DESTINATION/Sparkle.framework" && -x "$DESTINATION/bin/sign_update" ]]; then
    exit 0
fi

echo "Downloading Sparkle ${SPARKLE_VERSION}…"
DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
ARCHIVE="$DOWNLOAD_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
/usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --retry 2 --output "$ARCHIVE" "$SPARKLE_URL"
ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]]; then
    echo "The Sparkle download does not match its pinned checksum." >&2
    echo "  expected $SPARKLE_SHA256" >&2
    echo "  got      $ACTUAL_SHA256" >&2
    exit 1
fi

mkdir -p "$DOWNLOAD_DIR/unpacked"
/usr/bin/tar -xJf "$ARCHIVE" -C "$DOWNLOAD_DIR/unpacked"
if [[ ! -d "$DOWNLOAD_DIR/unpacked/Sparkle.framework" || ! -x "$DOWNLOAD_DIR/unpacked/bin/sign_update" ]]; then
    echo "The Sparkle archive does not have the expected layout." >&2
    exit 1
fi
rm -rf "$DESTINATION"
# Keep only what the build and release scripts use: the framework, the signing
# tools and the license.
mkdir -p "$DESTINATION"
/usr/bin/ditto "$DOWNLOAD_DIR/unpacked/Sparkle.framework" "$DESTINATION/Sparkle.framework"
/usr/bin/ditto "$DOWNLOAD_DIR/unpacked/bin" "$DESTINATION/bin"
/usr/bin/ditto "$DOWNLOAD_DIR/unpacked/LICENSE" "$DESTINATION/LICENSE"
echo "$SPARKLE_VERSION $SPARKLE_SHA256" > "$MARKER"
echo "Sparkle $SPARKLE_VERSION is in $DESTINATION"
