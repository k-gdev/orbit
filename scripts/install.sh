#!/bin/bash
# Installs build/Orbit.app to /Applications, refusing to replace a foreign app.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="build/Orbit.app"
DEST="/Applications/Orbit.app"
BUNDLE_ID="com.kevo.orbit"

if [[ ! -d "$SRC" ]]; then
    echo "error: $SRC not found; run scripts/build-app.sh first" >&2
    exit 1
fi

if [[ -e "$DEST" ]]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing" != "$BUNDLE_ID" ]]; then
        echo "error: $DEST exists and is not Orbit (bundle id '${existing:-unknown}'); refusing to replace it" >&2
        exit 1
    fi
fi

osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
ditto "$SRC" "$DEST"
open "$DEST"
echo "Installed $DEST"
