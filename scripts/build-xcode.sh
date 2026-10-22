#!/bin/bash
# Builds DocuFind with full Xcode.
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
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Full Xcode is required for this script; scripts/build.sh works with the command-line tools." >&2
    echo "Set DEVELOPER_DIR to Xcode.app/Contents/Developer, then run this script again." >&2
    exit 1
fi
"$PROJECT_ROOT/scripts/fetch-sparkle.sh"
python3 "$PROJECT_ROOT/scripts/generate-xcode-project.py"
mkdir -p "$BUILD_ROOT"
xcodebuild -quiet \
    -project "$PROJECT_ROOT/DocuFind.xcodeproj" -scheme DocuFind \
    -configuration Release -sdk macosx -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_ROOT/xcode" \
    ARCHS="$ARCHITECTURE" ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build
BUILT_APP="$BUILD_ROOT/xcode/Build/Products/Release/DocuFind.app"
if [[ ! -d "$BUILT_APP" ]]; then echo "Xcode did not produce DocuFind.app." >&2; exit 1; fi
if [[ -e "$APP_DESTINATION" ]]; then rm -rf "$APP_DESTINATION"; fi
/usr/bin/ditto "$BUILT_APP" "$APP_DESTINATION"
# Update settings come from the environment (see configure-updates.sh); adding them
# changes Info.plist, so the app is signed again.
if [[ -n "${DOCUFIND_APPCAST_URL:-}${DOCUFIND_SPARKLE_PUBLIC_KEY:-}" ]]; then
    "$PROJECT_ROOT/scripts/configure-updates.sh" "$APP_DESTINATION/Contents/Info.plist"
    /usr/bin/codesign --force --sign - --options runtime \
        --entitlements "$PROJECT_ROOT/DocuFind.entitlements" "$APP_DESTINATION"
fi
/usr/bin/codesign --verify --deep --strict "$APP_DESTINATION"
echo "Built: $APP_DESTINATION"
