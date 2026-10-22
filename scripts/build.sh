#!/bin/bash
# Build a portable .app with the command-line tools, or with full Xcode when installed.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
BUILD_ROOT="${DOCUFIND_BUILD_DIR:-$(cd "$PROJECT_ROOT/../.." && pwd)/work/docufind-build}"
APP_DESTINATION="${DOCUFIND_APP_DESTINATION:-$OUTPUT_ROOT/DocuFind.app}"
ARCHITECTURE="${DOCUFIND_ARCH:-$(uname -m)}"
case "$ARCHITECTURE" in
    arm64|x86_64) ;;
    *) echo "Unsupported build architecture: $ARCHITECTURE" >&2; exit 1 ;;
esac
mkdir -p "$BUILD_ROOT"
# Sparkle (automatic updates) is downloaded once into vendor/ and checked against a pinned hash.
"$PROJECT_ROOT/scripts/fetch-sparkle.sh"

if xcrun --find xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1 && [[ "${DOCUFIND_USE_SWIFTC:-0}" != "1" ]]; then
    exec "$PROJECT_ROOT/scripts/build-xcode.sh"
fi

echo "Building DocuFind for $ARCHITECTURE with the installed command-line tools…"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
STAGING_DIR="$(mktemp -d "$BUILD_ROOT/staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_STAGING="$STAGING_DIR/DocuFind.app"
mkdir -p "$APP_STAGING/Contents/MacOS" "$APP_STAGING/Contents/Resources/backend" "$BUILD_ROOT/module-cache"

SOURCES=()
while IFS= read -r -d '' source_file; do SOURCES+=("$source_file"); done < <(find "$PROJECT_ROOT/Sources/DocuFind" -name '*.swift' -type f -print0)
if [[ "${#SOURCES[@]}" -eq 0 ]]; then
    echo "No Swift sources found in $PROJECT_ROOT/Sources/DocuFind." >&2
    exit 1
fi
xcrun swiftc -parse-as-library -O -swift-version 5 \
    -target "$ARCHITECTURE-apple-macosx15.0" -sdk "$SDK_PATH" \
    -module-name DocuFind -module-cache-path "$BUILD_ROOT/module-cache" \
    -framework AppKit -framework SwiftUI -framework CoreSpotlight \
    -framework UniformTypeIdentifiers \
    -F "$PROJECT_ROOT/vendor/Sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${SOURCES[@]}" -o "$APP_STAGING/Contents/MacOS/DocuFind"

/usr/bin/ditto "$PROJECT_ROOT/Info.plist" "$APP_STAGING/Contents/Info.plist"
"$PROJECT_ROOT/scripts/configure-updates.sh" "$APP_STAGING/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_STAGING/Contents/Info.plist" >/dev/null
for resource in DocuFind.icns Banner.png; do
    if [[ -f "$PROJECT_ROOT/Resources/$resource" ]]; then
        /usr/bin/ditto "$PROJECT_ROOT/Resources/$resource" "$APP_STAGING/Contents/Resources/$resource"
    fi
done
/usr/bin/rsync -a --delete \
    --exclude='.venv' --exclude='__pycache__' --exclude='.pytest_cache' \
    --exclude='.DS_Store' --exclude='*.pyc' --exclude='tests' \
    "$PROJECT_ROOT/backend/" "$APP_STAGING/Contents/Resources/backend/"
printf 'APPL????' > "$APP_STAGING/Contents/PkgInfo"
# Ad-hoc signing changes the app's identity on every build, so macOS forgets
# granted privacy permissions. Set DOCUFIND_SIGN_IDENTITY to a code-signing
# certificate (see `security find-identity -v -p codesigning`) to keep them.
# With a real identity the app is signed for distribution: hardened runtime and a
# secure timestamp, both required for notarization.
# Sparkle, the docufind tool and the text-recognition helper are added and signed first, then the app.
"$PROJECT_ROOT/scripts/embed-helpers.sh" "$APP_STAGING" "$ARCHITECTURE" "$BUILD_ROOT/module-cache" "${DOCUFIND_SIGN_IDENTITY:--}"
if [[ -n "${DOCUFIND_SIGN_IDENTITY:-}" ]]; then
    /usr/bin/codesign --force --sign "$DOCUFIND_SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$PROJECT_ROOT/DocuFind.entitlements" "$APP_STAGING"
else
    /usr/bin/codesign --force --sign - --entitlements "$PROJECT_ROOT/DocuFind.entitlements" "$APP_STAGING"
fi
/usr/bin/codesign --verify --deep --strict "$APP_STAGING"
if [[ -e "$APP_DESTINATION" ]]; then rm -rf "$APP_DESTINATION"; fi
/usr/bin/ditto "$APP_STAGING" "$APP_DESTINATION"
echo "Built: $APP_DESTINATION"
