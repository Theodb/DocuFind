#!/bin/bash
# Builds a signed, notarized DocuFind disk image ready to share, plus what the update
# feed needs. Nothing is uploaded anywhere except to Apple's notary service.
#
# Output, in ../dist:
#   DocuFind-<version>.dmg          signed, notarized and stapled disk image
#   DocuFind-<version>.dmg.sha256   its checksum
#   appcast.xml                     Sparkle update feed, with this release added
#
# Needs an Apple Developer account and, once per Mac:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates, or developer.apple.com).
#   2. Notary credentials saved under a profile name:
#      xcrun notarytool store-credentials docufind-notary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#   3. An update signing key. Run ./scripts/fetch-sparkle.sh, then
#      vendor/Sparkle/bin/generate_keys
#      It stores the private key in the login keychain and prints the public key;
#      pass that as DOCUFIND_SPARKLE_PUBLIC_KEY. Back up the private key
#      (generate_keys -x <file>): without it, installed copies can't be updated.
#
# Usage:
#   DOCUFIND_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   DOCUFIND_NOTARY_PROFILE=docufind-notary \
#   DOCUFIND_GITHUB_REPO=you/DocuFind \
#   DOCUFIND_APPCAST_URL=https://raw.githubusercontent.com/you/DocuFind/main/appcast.xml \
#   DOCUFIND_SPARKLE_PUBLIC_KEY=<public key from generate_keys> \
#   ./scripts/release.sh
#
# DOCUFIND_SIGN_IDENTITY can also be the certificate's hash from security find-identity,
# which is needed when the name has accents.
#
# Optional:
#   DOCUFIND_SPARKLE_KEY_FILE   private update key in a file instead of the keychain
#   DOCUFIND_DIST_DIR           output folder (default ../dist)
#   DOCUFIND_APP_DESTINATION    where the built app is copied (default ../DocuFind.app)
#   DOCUFIND_RELEASE_UNSIGNED=1 local test: builds an ad-hoc signed disk image in
#                               dist/unsigned-test without notarizing. Not for
#                               distribution: Gatekeeper blocks it on other Macs.
#
# Increase CFBundleVersion in Info.plist for every release; Sparkle compares it.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
UNSIGNED="${DOCUFIND_RELEASE_UNSIGNED:-0}"
REPOSITORY="${DOCUFIND_GITHUB_REPO:-}"

if [[ "$UNSIGNED" == "1" ]]; then
    echo "Building an UNSIGNED test disk image. It is not notarized and not for distribution."
    unset DOCUFIND_SIGN_IDENTITY
    IDENTITY=""
    REPOSITORY="${REPOSITORY:-OWNER/DocuFind}"
else
    IDENTITY="${DOCUFIND_SIGN_IDENTITY:?Set DOCUFIND_SIGN_IDENTITY to your Developer ID Application certificate name, or DOCUFIND_RELEASE_UNSIGNED=1 for a local test.}"
    PROFILE="${DOCUFIND_NOTARY_PROFILE:?Set DOCUFIND_NOTARY_PROFILE to a notarytool keychain profile.}"
    if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "Set DOCUFIND_GITHUB_REPO to the GitHub repository that hosts releases, like you/DocuFind." >&2
        exit 1
    fi
    if [[ -z "${DOCUFIND_APPCAST_URL:-}" || -z "${DOCUFIND_SPARKLE_PUBLIC_KEY:-}" ]]; then
        echo "Set DOCUFIND_APPCAST_URL and DOCUFIND_SPARKLE_PUBLIC_KEY so the release can update itself." >&2
        echo "The comments at the top of this script explain the one-time key setup." >&2
        exit 1
    fi
    # The certificate's name or its hash: codesign can't find a name with accents, so the hash is safer.
    FOUND="$(security find-identity -v -p codesigning | grep -F "$IDENTITY" || true)"
    if [[ -z "$FOUND" ]]; then
        echo "The certificate \"$IDENTITY\" is not in your keychain." >&2
        exit 1
    fi
    if [[ "$FOUND" != *'"Developer ID Application:'* ]]; then
        echo "Use a \"Developer ID Application\" certificate; other certificates cannot be notarized for distribution." >&2
        exit 1
    fi
fi

"$PROJECT_ROOT/scripts/fetch-sparkle.sh"
SPARKLE_BIN="$PROJECT_ROOT/vendor/Sparkle/bin"
SIGN_UPDATE=("$SPARKLE_BIN/sign_update")
if [[ -n "${DOCUFIND_SPARKLE_KEY_FILE:-}" ]]; then
    SIGN_UPDATE+=(--ed-key-file "$DOCUFIND_SPARKLE_KEY_FILE")
elif [[ "$UNSIGNED" != "1" ]]; then
    # The keychain key must match the public key built into the app, or no update would install.
    KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
    if [[ "$KEYCHAIN_PUBLIC_KEY" != "$DOCUFIND_SPARKLE_PUBLIC_KEY" ]]; then
        echo "DOCUFIND_SPARKLE_PUBLIC_KEY doesn't match the update key in your keychain (generate_keys -p)." >&2
        exit 1
    fi
fi

INFO="$PROJECT_ROOT/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"
APP="${DOCUFIND_APP_DESTINATION:-$OUTPUT_ROOT/DocuFind.app}"
DIST="${DOCUFIND_DIST_DIR:-$OUTPUT_ROOT/dist}"
NAME="DocuFind-$VERSION"
if [[ "$UNSIGNED" == "1" ]]; then
    DIST="$DIST/unsigned-test"
    NAME="DocuFind-$VERSION-UNSIGNED-not-for-distribution"
fi
DMG="$DIST/$NAME.dmg"
DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/$NAME.dmg"
mkdir -p "$DIST"
if [[ -f "$DIST/appcast.xml" ]]; then
    /usr/bin/python3 "$PROJECT_ROOT/scripts/update-appcast.py" "$DIST/appcast.xml" --check \
        --version "$VERSION" --build "$BUILD_NUMBER"
fi

echo "Building DocuFind ${VERSION} (build ${BUILD_NUMBER})…"
DOCUFIND_USE_SWIFTC=1 DOCUFIND_APP_DESTINATION="$APP" "$PROJECT_ROOT/scripts/build.sh"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "$UNSIGNED" != "1" ]]; then
    # Read in full first: grep -q stops early, and with pipefail codesign's broken pipe would fail the check.
    SIGNATURE_INFO="$(/usr/bin/codesign --display --verbose=2 "$APP" 2>&1)"
    [[ "$SIGNATURE_INFO" == *"flags="*"runtime"* ]] || { echo "The hardened runtime is not enabled." >&2; exit 1; }
    /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" >/dev/null || { echo "The app has no update feed." >&2; exit 1; }
fi

echo "Creating the disk image…"
STAGING="$(mktemp -d)"
MOUNT="$STAGING/mount"
cleanup() {
    if [[ -d "$MOUNT" ]] && /sbin/mount | grep -Fq "$MOUNT"; then /usr/bin/hdiutil detach "$MOUNT" -quiet -force || true; fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
mkdir -p "$STAGING/content" "$MOUNT"
/usr/bin/ditto "$APP" "$STAGING/content/DocuFind.app"
ln -s /Applications "$STAGING/content/Applications"
/usr/bin/ditto "$PROJECT_ROOT/Resources/DocuFind.icns" "$STAGING/content/.VolumeIcon.icns"
/usr/bin/hdiutil create -volname "DocuFind" -srcfolder "$STAGING/content" -fs HFS+ \
    -format UDRW -ov "$STAGING/writable.dmg" >/dev/null
# Give the volume the app's icon: set the "has custom icon" Finder flag on its root.
/usr/bin/hdiutil attach "$STAGING/writable.dmg" -mountpoint "$MOUNT" -nobrowse -noautoopen -quiet
/usr/bin/xattr -wx com.apple.FinderInfo \
    "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
/usr/bin/hdiutil detach "$MOUNT" -quiet
rm -f "$DMG"
/usr/bin/hdiutil convert "$STAGING/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

if [[ "$UNSIGNED" != "1" ]]; then
    /usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    echo "Submitting to Apple for notarization (this usually takes a few minutes)…"
    SUBMISSION="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json)"
    STATUS="$(/usr/bin/plutil -extract status raw - <<< "$SUBMISSION" 2>/dev/null || echo unknown)"
    if [[ "$STATUS" != "Accepted" ]]; then
        echo "Notarization finished with status: $STATUS" >&2
        SUBMISSION_ID="$(/usr/bin/plutil -extract id raw - <<< "$SUBMISSION" 2>/dev/null || true)"
        if [[ -n "$SUBMISSION_ID" ]]; then xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2 || true; fi
        exit 1
    fi
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

# Everything below describes the final file, so it comes after stapling.
SHA256="$(/usr/bin/shasum -a 256 "$DMG" | awk '{print $1}')"
echo "$SHA256  $(basename "$DMG")" > "$DMG.sha256"

if [[ "$UNSIGNED" != "1" || -n "${DOCUFIND_SPARKLE_KEY_FILE:-}" ]]; then
    echo "Signing the update for Sparkle…"
    SIGNATURE="$("${SIGN_UPDATE[@]}" -p "$DMG")"
    "${SIGN_UPDATE[@]}" --verify "$DMG" "$SIGNATURE" >/dev/null
    /usr/bin/python3 "$PROJECT_ROOT/scripts/update-appcast.py" "$DIST/appcast.xml" \
        --version "$VERSION" --build "$BUILD_NUMBER" --minimum-system "$MINIMUM_SYSTEM" \
        --url "$DOWNLOAD_URL" --signature "$SIGNATURE" --length "$(stat -f %z "$DMG")"
else
    echo "Skipping the update feed: unsigned test without DOCUFIND_SPARKLE_KEY_FILE."
fi

echo
echo "Disk image: $DMG"
echo "SHA-256:    $SHA256"
if [[ "$UNSIGNED" == "1" ]]; then
    echo "This test image is ad-hoc signed and not notarized. Do not distribute it."
else
    echo "Next: create the GitHub release v$VERSION with $(basename "$DMG"), and publish"
    echo "$DIST/appcast.xml at $DOCUFIND_APPCAST_URL."
fi
