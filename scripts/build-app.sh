#!/bin/bash
# Builds build/Orbit.app. Default: universal release. --debug: plain debug build.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--debug" ]]; then
    swift build
    BIN="$(swift build --show-bin-path)/Orbit"
else
    ARCHS=(--arch arm64 --arch x86_64)
    swift build -c release "${ARCHS[@]}"
    BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Orbit"
fi

# build/ is generated output owned by this script.
rm -rf build
mkdir -p build/Orbit.app/Contents/MacOS
cp "$BIN" build/Orbit.app/Contents/MacOS/Orbit
cp Support/Info.plist build/Orbit.app/Contents/Info.plist
codesign --force --sign - build/Orbit.app
echo "Built build/Orbit.app"
