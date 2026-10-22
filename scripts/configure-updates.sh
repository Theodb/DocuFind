#!/bin/bash
# Adds the automatic update settings to a built app's Info.plist:
#   DOCUFIND_APPCAST_URL          https address of appcast.xml (Sparkle's SUFeedURL)
#   DOCUFIND_SPARKLE_PUBLIC_KEY   public key printed by Sparkle's generate_keys (SUPublicEDKey)
# Without both, the app is built with updates turned off.
set -euo pipefail

PLIST="${1:?Usage: configure-updates.sh <Info.plist>}"
FEED="${DOCUFIND_APPCAST_URL:-}"
KEY="${DOCUFIND_SPARKLE_PUBLIC_KEY:-}"

if [[ -z "$FEED" && -z "$KEY" ]]; then
    exit 0
fi
if [[ -z "$FEED" || -z "$KEY" ]]; then
    echo "Set both DOCUFIND_APPCAST_URL and DOCUFIND_SPARKLE_PUBLIC_KEY, or neither." >&2
    exit 1
fi
if [[ ! "$FEED" =~ ^https://[^[:space:]]+$ ]]; then
    echo "DOCUFIND_APPCAST_URL must be an https:// address." >&2
    exit 1
fi
# An Ed25519 public key is 32 bytes: 44 characters of base64.
if [[ ! "$KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "DOCUFIND_SPARKLE_PUBLIC_KEY doesn't look like a key printed by generate_keys." >&2
    exit 1
fi
/usr/bin/plutil -replace SUFeedURL -string "$FEED" "$PLIST"
/usr/bin/plutil -replace SUPublicEDKey -string "$KEY" "$PLIST"
echo "Automatic updates enabled: $FEED"
