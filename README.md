<p align="center">
  <img src="Support/Brand/orbit-logo.png" width="160" alt="Orbit">
</p>

# Orbit

Orbit is a native macOS menu bar app that shows a radial wheel while you drag files, so you can convert and edit them by dropping onto a slice. It works entirely on your Mac: no network access, no telemetry, and no Accessibility or Input Monitoring permission.

<p align="center">
  <a href="docs/demo/orbit-demo.mp4"><img src="docs/demo/orbit-demo.webp" width="100%" alt="Orbit demo: a photo is dragged, Shift opens the wheel, and dropping on PNG converts it; holding Compress opens a sub-ring of presets."></a>
  <br>
  <sub><a href="docs/demo/orbit-demo.mp4">Watch the demo with sound (24 s)</a></sub>
</p>

Requires macOS 14 or later. On macOS 26 the wheel uses Liquid Glass; earlier systems get a frosted-material fallback.

## How it works

Start dragging one or more files in Finder (or on the Desktop), then press a trigger key **after** the drag has begun. The wheel opens under the pointer and stays open when you let go of the key. Move toward a slice and drop. Dropping on the centre hub cancels; dropping outside the wheel goes to whatever is underneath, as a normal drag.

| Wheel | Default keys | What it holds |
|---|---|---|
| **Convert** | Hold Shift **or** ⌘ | Output formats for the dragged file type |
| **Tools** | Hold Shift+⌥ **or** ⌥⌘ | Editing, cleanup and optimization tools |
| **Actions** | Tap Control | Float, AirDrop, Copy Path, Terminal, Copy to, Move to, Archive |

- Pressing another trigger while the wheel is open switches to that wheel in place.
- Holding a slice briefly opens a sub-ring (compression tiers, favourite folders, speed values).
- Several files of the same kind are processed as one batch with one progress panel; mixed selections and folders offer ZIP, TAR and TAR.GZ, and Actions works on anything.
- Prefer the keyboard? Right-click files, choose **Quick Actions → Orbit…**, or use **Open Files…** in the menu bar. Arrow keys move the highlight, Return applies, Escape closes, and ⌘, ⌥ and Control switch wheels.

Results are saved beside the original as `name-<suffix>.<ext>` (for example `photo-converted.png` or `clip-compressed.mp4`). Nothing is ever overwritten: a name collision becomes `-2`, `-3`, and so on, and an unwritable folder falls back to `~/Downloads/Orbit/`. Orbit never modifies a source file; the one exception is **Move to**, which relocates it. A toast offers **Open**, **Show in Finder** and **Undo**.

## Build and install

```sh
scripts/build-app.sh && scripts/install.sh
```

`build-app.sh` produces a universal (arm64 + x86_64), ad-hoc-signed `build/Orbit.app`; `install.sh` copies it to `/Applications` (refusing to replace anything that isn't Orbit) and launches it. Use `scripts/build-app.sh --debug` for a plain debug build. Tests run with `swift test`.

## Optional helpers

Orbit works without these; slices that need a missing helper are hidden and the hub says what to install.

- **ffmpeg**, for MKV, WebM, AVI, WMV, MP3, OGG, Opus and WMA: `brew install ffmpeg`. Orbit looks at the custom path from Settings, then `/opt/homebrew/bin/ffmpeg`, then `/usr/local/bin/ffmpeg`. It is never bundled.
- **Pages, Keynote and Numbers**, from the Mac App Store, for PAGES, NUMBERS and KEY output, slide decks, and reading XLSX, XLS and NUMBERS spreadsheets. Their slices appear only when the app is installed.

## First run

- The first time you use an iWork-backed slice, macOS asks whether Orbit may control Pages, Keynote or Numbers (an Automation prompt). Allow it; it is asked once per app.
- Nothing else is requested. Orbit watches the drag pasteboard and the mouse, which need no permission.
- Orbit is ad-hoc signed, not notarized. If macOS blocks the first launch, right-click the app and choose **Open**.

## Settings

Open **Settings…** from the menu bar icon.

- **Triggers:** record the key combination for each wheel.
- **Output:** reveal results in Finder; quality defaults for JPEG, HEIC, WebP and AVIF; PDF-to-image resolution; presets for compression and "fit under" sizes.
- **Copy / Move:** favourite folders for the Copy to and Move to sub-rings (Desktop, Documents and Downloads by default).
- **Terminal:** which terminal app the Terminal action opens (Terminal, iTerm, Ghostty or Warp).
- **Helpers:** whether ffmpeg, Pages, Keynote and Numbers were found, with a one-line way to get each.
- **General:** launch at login, haptic feedback, and the **accent colour** (default `#80649C`) used for the wheel's highlight and the editors' controls. It comes with a colour well, the hex value and a reset button.

The menu bar menu also has an **Enabled** toggle, **Recent results** (the last 10) and **Quit**.

## Logs

`~/Library/Logs/Orbit/orbit.log`. Run the app with `--diagnose-trigger` to log every trigger input sample and drop callback there.

## License

MIT. See [LICENSE](LICENSE). © k-gdev.
