# Orbit — Design

**Date:** 2026-10-18
**Status:** Draft for Kevo's approval

## 1. Intent

Orbit is a macOS menu bar utility that turns a file drag into a command. You
start dragging files in Finder (or on the Desktop), press a modifier key, and a
glassy wheel of choices appears under the pointer. Dropping the files on a slice
converts, edits or hands them off. The result is saved next to the original, the
original is never touched, and Finder shows you the new file.

Kevo is building it for his own Mac and will publish the source on GitHub
("why not"). There is no commercial goal.

Reference points Kevo supplied:

- **Tangerine** (commercial, Mac App Store, by Leap Studio). Kevo wants Orbit to
  have Tangerine's features. Its published feature set is folded into §6.
- **DragShift** (`github.com/llamaboi55/DragShift`, MIT, Python/PySide6). Same
  idea, cross-platform. Useful prior art for how the trigger is detected on macOS
  without special permissions (§8).
- **`hero.mp4`** (`/Users/kevog/Downloads/hero.mp4`, 22 s). This is the look and
  feel target (§5).

## 2. Goals

1. Feel instant. The wheel appears on the same frame you press the key, with no
   visible lag. (A review of Tangerine called out occasional lag opening the
   wheel on an M1. Orbit must not have it.)
2. Cover everything in Kevo's feature list, Tangerine's feature list and the tools
   visible in the hero video (§6), in one build.
3. Never touch the original file. Every output is a new file beside the source.
4. Work entirely offline. No network calls of any kind.
5. Run silently: menu bar icon only, no Dock icon, no window unless a tool needs
   one.

## 3. Non-goals

- Mac App Store distribution and the App Sandbox.
- Windows or Linux. A port would be a separate project later.
- Accounts, licensing, payments, telemetry, analytics or auto-update.
- Bundling ffmpeg or the iWork apps. Orbit uses them when they are installed.

## 4. Anti-goals (failures even if everything "works")

- **Overwriting or modifying a source file**, for any reason, including on
  error.
- **Getting in the way of normal dragging.** The wheel must never appear for
  window drags, text selection, or a file drag without the trigger key. If you
  drag past the wheel and drop elsewhere, Finder's normal behavior (move, copy,
  alias) must be unchanged.
- **Fake redaction.** A redacted PDF or image where the blacked-out text or
  pixels can still be recovered (selected, copied, or revealed by removing a
  layer) is a security bug, not a cosmetic one.
- **Silent failure.** Every action ends with a visible result or a plain-language
  error.
- **Permission nagging.** Orbit should not need Accessibility or Input
  Monitoring permission for its trigger (§8). It may need one-time Automation
  prompts for the iWork apps.
- **Copying Tangerine's branding or assets.** Orbit has its own name, icon and
  look. Feature parity is the goal, not a clone of its identity.

## 5. Look and feel

Target: the hero video. In it:

- The wheel is a ring of petal-shaped slices with clear gaps between them,
  around a round center hub.
- The hub shows a thumbnail of the dragged file and, in a pill, the name of the
  slice under the pointer.
- Conversion slices show the format name (MP4, MKV, GIF). Tool slices show an
  SF Symbol above an uppercase label (COMPRESS, TRIM, CROP, SPEED, SNAPSHOT,
  SPLIT, MUTE, REMOVE META).
- The hovered slice fills with a warm orange accent. The rest are translucent
  glass tinted by what's behind them.
- Editor windows (the hero's "Crop Video" panel) and the progress panel
  ("Converting to MP4", "Cropping video") use the same translucent rounded glass,
  a close button at top left, and an orange primary button.

Rendering:

- **macOS 26 and later:** Apple's native Liquid Glass.
- **macOS 14 and 15:** the system frosted material (`NSVisualEffectView`) with a
  light tint. This path cannot be tested on Kevo's Mac (26.5).
- Both light and dark appearance must look right.
- Motion: the wheel scales in with a spring. The highlight follows the pointer
  with spring physics. A subtle trackpad haptic tick plays when the highlighted
  slice changes, and a stronger one when a job completes. *(The hover tick is my
  call. Kevo's spec only asked for the completion haptic.)*

Exact colors, sizes and radii are left to the builder, matched by eye to the
hero video.

## 6. Features

### 6.1 Triggers and the wheel

Default triggers (all changeable in Settings):

| Wheel | Default keys | Contents |
|---|---|---|
| **Convert** | Hold Shift **or** ⌘ | Output formats for the file type |
| **Tools** | Hold Shift+⌥ **or** ⌥⌘ | Editing, cleanup and optimization tools |
| **Actions** | Tap Control | Float, AirDrop, Copy Path, Terminal, Copy to, Move to, Archive |

Behavior:

- The wheel opens only during a real drag of file URLs. Finder and the Desktop
  must work. Other apps that drag files are a bonus. *(My call.)*
- The trigger fires only when the key is pressed **after** the drag has started.
  Holding Shift or ⌘ while you *start* a drag, for example after shift-clicking
  to extend a Finder selection, does not open the wheel until you release and
  press again. *(My call. It keeps normal Finder habits safe.)*
- It opens centered on the pointer at the moment the trigger fires.
- After it opens it stays open when the keys are released, until you drop or
  cancel. This matches Tangerine and lets you aim without holding keys.
- While open, pressing another trigger switches to that wheel in place.
- **Dead zone:** dropping in the inner hub does nothing (cancel).
- **Selection by angle:** past the dead-zone radius, the slice in the pointer's
  direction is highlighted. You don't have to be precisely inside the petal.
  Leaving the wheel's outer edge clears the highlight. Dropping out there goes to
  whatever is beneath, as a normal drag.
- **Escape** cancels the drag, which is macOS's own behavior, and Orbit hides
  the wheel when the drag ends. Orbit does not try to keep the drag alive,
  because that would need a keyboard permission (§8).
- Slice sets depend on the dragged files (§6.3 onward). The ring shows at most
  10 slices. Some slices open a **sub-ring** when you hover on them briefly
  (compression tiers, folder targets, speed values). This avoids extra windows
  for quick choices. *(Sub-rings are my call.)*

Selections with several files:

- **All the same category:** that category's wheels. Each file is processed in
  turn as a single batch with one progress panel. Combining slices, such as
  Images→one PDF, Merge PDFs or Join videos, appear only when several files are
  dragged.
- **Mixed categories, or folders:** Convert offers ZIP, TAR and TAR.GZ (one
  archive of everything). Actions always works, and its **Archive** slice can
  pack any selection, including five photos (§6.8). Tools shows only what applies to
  every item. If nothing applies, the hub says so.
- **Formats Orbit can't handle:** Actions still works, and the other wheels
  explain why they're empty.

Keyboard path *(my call; Tangerine has arrow/Enter/Escape navigation)*:

- A Finder Quick Action **"Orbit…"** (right-click → Quick Actions) and a menu bar
  item **"Open Files…"** open the wheel at the pointer for chosen files without
  dragging.
- In this mode the wheel is a normal window. Arrow keys move the highlight,
  Return applies, Escape closes, ⌘/⌥/Control switch wheels, and clicking works.

### 6.2 Output, progress and results

- **Placement:** in the same folder as the source.
- **Naming:** `name-<suffix>.<ext>`. Conversions use `-converted`
  (`photo-converted.png`). Tools use their own suffix: `-compressed`, `-nobg`,
  `-clean`, `-trimmed`, `-cropped`, `-redacted`, and so on.
- **Collisions:** append `-2`, `-3`, … Never overwrite.
- **Combined outputs** (one PDF from many images, one archive from many files)
  are named after the first item in the order used (§6.3), plus `-combined`, or
  `Archive.zip` style for packing. *(My call.)*
- **Unwritable source folder** (a mounted DMG, a read-only share): save to
  `~/Downloads/Orbit/` instead and say so in the result. *(My call.)*
- **Progress panel:** any job that takes more than about half a second shows a
  compact glass panel near where you dropped. It shows the action ("Converting
  to MP4"), the file name, a progress bar, `n of m` for batches, and × to cancel.
  Several jobs stack. The menu bar icon also shows that work is running.
- **On completion:**
  1. A trackpad haptic plays.
  2. Finder reveals and selects the new file(s), as Kevo's spec requires.
     Settings has a toggle to turn this off.
  3. A small result toast shows what changed (for example `2.4 MB → 610 KB · 75%
     smaller` or `4032×3024 → 2016×1512`) with **Open**, **Show in Finder** and
     **Undo**. Undo moves the new file(s) to the Trash.
- **On error or cancel:** a toast in plain language. Partial outputs that Orbit
  created are moved to the Trash. Nothing else is touched.

### 6.3 Images

Input: PNG, JPG/JPEG, HEIC/HEIF, WebP, TIFF, BMP, GIF, ICO, AVIF, SVG.

**Convert:** JPG, PNG, HEIC, WebP, TIFF, AVIF, BMP, GIF, ICO, PDF. The source's
own format is omitted.

- SVG is input only. It is rasterized at a sensible size (builder's call).
- Several images dropped on **PDF** become **one** multi-page PDF. Pages follow
  natural filename order (`img2` before `img10`), because Finder's drag order
  isn't reliable. *(My call.)*

**Tools:**

| Tool | What it does |
|---|---|
| **Remove BG** | Uses Apple's on-device Vision subject isolation (macOS 14+) to cut out the subject and save a transparent PNG. |
| **Add BG** | Editor: put the cut-out subject (or a transparent image) on a solid color, gradient or blurred backdrop (Tangerine). |
| **Markup** | Editor: crop (free or fixed ratios), resize by pixels or percent, arrows, boxes, text, marker, numbered steps, and blackout/redact. Redaction and blackout are burned into the pixels. |
| **Adjust** | Editor: auto-enhance, exposure, contrast, saturation, warmth, B&W, rotate and flip, with hold-to-compare (Tangerine "Edit photo"). |
| **Compress** | Sub-ring of tiers: Light, Medium, Strong (percentage reductions), **Fit under…** (presets such as 500 KB, 1 MB, 5 MB), and **Custom…** (small panel). Works on batches. |
| **Metadata** | Sub-ring: **Strip all** (GPS, camera, serial numbers, dates), **Strip location only**, **View & edit…** (panel listing camera, date, GPS with a map link, and editable fields). |
| **Read QR** | Decodes QR and barcodes with Vision and copies the text. If it's a URL, the toast offers **Open**. No file is written. |
| **Collage** | (Several images only.) Lays the images out in a grid as one image or PDF. |

### 6.4 Video

Input: MP4, MOV, M4V, plus MKV, WebM, AVI and WMV (these four need ffmpeg to
read).

**Convert:**

- **Native:** MP4, MOV, GIF (looped, lightweight).
- **Needs ffmpeg:** MKV, WebM, AVI, WMV.
- **Audio extracts:** M4A (native) and MP3 (needs ffmpeg).

**Tools** (the eight in the hero video, plus Join):

| Tool | What it does |
|---|---|
| **Compress** | Sub-ring: **Fit under** presets (10 MB, 25 MB, 50 MB, 100 MB), plus percentage tiers. Bitrate is computed from the target size and duration and re-encoded with the Apple media engine (VideoToolbox H.264/HEVC). |
| **Trim** | Editor: choose start and end on a scrubber, with preview. |
| **Crop** | Editor like the hero's "Crop Video": aspect ratio presets or freeform, width/height sliders, live pixel size, and a frame scrubber. |
| **Speed** | Sub-ring: 0.25×, 0.5×, 1.5×, 2×, 4×. Audio is pitch-corrected, or dropped at extreme speeds. |
| **Split** | Editor: split at chosen points, or into N equal parts. |
| **Snapshot** | Editor: scrub to a frame and save it as PNG at full resolution. |
| **Mute** | Removes the audio track without re-encoding the video. |
| **Remove Meta** | Strips container metadata (location, device, dates) without re-encoding. |
| **Join** | (Several videos only.) Joins them end to end in natural filename order. |

Kevo's "Audio stripping: extracts the soundtrack" is covered by the Convert
wheel's M4A and MP3 slices.

**Formats Apple can't read or write (applies to §6.4 and §6.5)** *(my call,
honoring "every feature")*:

- **Output keeps the source format.** A trimmed MKV stays MKV, a normalized MP3
  stays MP3, a compressed FLAC stays FLAC (lossless can't be bitrate-compressed,
  so for WAV and FLAC, Compress means converting to a smaller lossy format, and
  the slice says so).
- **ffmpeg is used when needed.** When the source can't be written natively, the
  edit is done through ffmpeg.
- **Editors preview through a proxy.** When AVFoundation can't open the source
  (MKV, WebM, WMV, WMA, some AVI), the editor previews a temporary MP4/M4A proxy
  that ffmpeg makes in the background. The final edit is then applied to the
  original through ffmpeg.
- **Without ffmpeg,** these tools are hidden for those formats. The hub explains
  why.

### 6.5 Audio

Input: MP3, M4A, AAC, WAV, AIFF, FLAC, OGG, Opus, plus WMA (needs ffmpeg).

**Convert:**

- **Native:** M4A (AAC), AAC, WAV, AIFF, FLAC.
- **Needs ffmpeg:** MP3, OGG, Opus, WMA.

Conversions preserve channel layout and sample rate unless a tool changes them.

**Tools:**

| Tool | What it does |
|---|---|
| **Compress** | Bitrate sub-ring: 256, 192, 128, 96 kbps, plus "Smaller" (a sensible VBR). Keeps channel mapping. Kevo's "bitrate optimization." |
| **Trim** | Editor with waveform, start/end handles and preview. |
| **Normalize** | Adjusts loudness to a standard target. |
| **Bleep** | Editor: mark ranges on the waveform, which are replaced with a beep tone. |
| **Channels** | Sub-ring: Stereo→Mono, Mono→Stereo, Swap L/R. |
| **Metadata** | Sub-ring: Strip all, or View & edit (title, artist, album, artwork). |

### 6.6 Documents

The "needs Pages / Keynote / Numbers" outputs are produced by scripting those
Apple apps. Those slices appear only if the app is installed. On Kevo's Mac they
are the 2026 "Creator Studio" editions, with bundle IDs `com.apple.Pages`,
`com.apple.Keynote` and `com.apple.Numbers`. Older installs use
`com.apple.iWork.*`, so detection must check both. Expect a one-time macOS
Automation prompt per app.

**PDF**

- **Convert:**
  - JPG and PNG: one image per page, 300 DPI by default.
  - TXT and MD: text extraction.
  - DOCX and EPUB: text with basic structure, not layout-faithful.
  - PAGES: needs Pages.
  - PPTX: one slide per page image.
  - XLSX: best-effort, text lines into rows.

  The lower-fidelity outputs are labeled honestly in their slice subtitle or
  result toast.
- **Tools:**
  - **Compress / Flatten:** downsample embedded images, with tiers and a "Fit
    under…" option.
  - **Merge:** several PDFs into one.
  - **Split:** editor with page ranges, or "every page".
  - **Organize:** page-grid editor to reorder, rotate and delete pages.
  - **Redact:** editor to select text or draw boxes. Every page with a redaction
    is rasterized, so the underlying text is truly gone; other pages stay as
    text.
  - **Metadata:** strip all.

**Word-processing:** DOCX, DOC, PAGES, RTF, RTFD, TXT, MD, HTML, and text
clippings as input.

- Convert to PDF, DOCX, TXT, MD, HTML and EPUB.
- PAGES output needs Pages.
- When Pages is installed, it is used for higher-fidelity DOCX/PAGES→PDF.

**Slides:** PPTX, PPT, KEY as input.

- Convert to PDF, JPG and PNG (one per slide), PPTX and KEY.
- All of these need Keynote.

**Spreadsheets:** XLSX, XLS, NUMBERS, ODS, CSV, TSV as input.

- Convert to XLSX, CSV, TSV, PDF, NUMBERS and ODS.
- CSV↔TSV and CSV/TSV→XLSX/ODS are pure Swift.
- Anything reading XLSX, XLS or NUMBERS, and the PDF output, needs Numbers.

**Subtitles:** SRT, VTT as input. Convert to SRT, VTT and TXT, all pure Swift.

### 6.7 Archives

- **Folders, loose files and mixed selections:** Convert makes ZIP, TAR or
  TAR.GZ. One archive for the whole selection, created in place. This is
  "Instant Packing."
- **ZIP, TAR, GZ/TGZ and RAR:**
  - **Extract** (Tools wheel) unpacks to a folder beside the archive, without
    opening Archive Utility.
  - Convert repacks to the other formats.
  - RAR is input only.
- macOS's built-in `ditto` (ZIP, keeps macOS metadata) and `/usr/bin/tar`
  (libarchive 3.7, reads RAR) cover all of this. No extra install is needed.

### 6.8 Actions wheel (any file, folder or mix; Control)

| Action | What it does |
|---|---|
| **Float** | Spawns a small, semi-translucent thumbnail panel. It stays above all apps, on every Space, over full-screen apps, and is not swept away by Mission Control. You can drag it out later as the original file(s), so you don't have to hold a drag while switching Spaces. Several floats stack. Each has a close button; hover shows the name, and click opens Quick Look. |
| **AirDrop** | Opens macOS's AirDrop device picker directly (the system AirDrop sharing service), not the full Share sheet. |
| **Copy Path** | Copies POSIX paths, one per line for several files. A sub-ring offers **POSIX** and **URI** (`file://…`). |
| **Terminal** | Opens the terminal chosen in Settings at the folder: the item itself if it's a folder, otherwise the folder containing it. Auto-detects installed Terminal, iTerm (installed on Kevo's Mac), Ghostty and Warp. Defaults to Terminal. |
| **Copy to** | Sub-ring of favourite folders from Settings, plus **Choose…**. Copies there. |
| **Move to** | Same as Copy to, but moves. This is the only action allowed to relocate the original, because that is its explicit purpose. Name collisions are never overwritten. Undo moves the file back to where it was. |
| **Archive** | Sub-ring: **ZIP**, **TAR**, **TAR.GZ**. Packs the whole selection into one archive beside the first item, for any file type. *(My call. It lets you zip a handful of photos without crowding every Convert wheel.)* |

Actions work on any file type.

### 6.9 Menu bar and Settings

**Menu bar menu:**

- **Enabled** toggle
- **Open Files…** (keyboard path, §6.1)
- **Recent results** (the last 10, click to reveal)
- **Settings…**
- **About**
- **Quit**

**Settings window:**

- **Triggers:** record the key combination for each wheel.
- **Output:** toggle for revealing in Finder; quality defaults for JPEG, HEIC,
  WebP and AVIF; DPI for PDF→image; presets for compression and "fit under"
  sizes.
- **Copy/Move:** favourite folders. The defaults are Desktop, Documents and
  Downloads.
- **Terminal:** which terminal app to use.
- **Helpers:** status of ffmpeg (auto-detected in `/opt/homebrew/bin`, then
  `/usr/local/bin`, then a custom path) and of Pages, Keynote and Numbers. Each
  has a one-line "how to get it."
- **General:** launch at login, haptics on/off.

## 7. Constraints

- **Language and frameworks:** Swift, native.
  - AppKit for the overlay, event and window plumbing.
  - SwiftUI where it fits (wheel content, editors, Settings).
  - Apple frameworks for processing: ImageIO, Core Image, Vision, AVFoundation,
    VideoToolbox, AudioToolbox, PDFKit, QuickLookThumbnailing.
- **Minimum macOS 14 (Sonoma).** Liquid Glass on macOS 26, frosted fallback on
  14–15. The build is a universal binary *(my call)*.
- **Not sandboxed, not on the App Store.** Built from source with Xcode
  command-line tools. An ad-hoc-signed `.app` is fine for Kevo's use.
- **Open source on GitHub.** MIT license *(my call, matches DragShift)*.
  - README with build steps, the optional `brew install ffmpeg`, and the
    iWork-app note.
  - Neither ffmpeg nor any GPL component is bundled or linked. Orbit runs the
    user's ffmpeg as a separate process.
- **WebP output:** Apple's ImageIO reads WebP but cannot write it, and Kevo's
  Homebrew ffmpeg has no libwebp encoder. WebP output therefore comes from
  **libwebp bundled into Orbit** (BSD licence, fine for MIT), so it works with no
  extra install. *(My call.)*
- **Format sources** (checked on Kevo's machine, macOS 26.5):

  | Format | Native support | Source when not native |
  |---|---|---|
  | AVIF | ImageIO writes it | — |
  | ICO, BMP, GIF, HEIC, TIFF, PDF | ImageIO writes them | — |
  | SVG | NSImage reads it | — |
  | FLAC, Opus, ALAC, AAC | AudioToolbox encodes them | — |
  | AVI, OGG, FLAC, MP3 | AVFoundation reads them | — |
  | MKV, WebM | AVFoundation can't read them | ffmpeg |
  | MKV, WebM, AVI, WMV, MP3, OGG | AVFoundation can't write these containers | ffmpeg |
  | MP3 encoding | Apple has no encoder | ffmpeg (libmp3lame) |
  | WebP encoding | not native | bundled libwebp |
  | DOCX | NSAttributedString reads and writes it | — |

  Kevo's ffmpeg has libmp3lame, libopus, libvpx, wmv2/wmav2 and the
  VideoToolbox H.264/HEVC encoders. It has no libvorbis, so OGG output should use
  Opus or ffmpeg's built-in Vorbis encoder.
- **When a helper is missing,** its slices are hidden. A file whose type can
  only be read by a missing helper shows a hub message such as "Install ffmpeg
  to convert MKV" instead of an empty wheel.
- **Kevo's machine:**
  - Apple silicon, macOS 26.5, Xcode 26.6, Swift 6.3.
  - Homebrew ffmpeg and lame installed.
  - Pages, Keynote and Numbers (Creator Studio) installed.
  - iTerm installed.

## 8. How the trigger works: required behavior, mechanism left to the builder

Required:

- No Accessibility or Input Monitoring permission. This is a firm goal. If the
  first technical spike shows something in this spec can't be done without one,
  the builder stops and asks Kevo, rather than adding a permission or dropping
  the behavior. Triggers are modifier keys only, so recording them needs no
  permission either.
- No effect on dragging when no trigger key is pressed.
- The wheel must be ready to receive the drop the instant it appears.

Prior art: DragShift polls the global mouse-button and modifier state
(`NSEvent.pressedMouseButtons` / `NSEvent.modifierFlags`). Its code says that
needs no permission on macOS. It opens a non-activating overlay under the
pointer that is a drop target for file URLs. A common native way to confirm that
a *file* drag is in progress, and not a window drag, is the drag pasteboard
(`NSPasteboard(name: .drag)`) change count plus checking it for file URLs. The
builder should confirm these on macOS 26. Idle CPU must stay near zero.
Expensive polling may only run while the mouse button is held.

The overlay must be:

- a borderless, non-activating panel
- shown on all Spaces and over full-screen apps
- the drop target

The Float panels need the same "everywhere" behavior.

## 9. Testing and done

- **Processing engine:** separate from the UI, with automated tests for every
  conversion path and tool. Tests run on small fixture files and check the
  output, not just that a file exists: format, dimensions, duration, page count,
  that metadata is gone, that redacted text is not extractable, and that
  archives round-trip. Tests for paths that need ffmpeg or iWork are skipped
  when the helper isn't installed.
- **UI and trigger:** verified by actually dragging in Finder on Kevo's Mac.
  An automated drag test (synthetic mouse and key events, as DragShift does in
  CI) is a stretch goal, not required.
- **Done means:**
  - Every slice in §6 produces a correct output, or is hidden because its
    helper is missing.
  - The wheel opens without lag.
  - Normal Finder drags are unaffected.
  - The app builds from a clean clone with one documented command.

## 10. Left to the builder

- **Project layout.** Xcode project versus XcodeGen. A suggested split is an
  `OrbitCore` Swift package (engine, testable with `swift test`) plus the
  `Orbit` app target.
- **Trigger and drop mechanics** (§8).
- **Visuals:** exact geometry and colors, matched to the hero video.
- **Fine details:** editor UI layout, and preset values beyond those named here.
- **Writers:** how EPUB, XLSX, ODS and PPTX output are written (hand-built zip
  and XML is fine), and fidelity trade-offs within the honesty rule in §6.6.
- **Concurrency:** how many batch items run in parallel.
- **Logging:** a log file under `~/Library/Logs/Orbit/` is expected for
  debugging.

## Appendix A — Kevo's original feature list (source for §6)

Kevo's brief, lightly cleaned up. §6 is a superset of it: this list, plus
Tangerine's published features, plus the hero video's tools.

- **What it is:** a menu bar app (`LSUIElement`), with no permanent window and
  no Dock icon. It intercepts drags and modifier keys.
- **The gesture:** drag files in Finder, then:
  - hold Shift or ⌘ for the **Conversion Wheel** (target formats);
  - hold Shift+Option or ⌥⌘ for the **Tools Wheel** (edit, redact, compress);
  - tap Control for the **Actions Wheel** (Float, Move, AirDrop).

  Release on a slice. The file is processed locally and saved beside the source.
- **Dynamic radial HUD:** a circular glassmorphic HUD centered on the pointer.
  Its slices depend on the file type being dragged.
- **Dead zone and drop trigger:** an inner dead zone prevents accidental
  releases. Moving past the threshold highlights the chosen segment with spring
  physics.
- **File placement:** outputs go beside the source with non-destructive
  suffixes (for example `-converted.png`), and are immediately revealed in Finder.
- **Progress HUD:** for heavy batches or large video transcodes, a compact
  floating indicator near the cursor or menu bar. Subtle trackpad haptic
  feedback on completion.

**Images**

- **Inputs:** PNG, JPG/JPEG, HEIC, WebP, TIFF, SVG, ICO, BMP.
- **Outputs:** JPG, PNG, HEIC, WebP, TIFF, PDF.
- **Tools:**
  - Subject cutout / Remove BG: local Vision, transparent PNG.
  - EXIF stripping: GPS, camera info, device serials.
  - Markup / Annotate: crop, arrow, blackout, dimensions.
  - Percentage compression: adjustable tiers.
  - QR decoding: copies the text or URL.

**Video**

- **Inputs:** MP4, MOV, MKV, WebM, AVI.
- **Outputs:** MP4, MOV, MKV, GIF, MP3, M4A.
- **Tools:**
  - Size-target compression, using the Apple Silicon media engines, to fit
    messaging and email limits.
  - Audio stripping, to audio files.
  - Video-to-GIF.
  - Metadata scrub.

**Audio**

- **Inputs:** MP3, M4A, WAV, FLAC, AAC, OGG.
- **Outputs:** MP3, M4A, WAV, FLAC, AAC.
- **Tools:**
  - Transcoding, lossless ↔ lossy.
  - Bitrate optimization, preserving channel mapping.

**Documents and Office**

- **Inputs:** PDF, DOCX, PAGES, PPTX, KEYNOTE, XLSX, NUMBERS, CSV, TXT, MD.
- **Outputs:** PDF, DOCX, TXT, EPUB.
- **Tools:**
  - Image-to-PDF stitching: several images become an ordered multi-page PDF.
  - Document redaction.
  - PDF flattening and compression: downsample high-DPI images.

**Archives**

- **Inputs:** folders, loose file batches, ZIP, TAR, GZ.
- **Outputs:** ZIP, TAR, GZ.
- **Tools:**
  - Instant packing: in-place archive.
  - Quick extraction, without Archive Utility.

**Actions wheel (Control)**

- **Float (Quick Stash):** a small, semi-translucent thumbnail pinned above all
  apps, full-screen Spaces and Mission Control. No need to hold a drag while
  switching Spaces.
- **AirDrop:** straight to nearby devices, without the Share sheet.
- **Copy Path:** POSIX or URI.
- **Open in Terminal:** in the default terminal (Terminal, iTerm, Ghostty),
  `cd`'d to the file's directory.
- **Move / Copy:** fast routing to designated local folders.
