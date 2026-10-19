#!/bin/bash
# Builds build/Orbit.app. Default: universal release. --debug: plain debug build.
set -euo pipefail
cd "$(dirname "$0")/.."

# Only build/Orbit.app belongs to this script; anything else under build/ is left alone.
APP="build/Orbit.app"
BUNDLE_ID="com.kevo.orbit"
mkdir -p build
if [[ -L "$APP" ]]; then
    echo "error: $APP is a symbolic link, not an Orbit build; refusing to replace it" >&2
    exit 1
fi
if [[ -e "$APP" ]]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing" != "$BUNDLE_ID" ]]; then
        echo "error: $APP exists and is not an Orbit build (bundle id '${existing:-unknown}'); refusing to replace it" >&2
        exit 1
    fi
fi

if [[ "${1:-}" == "--debug" ]]; then
    swift build
    BIN="$(swift build --show-bin-path)/Orbit"
else
    ARCHS=(--arch arm64 --arch x86_64)
    swift build -c release "${ARCHS[@]}"
    BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Orbit"
fi

# Replace only our own previous build (checked above, before building).
if [[ -e "$APP" ]]; then rm -rf "$APP"; fi
mkdir -p build/Orbit.app/Contents/MacOS
cp "$BIN" build/Orbit.app/Contents/MacOS/Orbit
cp Support/Info.plist build/Orbit.app/Contents/Info.plist
mkdir -p build/Orbit.app/Contents/Resources
cp Support/AppIcon.icns build/Orbit.app/Contents/Resources/AppIcon.icns
codesign --force --sign - build/Orbit.app
echo "Built build/Orbit.app"
