#!/bin/bash
# Adds the code that ships inside DocuFind.app besides the app itself, and signs it:
#   Contents/Frameworks/Sparkle.framework   automatic updates (from vendor/Sparkle)
#   Contents/Helpers/docufind               the command-line tool
#   Contents/Helpers/docufind-ocr           reads text in pictures and scanned PDF pages
# Used by build.sh and by the Xcode project. The app itself is signed afterwards.
#
# Usage: embed-helpers.sh <DocuFind.app> <arm64|x86_64> <module cache dir> [signing identity, or - for ad hoc]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: embed-helpers.sh <app> <arch> <module-cache> [identity]}"
ARCHITECTURE="${2:?Give the architecture}"
MODULE_CACHE="${3:?Give a module cache directory}"
IDENTITY="${4:--}"
SPARKLE_DIR="$PROJECT_ROOT/vendor/Sparkle"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$MODULE_CACHE"

# The command-line tool lives in Contents/Helpers because Contents/MacOS already holds
# "DocuFind", and on most Macs file names differing only by case are the same file.
# A small Info.plist is embedded in the binary so `docufind --version` works through
# a symlink such as /usr/local/bin/docufind.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Info.plist")"
CLI_INFO="$WORK/docufind-Info.plist"
/usr/bin/plutil -create xml1 "$CLI_INFO"
/usr/bin/plutil -insert CFBundleIdentifier -string com.theodeschampsberger.DocuFind.cli "$CLI_INFO"
/usr/bin/plutil -insert CFBundleName -string docufind "$CLI_INFO"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$CLI_INFO"
xcrun swiftc -O -swift-version 5 \
    -target "$ARCHITECTURE-apple-macosx15.0" -sdk "$SDK_PATH" \
    -module-name docufind -module-cache-path "$MODULE_CACHE" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$CLI_INFO" \
    "$PROJECT_ROOT/Sources/docufind-cli/main.swift" -o "$APP/Contents/Helpers/docufind"

# The text-recognition helper the search worker runs.
xcrun swiftc -O -swift-version 5 \
    -target "$ARCHITECTURE-apple-macosx15.0" -sdk "$SDK_PATH" \
    -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_ROOT/Sources/DocuFindOCR/main.swift" -o "$APP/Contents/Helpers/docufind-ocr"

# Sparkle, without the parts a non-sandboxed app never loads: the XPC services are
# only for sandboxed apps, and headers and module maps are only for compiling.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE"
/usr/bin/ditto "$SPARKLE_DIR/Sparkle.framework" "$SPARKLE"
for unused in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "${SPARKLE:?}/$unused" "${SPARKLE:?}/Versions/B/$unused"
done

# Sign from the inside out. A real identity gets the hardened runtime and a secure
# timestamp, which notarization requires.
if [[ "$IDENTITY" == "-" ]]; then
    SIGN=(/usr/bin/codesign --force --sign -)
else
    SIGN=(/usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp)
fi
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" --identifier com.theodeschampsberger.DocuFind.cli "$APP/Contents/Helpers/docufind"
"${SIGN[@]}" --identifier com.theodeschampsberger.DocuFind.ocr "$APP/Contents/Helpers/docufind-ocr"
