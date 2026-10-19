#!/bin/bash
# Builds the app icon from the logo: Support/AppIcon-1024.png (planet mark on a cream rounded square)
# and Support/AppIcon.icns (every standard size, via sips + iconutil).
#
#     scripts/make-icons.sh [--force]
#
# Outputs this script wrote are recorded in Support/AppIcon.sha256. It overwrites an output only while
# that output still matches its recorded hash; anything else at those paths (not ours, or edited by
# hand) is left alone unless you pass --force.
set -euo pipefail
cd "$(dirname "$0")/.."

LOGO=Support/Brand/orbit-logo.png
PNG=Support/AppIcon-1024.png
ICNS=Support/AppIcon.icns
MANIFEST=Support/AppIcon.sha256

FORCE=0
case "${1:-}" in
    "") ;;
    --force) FORCE=1 ;;
    *) echo "usage: scripts/make-icons.sh [--force]" >&2; exit 64 ;;
esac

[[ -f "$LOGO" ]] || { echo "missing $LOGO" >&2; exit 1; }

hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Ours = recorded in the manifest with the same hash as the file on disk now.
is_ours() {
    [[ -f "$MANIFEST" ]] || return 1
    local recorded
    recorded="$(awk -v f="$1" '$2 == f { print $1 }' "$MANIFEST")"
    [[ -n "$recorded" && "$recorded" == "$(hash_of "$1")" ]]
}

if [[ $FORCE -eq 0 ]]; then
    for out in "$PNG" "$ICNS"; do
        if [[ -e "$out" ]] && ! is_ours "$out"; then
            echo "refusing to overwrite $out: this script did not create it (or it was changed since). Use --force." >&2
            exit 1
        fi
    done
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orbit-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

swift scripts/make-icon.swift "$LOGO" "$WORK/icon-1024.png"

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
            256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512; do
    sips -z "${spec%%:*}" "${spec%%:*}" "$WORK/icon-1024.png" --out "$SET/${spec#*:}.png" >/dev/null
done
cp "$WORK/icon-1024.png" "$SET/icon_512x512@2x.png"
iconutil -c icns "$SET" -o "$WORK/AppIcon.icns"

cp "$WORK/icon-1024.png" "$PNG"
cp "$WORK/AppIcon.icns" "$ICNS"
{ echo "$(hash_of "$PNG")  $PNG"; echo "$(hash_of "$ICNS")  $ICNS"; } > "$MANIFEST"
echo "Wrote $PNG and $ICNS"
