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

# Signing identity: $ORBIT_SIGN_IDENTITY, else the first line of the git-ignored .orbit-signing file
# (a certificate SHA-1 hash or name from `security find-identity -v -p codesigning`), else ad-hoc.
# A real identity gives the app a stable designated requirement, so macOS keeps its folder-access grants
# across rebuilds; an ad-hoc signature is tied to the exact binary (its cdhash) and is forgotten every build.
IDENTITY="${ORBIT_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .orbit-signing ]]; then
    IFS= read -r IDENTITY < .orbit-signing || true
    IDENTITY="${IDENTITY%$'\r'}"
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "warning: no signing identity (set ORBIT_SIGN_IDENTITY or put one in .orbit-signing); signing ad-hoc." >&2
    echo "warning: macOS will ask for Desktop/Documents/Downloads access again after every rebuild." >&2
fi
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Signed $APP ad-hoc"
else
    echo "Signed $APP with identity: $IDENTITY"
fi
echo "Designated requirement:"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /  /p'
echo "Built $APP"
