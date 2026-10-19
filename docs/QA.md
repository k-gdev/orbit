# Orbit QA checklist

Build under test: `/Applications/Orbit.app` installed by `scripts/build-app.sh && scripts/install.sh` from branch `feat/orbit-v1`. Universal binary (`lipo -archs`: `x86_64 arm64`), ad-hoc signed.

Two kinds of line below:

- **Automated** results come from a headless pass: the installed app run with `--perform <file> --wheel <convert|tools|actions> --slice <id>` against one small sample file per input category, the same code path as a real drop. `--list-slices <file> --wheel <wheel>` lists the slice ids for a file. Outputs landed beside the samples in a scratch folder, never in the repo. No agent could do real Finder drags or take screenshots, so everything that needs a pointer, a window you must look at, or an Apple app is **pending — Kevo**.
- **pending — Kevo** lines are things only a person at the Mac can confirm. Tick them off here.

## 1. Top priority: the permission-free trigger spike (pending — Kevo)

This decides whether the whole design (spec §8) works with no Accessibility or Input Monitoring permission. Do it before anything else.

1. Quit any running Orbit (menu bar icon, Quit). **Do not launch from iTerm**: iTerm has Input Monitoring, and a process started from it would inherit that grant and hide a missing-permission problem. Launch through LaunchServices instead, from Terminal.app, Spotlight, or another app that has no such grant:
   ```sh
   open -n /Applications/Orbit.app --args --diagnose-trigger
   ```
2. In Finder, press on a file and start dragging it. **Mid-drag**, press and hold ⌘. The wheel should appear under the pointer. Release ⌘ (the wheel stays), move over a petal, then onto the centre hub, and release the mouse over the hub. Quit Orbit from its menu bar icon.
3. Read the log:
   ```sh
   L=$(grep -n 'trigger diagnostics on' ~/Library/Logs/Orbit/orbit.log | tail -1 | cut -d: -f1)
   tail -n +$L ~/Library/Logs/Orbit/orbit.log | grep 'buttonDown=true' | head -60
   tail -n +$L ~/Library/Logs/Orbit/orbit.log | grep -E ' -> |drop: '
   ```
   **Pass** requires all of:
   - [ ] `buttonDown=true … changeCount=N dragHasFiles=false` lines, then `changeCount=N+1 dragHasFiles=true` once the drag starts (the count changes after the first `buttonDown=true` line).
   - [ ] `modifiers=[command]` while ⌘ is held, and a line ending `-> open convert at (x, y)`.
   - [ ] `drop: draggingEntered -> copy` (or `-> generic` if ⌘ was still held) when the pointer is over the wheel.
   - [ ] `-> close` on release, plus `drop: draggingEnded without a drop` if you released over the hub.
   - [ ] No permission dialog appeared. Optional evidence while Orbit is still running:
     ```sh
     pid=$(pgrep -f Orbit.app/Contents/MacOS/Orbit)
     /usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.apple.TCC"' | grep "msgID=$pid\." | grep -E 'AUTHREQ_CTX|AUTHREQ_RESULT'
     ```
     Expect only `service=kTCCServiceListenEvent, preflight=yes` (a silent check every AppKit process makes) and no `preflight=no`.
4. **Release without moving.** Drag, press ⌘ to open the wheel, then release the mouse without moving the pointer. The log must show `drop: draggingEntered` before the release `-> close`. [ ]
5. **Drop past the wheel.** Open the wheel, move about 300 pt from its centre, and drop on a Finder folder there. Finder does its normal move (the file ends up in that folder). In the diagnose log you should see `drop: panel lets drags through at r=…` once you cross 230 pt (322 pt with a sub-ring open). [ ]

**Stop and report, with the log excerpt, if:** `buttonDown` stays false during the drag; the change count never moves or `dragHasFiles` stays false; `modifiers` stays `[]` while ⌘ is held; a permission prompt appears; or there is no `draggingEntered` line. Do not add a permission.

## 2. Other pending — Kevo items

### 2.1 iWork (first item: this pops a macOS Automation dialog on screen, so it was not run headlessly)

- [ ] **`ORBIT_IWORK_TESTS=1 swift test --filter "Document|Office"`**: approve the Pages, Keynote and Numbers Automation prompts when macOS asks. Expect PASS (4 tests are skipped without the variable: `toPages`, `viaPages`, `keynoteAndNumbers`, and a second `toPages`).
- [ ] Pages: drag `sample.pdf` to Convert → PAGES; drag `sample.docx` to Convert → PAGES and → PDF. Output lands beside the source and opens in Pages.
- [ ] Real DOCX with tables and images → PDF, MD, HTML, EPUB looks right. A real text clipping (`.textClipping`) converts.
- [ ] Keynote: a real `.pptx` → PNG and JPG (one image per slide), PDF, KEY. PDF → PPTX opens in Keynote.
- [ ] Numbers: `.xlsx` and `.numbers` → CSV, PDF; `sample.csv` → NUMBERS.
- [ ] Without Pages/Keynote/Numbers installed the corresponding slices do not appear (optional: rename an app temporarily).

### 2.2 Wheel and overlay (Tasks 9, 11)

- [ ] Wheel look on macOS 26: Liquid Glass renders inside the hosting container; petals, hub thumbnail and pill look right.
- [ ] macOS 14/15 (if you have a machine): the `.ultraThinMaterial` frosted fallback looks acceptable.
- [ ] Haptic tick when the highlight changes; first-show spring (scale 0.85 → 1); inactive-panel material rendering.
- [ ] **(a)** Drag a `.mov`, press ⌘ after the drag started: wheel appears under the pointer (about 3 frames of settle). Release ⌘: it stays.
- [ ] **(b)** Add ⌥ (⌥⌘): switches to Tools in place. Tap Control: Actions. Rebinding is covered in 2.4.
- [ ] **(c)** Drop on the hub: nothing happens, Finder slides the drag image back, the file is unchanged.
- [ ] **(d)** Drop on a leaf slice twice: once with ⌘ still held, once after releasing it. Both run the job.
- [ ] **(e)** Shift-click to extend a Finder selection, then drag while holding Shift: no wheel until you release and press again.
- [ ] **(f)** Drag a Finder window by its title bar with ⌘ held: no wheel.
- [ ] **(g)** Esc mid-drag with the pointer over the wheel: the drag cancels and the wheel disappears. (Known limit: with the pointer off the wheel, it stays until you release the button.)
- [ ] **(h)** Drag past the wheel's 644 pt square and drop in another Finder folder: Finder does its normal move. Repeat about 300 pt from the centre.
- [ ] **(i)** Activity Monitor shows Orbit at about 0% CPU while idle (measured 0.08%).
- [ ] Control → Actions drop works (the source mask becomes `.link`); Enabled toggled off gives no wheel; a secondary display (including one left of or above the main display) keeps the wheel fully on screen.
- [ ] A transparent-margin drop (inside the panel square but past the wheel) reaches the Finder item beneath.
- [ ] macOS 26 "paste from other apps" style alert does not appear when the wheel opens.
- [ ] Debug wheel: menu bar → Debug → Show Wheel is interactive (hover, click, Tab, Esc).

### 2.3 Progress, toasts, menu bar (Tasks 1, 10, 28b)

- [ ] Menu bar icon: ringed-planet glyph is crisp in light and dark menu bars; the ring is dashed while a job runs.
- [ ] A job longer than half a second shows the progress panel (action, file name, bar, `n of m`, × to cancel). Cancelling removes partial output.
- [ ] Result toast: **Open**, **Show in Finder**, **Undo** (moves new files to the Trash); hover pauses the 6 s dismiss; × dismisses; several toasts stack and stay on screen.
- [ ] Debug → Show Wheel → COPY PATH on an unreadable file shows an error toast.
- [ ] Recent results: lists the last 10, click reveals in Finder; clipboard-only results re-copy.
- [ ] Enabled checkmark toggles. Choose… opens an NSOpenPanel; the chosen folder works as the Copy/Move destination.
- [ ] Haptic when a job finishes (trackpad).

### 2.4 Settings (Task 12, 28b)

- [ ] Record `⌃⌥` for Tools; drag with ⌃⌥ opens Tools; quit and relaunch: the binding persisted.
- [ ] Launch at login toggle (an error message is shown if the app runs from a build folder); it appears in System Settings → General → Login Items.
- [ ] Accent colour: pick a colour, the wheel highlight and editor controls follow immediately; **Reset to default** returns to `#80649C`; an invalid hex is rejected.
- [ ] Reveal in Finder toggle, DPI slider, compression presets, favourite folders add/remove, Terminal picker, Helpers status: look and behave as labelled.

### 2.5 Keyboard path and Services (Task 13)

- [ ] Right-click a PNG → Quick Actions (or Services) → **Orbit…**: the wheel opens at the pointer; → → Return converts. If "Orbit…" is missing, enable it in System Settings → Keyboard → Keyboard Shortcuts → Services.
- [ ] Menu bar → **Open Files…** → pick two PDFs → press ⌥ (Tools) → MERGE.
- [ ] The wheel window receives keys: arrows move the highlight, Return applies, Esc closes (and leaves a sub-ring first), ⌘/⌥/⌃ switch wheels, hover and click work.

### 2.6 Actions that need a person (Task 25)

- [ ] **Float**: panel stays above apps across Spaces and over full-screen apps; hover shows name, × and raised alpha; click opens Quick Look; drag it into Mail attaches the file and closes the float; several floats stack 8 pt apart.
- [ ] **AirDrop** opens the AirDrop device picker, not the full Share sheet.
- [ ] **Terminal** opens iTerm (or your chosen terminal) at the folder; falls back to Terminal.app.
- [ ] **Copy Path → URI** puts a `file://` URL on the real clipboard (paste into TextEdit to confirm); POSIX puts plain paths, one per line for several files.
- [ ] **Move to** then **Undo** moves the file back; a name collision never overwrites.

### 2.7 Image editors and tools (Tasks 14–16, 26)

- [ ] Markup: crop (free and fixed ratios), resize, arrow (head), box, text, marker, numbered steps, blackout (burned in); undo/redo; Return in a text field; drag the header; Esc and ×. Multi-image selection re-opens the editor per image.
- [ ] Adjust: auto-enhance, exposure, contrast, saturation, warmth direction (warmer = warmer), B&W, rotate/flip, hold-to-compare.
- [ ] Add BG on a real portrait photo (after Remove BG): solid, gradient and blur backdrops; colour picker appears above the panel; resize fields.
- [ ] Remove BG on a real photo of a person or object gives a clean transparent PNG.
- [ ] Remove location on a real iPhone photo: Finder → Get Info → More Info shows no GPS.
- [ ] Read QR on a real screenshot of a QR code; a URL result offers **Open**.

### 2.8 Video and audio editors (Tasks 17–19, 27)

- [ ] Trim, Split (points and N equal parts), Snapshot (full-resolution PNG), Crop (ratio presets, sliders, live pixel size) on a real MP4/MOV; the preview matches the result.
- [ ] Same on an MKV: the editor previews through a proxy; trim/split of a sparse-keyframe MKV lands where expected.
- [ ] Compress, Crop, 4× speed on a real iPhone HEVC/HDR clip; join, crop and speed keep audio in sync in QuickTime.
- [ ] Audio: listen to a Normalized, a Bleeped and a Trimmed file in Music or QuickTime. Confirm cover art added in the metadata editor shows in Music and Finder for an MP3 and an M4A.
- [ ] Waveform editor: handles, marks, bleep ranges, playback preview.

### 2.9 Documents and PDF editors (Tasks 20–23, 28)

- [ ] Open generated `.xlsx`, `.pptx`, `.ods`, `.epub` in Excel/Numbers, PowerPoint/Keynote, LibreOffice and Books: no repair prompt.
- [ ] PDF → PPTX opens in Keynote; PDF → XLSX of a real table PDF puts columns where expected.
- [ ] Redact: select text and draw boxes live; the redacted PDF's text is truly gone (select-all and copy shows nothing for those lines; the page is flattened). Looks right.
- [ ] Organize: drag to reorder, rotate, delete pages. Split: choose page ranges. Metadata editor (images/audio/PDF): edit fields, map link opens Apple Maps, remove location. Custom compress panel.

### 2.10 Archives (Task 24)

- [ ] Extract a real `.rar` (tar/libarchive reads it); no RAR file was available headlessly.
- [ ] Real-drag Archive and Extract slices on a folder of photos and on a ZIP/TGZ.

### 2.11 Distribution

- [ ] On a second Mac (or after clearing quarantine with a download), the ad-hoc-signed app opens via right-click → Open.
- [ ] Intel (x86_64) run if a machine is available: the universal binary was only verified with `lipo`.

## 3. Review Focus items

| # | Focus | Evidence |
|---|---|---|
| 1 | Unsafe filenames (spaces, quotes, `ü`, leading `-`) | Unit tests (Tasks 5, 24). Headless: `-rf 'q" ü.mov` → MP4 and WebM (ffmpeg), ZIP archive; `-x 'y" ü.srt` → VTT: all PASS, names preserved, nothing treated as an option. |
| 2 | Package directories (`.rtfd`, `.app`, `.pages`…) are documents, not folders | Unit test (Task 2). Headless: `note.rtfd` lists the document Convert slices and → PDF PASS. |
| 3 | Wrong or missing extensions | Unit test (Task 2). Headless: a PNG saved as `photo.jpg` is offered JPG but not PNG, and converts to WebP (`photo-converted.webp`). |
| 4 | One bad file in a batch | Unit test (Task 8). Headless: `good.png` + a corrupt `corrupt.png` with Compress → `1 of 2 done · 1 failed`, `good-compressed.jpg` written, no partial file for the bad one. |
| 5 | Wheel at a screen edge / secondary display | Unit test (Task 7). Real screen-edge and second-display drag: pending — Kevo (section 2.2). |

## 4. Automated results (headless, installed app)

Sample files (generated with ffmpeg, ImageIO, CoreGraphics, `sips`, `textutil`, `zip`): PNG, JPG with GPS and camera EXIF, HEIC, SVG, MOV, MKV, WAV, MP3, a 3-page text PDF, DOCX, CSV, SRT, ZIP, a folder, plus a large noisy JPG, a 10 s MOV, an image-only PDF and a QR code PNG for the tier/fit and QR slices. Source files were hashed before and after: **no source file changed**. Spot checks of the outputs beyond "file exists": Strip all and Strip location both removed the GPS block from the JPG (read back with ImageIO); Normalize/Mono kept a valid 3 s WAV; MP4 convert kept video and audio; Mute left no audio stream; 4× speed gave 0.75 s from 3 s; PDF → TXT/MD returned the page text; SRT → VTT is valid WebVTT; CSV → XLSX is a well-formed 5-part package; ZIP extract produced the inner file.

**Tally.** 520 slice runs across 18 samples: **326 PASS, 28 REFUSED (expected), 0 FAIL, 166 SKIP** (54 UI-only: Float/AirDrop/Terminal; 4 iWork; 108 Copy to/Move to, of which 2 were run once separately and PASS). Plus 13 multi-file runs, all PASS. The 28 refusals are accurate plain-language errors for samples that cannot satisfy the slice, not defects:

- Compress tiers on tiny files (a 2 KB PNG or 46 KB clip cannot shrink to 25–75% of itself); the same slices PASS on `big-photo.jpg`, `big.mov` and `big-scan.pdf`.
- Read QR on pictures without a QR code ("No QR code found."); it PASSes on `qr.png` and copies the URL.
- Remove BG on `big-photo.jpg` (noise) and `qr.png` ("Couldn't find a subject in this image.").
- PDF text outputs from the image-only `big-scan.pdf` ("This PDF has no text to extract. It may be scanned pages.").
- `big-scan.pdf` Fit under 1 MB (the noisy page cannot get that small).

Editor slices (Add BG, Markup, Adjust, Custom compress, metadata View & edit, Trim, Crop, Split, Snapshot, Bleep, PDF Split/Organize/Redact, Choose…) open windows, so they are covered by section 5 and by the pending lines above. iWork-dependent slices (`convert.pages`, `convert.numbers`, anything using Keynote) are in section 2.1.

### Per-slice results

Legend: **PASS** = exit 0 and the output file(s) named in the last column were written beside the sample. **REFUSED (expected)** = Orbit declined with an accurate plain-language error because the sample cannot satisfy the slice (see the Note column); the same slice PASSES on a suitable sample elsewhere in this table. **SKIP** = not run headlessly (listed under "Pending — Kevo"). Collision suffixes (`-2`, `-3`) appear because every slice of a category ran against the same sample file.

#### Image: PNG (`sample.png`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.jpg` | PASS | sample-converted.jpg | 2 KB → 13 KB · 641% larger |
| `convert.heic` | PASS | sample-converted.heic | 2 KB → 4 KB · 115% larger |
| `convert.webp` | PASS | sample-converted.webp | 2 KB → 3 KB · 92% larger |
| `convert.tiff` | PASS | sample-converted.tiff | 2 KB → 234 KB · 13145% larger |
| `convert.avif` | PASS | sample-converted.avif | 2 KB → 2 KB · 24% larger |
| `convert.bmp` | PASS | sample-converted.bmp | 2 KB → 230 KB · 12957% larger |
| `convert.gif` | PASS | sample-converted.gif | 2 KB → 9 KB · 416% larger |
| `convert.ico` | PASS | sample-converted.ico | 320×240 → 256×192 |
| `convert.pdf` | PASS | sample-converted.pdf | 2 KB → 11 KB · 526% larger |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.removeBackground` | PASS | sample-nobg.png | Saved 1 file |
| `tools.compress.light` | REFUSED (expected) |  | Can't get this image under 1323 bytes. |
| `tools.compress.medium` | REFUSED (expected) |  | Can't get this image under 882 bytes. |
| `tools.compress.strong` | REFUSED (expected) |  | Can't get this image under 441 bytes. |
| `tools.compress.fit.500000` | PASS | sample-compressed.jpg | 2 KB → 14 KB · 694% larger |
| `tools.compress.fit.1000000` | PASS | sample-compressed-2.jpg | 2 KB → 14 KB · 694% larger |
| `tools.compress.fit.5000000` | PASS | sample-compressed-3.jpg | 2 KB → 14 KB · 694% larger |
| `tools.metadata.stripAll` | PASS | sample-clean.png | Saved 1 file |
| `tools.metadata.stripLocation` | PASS | sample-clean-2.png | Saved 1 file |
| `tools.readQR` | REFUSED (expected) |  | No QR code found. |

#### Image: JPG with GPS (`sample.jpg`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.png` | PASS | sample-converted.png | 12 KB → 31 KB · 161% larger |
| `convert.heic` | PASS | sample-converted-2.heic | 12 KB → 5 KB · 58% smaller |
| `convert.webp` | PASS | sample-converted-2.webp | 12 KB → 3 KB · 71% smaller |
| `convert.tiff` | PASS | sample-converted-2.tiff | 12 KB → 234 KB · 1889% larger |
| `convert.avif` | PASS | sample-converted-2.avif | 12 KB → 3 KB · 77% smaller |
| `convert.bmp` | PASS | sample-converted-2.bmp | 12 KB → 230 KB · 1859% larger |
| `convert.gif` | PASS | sample-converted-2.gif | 12 KB → 11 KB · 5% smaller |
| `convert.ico` | PASS | sample-converted-2.ico | 320×240 → 256×192 |
| `convert.pdf` | PASS | sample-converted-2.pdf | 12 KB → 38 KB · 224% larger |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.removeBackground` | PASS | sample-nobg-2.png | Saved 1 file |
| `tools.compress.light` | PASS | sample-compressed-4.jpg | 12 KB → 9 KB · 25% smaller |
| `tools.compress.medium` | PASS | sample-compressed-5.jpg | 12 KB → 6 KB · 51% smaller |
| `tools.compress.strong` | PASS | sample-compressed-6.jpg | 12 KB → 3 KB · 78% smaller |
| `tools.compress.fit.500000` | PASS | sample-compressed-7.jpg | 12 KB → 15 KB · 28% larger |
| `tools.compress.fit.1000000` | PASS | sample-compressed-8.jpg | 12 KB → 15 KB · 28% larger |
| `tools.compress.fit.5000000` | PASS | sample-compressed-9.jpg | 12 KB → 15 KB · 28% larger |
| `tools.metadata.stripAll` | PASS | sample-clean.jpg | Saved 1 file |
| `tools.metadata.stripLocation` | PASS | sample-clean-2.jpg | Saved 1 file |
| `tools.readQR` | REFUSED (expected) |  | No QR code found. |

#### Image: HEIC (`sample.heic`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.jpg` | PASS | sample-converted-2.jpg | 4 KB → 15 KB · 297% larger |
| `convert.png` | PASS | sample-converted-2.png | 4 KB → 24 KB · 541% larger |
| `convert.webp` | PASS | sample-converted-3.webp | 4 KB → 4 KB · 5% smaller |
| `convert.tiff` | PASS | sample-converted-3.tiff | 4 KB → 311 KB · 8285% larger |
| `convert.avif` | PASS | sample-converted-3.avif | 4 KB → 2 KB · 38% smaller |
| `convert.bmp` | PASS | sample-converted-3.bmp | 4 KB → 230 KB · 6122% larger |
| `convert.gif` | PASS | sample-converted-3.gif | 4 KB → 10 KB · 179% larger |
| `convert.ico` | PASS | sample-converted-3.ico | 320×240 → 256×192 |
| `convert.pdf` | PASS | sample-converted-3.pdf | 4 KB → 31 KB · 735% larger |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.removeBackground` | PASS | sample-nobg-3.png | Saved 1 file |
| `tools.compress.light` | PASS | sample-compressed.heic | 4 KB → 3 KB · 26% smaller |
| `tools.compress.medium` | PASS | sample-compressed-2.heic | 4 KB → 2 KB · 52% smaller |
| `tools.compress.strong` | REFUSED (expected) |  | Can't get this image under 926 bytes. |
| `tools.compress.fit.500000` | PASS | sample-compressed-3.heic | 4 KB → 7 KB · 82% larger |
| `tools.compress.fit.1000000` | PASS | sample-compressed-4.heic | 4 KB → 7 KB · 82% larger |
| `tools.compress.fit.5000000` | PASS | sample-compressed-5.heic | 4 KB → 7 KB · 82% larger |
| `tools.metadata.stripAll` | PASS | sample-clean.heic | Saved 1 file |
| `tools.metadata.stripLocation` | PASS | sample-clean-2.heic | Saved 1 file |
| `tools.readQR` | REFUSED (expected) |  | No QR code found. |

#### Image: SVG (`sample.svg`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.jpg` | PASS | sample-converted-3.jpg | 187 bytes → 20 KB · 10379% larger |
| `convert.png` | PASS | sample-converted-3.png | 187 bytes → 24 KB · 12710% larger |
| `convert.heic` | PASS | sample-converted-3.heic | 187 bytes → 7 KB · 3467% larger |
| `convert.webp` | PASS | sample-converted-4.webp | 187 bytes → 4 KB · 1915% larger |
| `convert.tiff` | PASS | sample-converted-4.tiff | 187 bytes → 2.5 MB · 1346059% larger |
| `convert.avif` | PASS | sample-converted-4.avif | 187 bytes → 5 KB · 2682% larger |
| `convert.bmp` | PASS | sample-converted-4.bmp | 187 bytes → 1.9 MB · 1008596% larger |
| `convert.gif` | PASS | sample-converted-4.gif | 187 bytes → 4 KB · 2303% larger |
| `convert.ico` | PASS | sample-converted-4.ico | 1024×614 → 256×154 |
| `convert.pdf` | PASS | sample-converted-4.pdf | 187 bytes → 18 KB · 9629% larger |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.removeBackground` | PASS | sample-nobg-4.png | Saved 1 file |
| `tools.compress.light` | REFUSED (expected) |  | Can't get this image under 140 bytes. |
| `tools.compress.medium` | REFUSED (expected) |  | Can't get this image under 93 bytes. |
| `tools.compress.strong` | REFUSED (expected) |  | Can't get this image under 46 bytes. |
| `tools.compress.fit.500000` | PASS | sample-compressed.png | 187 bytes → 24 KB · 12710% larger |
| `tools.compress.fit.1000000` | PASS | sample-compressed-2.png | 187 bytes → 24 KB · 12710% larger |
| `tools.compress.fit.5000000` | PASS | sample-compressed-3.png | 187 bytes → 24 KB · 12710% larger |
| `tools.readQR` | REFUSED (expected) |  | No QR code found. |

#### Image: large noisy JPG (tier/fit realism) (`big-photo.jpg`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.png` | PASS | big-photo-converted.png | 2.9 MB → 9.6 MB · 232% larger |
| `convert.heic` | PASS | big-photo-converted.heic | 2.9 MB → 2.3 MB · 21% smaller |
| `convert.webp` | PASS | big-photo-converted.webp | 2.9 MB → 1.5 MB · 47% smaller |
| `convert.tiff` | PASS | big-photo-converted.tiff | 2.9 MB → 11.5 MB · 298% larger |
| `convert.avif` | PASS | big-photo-converted.avif | 2.9 MB → 1.8 MB · 37% smaller |
| `convert.bmp` | PASS | big-photo-converted.bmp | 2.9 MB → 11.5 MB · 298% larger |
| `convert.gif` | PASS | big-photo-converted.gif | 2.9 MB → 3.7 MB · 28% larger |
| `convert.ico` | PASS | big-photo-converted.ico | 2400×1600 → 256×171 |
| `convert.pdf` | PASS | big-photo-converted.pdf | 2.9 MB → 8.9 MB · 208% larger |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.removeBackground` | REFUSED (expected) |  | Couldn't find a subject in this image. |
| `tools.compress.light` | PASS | big-photo-compressed.jpg | 2.9 MB → 2.2 MB · 25% smaller |
| `tools.compress.medium` | PASS | big-photo-compressed-2.jpg | 2.9 MB → 1.4 MB · 50% smaller |
| `tools.compress.strong` | PASS | big-photo-compressed-3.jpg | 2.9 MB → 724 KB · 75% smaller |
| `tools.compress.fit.500000` | PASS | big-photo-compressed-4.jpg | 2.9 MB → 498 KB · 83% smaller |
| `tools.compress.fit.1000000` | PASS | big-photo-compressed-5.jpg | 2.9 MB → 1 MB · 65% smaller |
| `tools.compress.fit.5000000` | PASS | big-photo-compressed-6.jpg | 2.9 MB → 3.2 MB · 10% larger |
| `tools.metadata.stripAll` | PASS | big-photo-clean.jpg | Saved 1 file |
| `tools.metadata.stripLocation` | PASS | big-photo-clean-2.jpg | Saved 1 file |
| `tools.readQR` | REFUSED (expected) |  | No QR code found. |

#### Image: QR code PNG (`qr.png`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.jpg` | PASS | qr-converted.jpg | 3 KB → 22 KB · 608% larger |
| `convert.heic` | PASS | qr-converted.heic | 3 KB → 4 KB · 30% larger |
| `convert.webp` | PASS | qr-converted.webp | 3 KB → 2 KB · 37% smaller |
| `convert.tiff` | PASS | qr-converted.tiff | 3 KB → 295 KB · 9293% larger |
| `convert.avif` | PASS | qr-converted.avif | 3 KB → 1 KB · 62% smaller |
| `convert.bmp` | PASS | qr-converted.bmp | 3 KB → 219 KB · 6882% larger |
| `convert.gif` | PASS | qr-converted.gif | 3 KB → 3 KB · 1% smaller |
| `convert.ico` | PASS | qr-converted.ico | 270×270 → 256×256 |
| `convert.pdf` | PASS | qr-converted.pdf | 3 KB → 10 KB · 211% larger |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.removeBackground` | REFUSED (expected) |  | Couldn't find a subject in this image. |
| `tools.compress.light` | PASS | qr-compressed.png | 3 KB → 2 KB · 36% smaller |
| `tools.compress.medium` | REFUSED (expected) |  | Can't get this image under 1570 bytes. |
| `tools.compress.strong` | REFUSED (expected) |  | Can't get this image under 785 bytes. |
| `tools.compress.fit.500000` | PASS | qr-compressed-2.png | 3 KB → 3 KB · 1% larger |
| `tools.compress.fit.1000000` | PASS | qr-compressed-3.png | 3 KB → 3 KB · 1% larger |
| `tools.compress.fit.5000000` | PASS | qr-compressed-4.png | 3 KB → 3 KB · 1% larger |
| `tools.metadata.stripAll` | PASS | qr-clean.png | Saved 1 file |
| `tools.metadata.stripLocation` | PASS | qr-clean-2.png | Saved 1 file |
| `tools.readQR` | PASS |  | Copied: https://example.com/orbit |

#### Video: MOV (H.264 + AAC, 3 s) (`sample.mov`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.mp4` | PASS | sample-converted.mp4 | Saved 1 file |
| `convert.mkv` | PASS | sample-converted.mkv | Saved 1 file |
| `convert.webm` | PASS | sample-converted.webm | Saved 1 file |
| `convert.avi` | PASS | sample-converted.avi | Saved 1 file |
| `convert.wmv` | PASS | sample-converted.wmv | Saved 1 file |
| `convert.gif` | PASS | sample-converted-5.gif | Saved 1 file |
| `convert.m4a` | PASS | sample-converted.m4a | Saved 1 file |
| `convert.mp3` | PASS | sample-converted.mp3 | Saved 1 file |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.compress.fit.10000000` | PASS | sample-compressed.mov | 46 KB → 313 KB · 585% larger |
| `tools.compress.fit.25000000` | PASS | sample-compressed-2.mov | 46 KB → 313 KB · 585% larger |
| `tools.compress.fit.50000000` | PASS | sample-compressed-3.mov | 46 KB → 313 KB · 585% larger |
| `tools.compress.fit.100000000` | PASS | sample-compressed-4.mov | 46 KB → 313 KB · 585% larger |
| `tools.compress.light` | REFUSED (expected) |  | Can't fit this video under 34 KB. |
| `tools.compress.medium` | REFUSED (expected) |  | Can't fit this video under 23 KB. |
| `tools.compress.strong` | REFUSED (expected) |  | Can't fit this video under 11 KB. |
| `tools.speed.0.25` | PASS | sample-0.25x.mov | Saved 1 file |
| `tools.speed.0.5` | PASS | sample-0.5x.mov | Saved 1 file |
| `tools.speed.1.5` | PASS | sample-1.5x.mov | Saved 1 file |
| `tools.speed.2.0` | PASS | sample-2x.mov | Saved 1 file |
| `tools.speed.4.0` | PASS | sample-4x.mov | Saved 1 file |
| `tools.mute` | PASS | sample-muted.mov | Saved 1 file |
| `tools.removeMetadata` | PASS | sample-clean.mov | Saved 1 file |

#### Video: MKV (needs ffmpeg), 3 s (`sample.mkv`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.mp4` | PASS | sample-converted-2.mp4 | Saved 1 file |
| `convert.mov` | PASS | sample-converted.mov | Saved 1 file |
| `convert.webm` | PASS | sample-converted-2.webm | Saved 1 file |
| `convert.avi` | PASS | sample-converted-2.avi | Saved 1 file |
| `convert.wmv` | PASS | sample-converted-2.wmv | Saved 1 file |
| `convert.gif` | PASS | sample-converted-6.gif | Saved 1 file |
| `convert.m4a` | PASS | sample-converted-2.m4a | Saved 1 file |
| `convert.mp3` | PASS | sample-converted-2.mp3 | Saved 1 file |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.compress.fit.10000000` | PASS | sample-compressed.mkv | 44 KB → 354 KB · 705% larger |
| `tools.compress.fit.25000000` | PASS | sample-compressed-2.mkv | 44 KB → 353 KB · 703% larger |
| `tools.compress.fit.50000000` | PASS | sample-compressed-3.mkv | 44 KB → 353 KB · 703% larger |
| `tools.compress.fit.100000000` | PASS | sample-compressed-4.mkv | 44 KB → 353 KB · 703% larger |
| `tools.compress.light` | REFUSED (expected) |  | Can't fit this video under 33 KB. |
| `tools.compress.medium` | REFUSED (expected) |  | Can't fit this video under 22 KB. |
| `tools.compress.strong` | REFUSED (expected) |  | Can't fit this video under 11 KB. |
| `tools.speed.0.25` | PASS | sample-0.25x.mkv | Saved 1 file |
| `tools.speed.0.5` | PASS | sample-0.5x.mkv | Saved 1 file |
| `tools.speed.1.5` | PASS | sample-1.5x.mkv | Saved 1 file |
| `tools.speed.2.0` | PASS | sample-2x.mkv | Saved 1 file |
| `tools.speed.4.0` | PASS | sample-4x.mkv | Saved 1 file |
| `tools.mute` | PASS | sample-muted.mkv | Saved 1 file |
| `tools.removeMetadata` | PASS | sample-clean.mkv | Saved 1 file |

#### Video: large MOV 640x360, 10 s, 6 MB (tier/fit realism) (`big.mov`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.mp4` | PASS | big-converted.mp4 | Saved 1 file |
| `convert.mkv` | PASS | big-converted.mkv | Saved 1 file |
| `convert.webm` | PASS | big-converted.webm | Saved 1 file |
| `convert.avi` | PASS | big-converted.avi | Saved 1 file |
| `convert.wmv` | PASS | big-converted.wmv | Saved 1 file |
| `convert.gif` | PASS | big-converted.gif | Saved 1 file |
| `convert.m4a` | PASS | big-converted.m4a | Saved 1 file |
| `convert.mp3` | PASS | big-converted.mp3 | Saved 1 file |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.compress.fit.10000000` | PASS | big-compressed.mov | 6.2 MB → 9.4 MB · 52% larger |
| `tools.compress.fit.25000000` | PASS | big-compressed-2.mov | 6.2 MB → 23.4 MB · 278% larger |
| `tools.compress.fit.50000000` | PASS | big-compressed-3.mov | 6.2 MB → 47 MB · 661% larger |
| `tools.compress.fit.100000000` | PASS | big-compressed-4.mov | 6.2 MB → 52.5 MB · 749% larger |
| `tools.compress.light` | PASS | big-compressed-5.mov | 6.2 MB → 4.4 MB · 30% smaller |
| `tools.compress.medium` | PASS | big-compressed-6.mov | 6.2 MB → 2.9 MB · 53% smaller |
| `tools.compress.strong` | PASS | big-compressed-7.mov | 6.2 MB → 1.4 MB · 77% smaller |
| `tools.speed.0.25` | PASS | big-0.25x.mov | Saved 1 file |
| `tools.speed.0.5` | PASS | big-0.5x.mov | Saved 1 file |
| `tools.speed.1.5` | PASS | big-1.5x.mov | Saved 1 file |
| `tools.speed.2.0` | PASS | big-2x.mov | Saved 1 file |
| `tools.speed.4.0` | PASS | big-4x.mov | Saved 1 file |
| `tools.mute` | PASS | big-muted.mov | Saved 1 file |
| `tools.removeMetadata` | PASS | big-clean.mov | Saved 1 file |

#### Audio: WAV (`sample.wav`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.m4a` | PASS | sample-converted-3.m4a | Saved 1 file |
| `convert.aac` | PASS | sample-converted.aac | Saved 1 file |
| `convert.aiff` | PASS | sample-converted.aiff | Saved 1 file |
| `convert.flac` | PASS | sample-converted.flac | Saved 1 file |
| `convert.mp3` | PASS | sample-converted-3.mp3 | Saved 1 file |
| `convert.ogg` | PASS | sample-converted.ogg | Saved 1 file |
| `convert.opus` | PASS | sample-converted.opus | Saved 1 file |
| `convert.wma` | PASS | sample-converted.wma | Saved 1 file |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.compress.bitrate.256` | PASS | sample-compressed.m4a | 265 KB → 99 KB · 62% smaller |
| `tools.compress.bitrate.192` | PASS | sample-compressed-2.m4a | 265 KB → 75 KB · 72% smaller |
| `tools.compress.bitrate.128` | PASS | sample-compressed-3.m4a | 265 KB → 50 KB · 81% smaller |
| `tools.compress.bitrate.96` | PASS | sample-compressed-4.m4a | 265 KB → 38 KB · 86% smaller |
| `tools.compress.bitrate.0` | PASS | sample-compressed-5.m4a | 265 KB → 89 KB · 66% smaller |
| `tools.normalize` | PASS | sample-normalized.wav | Saved 1 file |
| `tools.channels.toMono` | PASS | sample-mono.wav | Saved 1 file |
| `tools.channels.toStereo` | PASS | sample-stereo.wav | Saved 1 file |
| `tools.channels.swap` | PASS | sample-swapped.wav | Saved 1 file |
| `tools.metadata.stripAll` | PASS | sample-clean.wav | Saved 1 file |

#### Audio: MP3 (needs ffmpeg) (`sample.mp3`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.m4a` | PASS | sample-converted-4.m4a | Saved 1 file |
| `convert.aac` | PASS | sample-converted-2.aac | Saved 1 file |
| `convert.wav` | PASS | sample-converted.wav | Saved 1 file |
| `convert.aiff` | PASS | sample-converted-2.aiff | Saved 1 file |
| `convert.flac` | PASS | sample-converted-2.flac | Saved 1 file |
| `convert.ogg` | PASS | sample-converted-2.ogg | Saved 1 file |
| `convert.opus` | PASS | sample-converted-2.opus | Saved 1 file |
| `convert.wma` | PASS | sample-converted-2.wma | Saved 1 file |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.compress.bitrate.256` | PASS | sample-compressed.mp3 | 24 KB → 98 KB · 300% larger |
| `tools.compress.bitrate.192` | PASS | sample-compressed-2.mp3 | 24 KB → 73 KB · 200% larger |
| `tools.compress.bitrate.128` | PASS | sample-compressed-3.mp3 | 24 KB → 49 KB · 100% larger |
| `tools.compress.bitrate.96` | PASS | sample-compressed-4.mp3 | 24 KB → 37 KB · 50% larger |
| `tools.compress.bitrate.0` | PASS | sample-compressed-5.mp3 | 24 KB → 24 KB · same size |
| `tools.normalize` | PASS | sample-normalized.mp3 | Saved 1 file |
| `tools.channels.toMono` | PASS | sample-mono.mp3 | Saved 1 file |
| `tools.channels.toStereo` | PASS | sample-stereo.mp3 | Saved 1 file |
| `tools.channels.swap` | PASS | sample-swapped.mp3 | Saved 1 file |
| `tools.metadata.stripAll` | PASS | sample-clean.mp3 | Saved 1 file |

#### PDF with text (3 pages) (`sample.pdf`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.jpg` | PASS | sample-page-1.jpg,sample-page-2.jpg,sample-page-3.jpg | Saved 3 files |
| `convert.png` | PASS | sample-page-1.png,sample-page-2.png,sample-page-3.png | Saved 3 files |
| `convert.txt` | PASS | sample-converted.txt | Saved 1 file |
| `convert.md` | PASS | sample-converted.md | Saved 1 file |
| `convert.docx` | PASS | sample-converted.docx | Saved 1 file |
| `convert.epub` | PASS | sample-converted.epub | Saved 1 file |
| `convert.pages` | SKIP |  | iWork |
| `convert.pptx` | PASS | sample-converted.pptx | Saved 1 file |
| `convert.xlsx` | PASS | sample-converted.xlsx | Saved 1 file |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.compress.light` | PASS | sample-compressed.pdf | 14 KB → 14 KB · 1% larger |
| `tools.compress.medium` | PASS | sample-compressed-2.pdf | 14 KB → 14 KB · 1% larger |
| `tools.compress.strong` | PASS | sample-compressed-3.pdf | 14 KB → 86 KB · 509% larger |
| `tools.compress.fit.1000000` | PASS | sample-compressed-4.pdf | 14 KB → 14 KB · 1% larger |
| `tools.compress.fit.5000000` | PASS | sample-compressed-5.pdf | 14 KB → 14 KB · 1% larger |
| `tools.compress.fit.10000000` | PASS | sample-compressed-6.pdf | 14 KB → 14 KB · 1% larger |
| `tools.split.everyPage` | PASS | sample-part-1.pdf,sample-part-2.pdf,sample-part-3.pdf | Saved 3 files |
| `tools.metadata` | PASS | sample-clean.pdf | Saved 1 file |

#### PDF: image-only, 9 MB (no text layer) (`big-scan.pdf`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.jpg` | PASS | big-scan-page-1.jpg | Saved 1 file |
| `convert.png` | PASS | big-scan-page-1.png | Saved 1 file |
| `convert.txt` | REFUSED (expected) |  | This PDF has no text to extract. It may be scanned pages. |
| `convert.md` | REFUSED (expected) |  | This PDF has no text to extract. It may be scanned pages. |
| `convert.docx` | REFUSED (expected) |  | This PDF has no text to extract. It may be scanned pages. |
| `convert.epub` | REFUSED (expected) |  | This PDF has no text to extract. It may be scanned pages. |
| `convert.pages` | SKIP |  | iWork |
| `convert.pptx` | PASS | big-scan-converted.pptx | Saved 1 file |
| `convert.xlsx` | REFUSED (expected) |  | This PDF has no text to extract. It may be scanned pages. |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.compress.light` | PASS | big-scan-compressed.pdf | 8.9 MB → 8.9 MB · same size |
| `tools.compress.medium` | PASS | big-scan-compressed-2.pdf | 8.9 MB → 3 MB · 66% smaller |
| `tools.compress.strong` | PASS | big-scan-compressed-3.pdf | 8.9 MB → 2.6 MB · 71% smaller |
| `tools.compress.fit.1000000` | REFUSED (expected) |  | Can't get this PDF under 1000000 bytes. |
| `tools.compress.fit.5000000` | PASS | big-scan-compressed-4.pdf | 8.9 MB → 3 MB · 66% smaller |
| `tools.compress.fit.10000000` | PASS | big-scan-compressed-5.pdf | 8.9 MB → 8.9 MB · same size |
| `tools.split.everyPage` | PASS | big-scan-part-1.pdf | Saved 1 file |
| `tools.metadata` | PASS | big-scan-clean.pdf | Saved 1 file |

#### Document: DOCX (`sample.docx`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.pdf` | PASS | sample-converted-5.pdf | Saved 1 file |
| `convert.txt` | PASS | sample-converted-2.txt | Saved 1 file |
| `convert.md` | PASS | sample-converted-2.md | Saved 1 file |
| `convert.html` | PASS | sample-converted.html | Saved 1 file |
| `convert.epub` | PASS | sample-converted-2.epub | Saved 1 file |
| `convert.pages` | SKIP |  | iWork |

#### Spreadsheet: CSV (`sample.csv`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.xlsx` | PASS | sample-converted-2.xlsx | Saved 1 file |
| `convert.tsv` | PASS | sample-converted.tsv | Saved 1 file |
| `convert.pdf` | PASS | sample-converted-6.pdf | Saved 1 file |
| `convert.numbers` | SKIP |  | iWork |
| `convert.ods` | PASS | sample-converted.ods | Saved 1 file |

#### Subtitles: SRT (`sample.srt`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.vtt` | PASS | sample-converted.vtt | Saved 1 file |
| `convert.txt` | PASS | sample-converted-3.txt | Saved 1 file |

#### Archive: ZIP (`sample.zip`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.tar` | PASS | sample.tar | Saved 1 file |
| `convert.tgz` | PASS | sample.tar.gz | Saved 1 file |

**Tools wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `tools.extract` | PASS | z.txt | 1 item |

#### Folder (2 files) (`folder-sample`)

**Convert wheel**

| Slice id | Result | Output written | Note |
|---|---|---|---|
| `convert.zip` | PASS | folder-sample.zip | 1 item |
| `convert.tar` | PASS | folder-sample.tar | 1 item |
| `convert.tgz` | PASS | folder-sample.tar.gz | 1 item |

#### Actions wheel (all samples)

Run for every sample above: Copy Path (POSIX, URI) and Archive (ZIP, TAR, TAR.GZ) each PASS on all 18 samples; Float, AirDrop and Terminal are SKIP (UI-only); Copy to / Move to are SKIP in the matrix and exercised once separately below (they write to real folders).

| Sample | copyPath.posix | copyPath.uri | archive.zip | archive.tar | archive.tgz |
|---|---|---|---|---|---|
| `sample.png` | PASS | PASS | PASS `sample.png.zip` | PASS `sample.png.tar` | PASS `sample.png.tar.gz` |
| `sample.jpg` | PASS | PASS | PASS `sample.jpg.zip` | PASS `sample.jpg.tar` | PASS `sample.jpg.tar.gz` |
| `sample.heic` | PASS | PASS | PASS `sample.heic.zip` | PASS `sample.heic.tar` | PASS `sample.heic.tar.gz` |
| `sample.svg` | PASS | PASS | PASS `sample.svg.zip` | PASS `sample.svg.tar` | PASS `sample.svg.tar.gz` |
| `big-photo.jpg` | PASS | PASS | PASS `big-photo.jpg.zip` | PASS `big-photo.jpg.tar` | PASS `big-photo.jpg.tar.gz` |
| `qr.png` | PASS | PASS | PASS `qr.png.zip` | PASS `qr.png.tar` | PASS `qr.png.tar.gz` |
| `sample.mov` | PASS | PASS | PASS `sample.mov.zip` | PASS `sample.mov.tar` | PASS `sample.mov.tar.gz` |
| `sample.mkv` | PASS | PASS | PASS `sample.mkv.zip` | PASS `sample.mkv.tar` | PASS `sample.mkv.tar.gz` |
| `big.mov` | PASS | PASS | PASS `big.mov.zip` | PASS `big.mov.tar` | PASS `big.mov.tar.gz` |
| `sample.wav` | PASS | PASS | PASS `sample.wav.zip` | PASS `sample.wav.tar` | PASS `sample.wav.tar.gz` |
| `sample.mp3` | PASS | PASS | PASS `sample.mp3.zip` | PASS `sample.mp3.tar` | PASS `sample.mp3.tar.gz` |
| `sample.pdf` | PASS | PASS | PASS `sample.pdf.zip` | PASS `sample.pdf.tar` | PASS `sample.pdf.tar.gz` |
| `big-scan.pdf` | PASS | PASS | PASS `big-scan.pdf.zip` | PASS `big-scan.pdf.tar` | PASS `big-scan.pdf.tar.gz` |
| `sample.docx` | PASS | PASS | PASS `sample.docx.zip` | PASS `sample.docx.tar` | PASS `sample.docx.tar.gz` |
| `sample.csv` | PASS | PASS | PASS `sample.csv.zip` | PASS `sample.csv.tar` | PASS `sample.csv.tar.gz` |
| `sample.srt` | PASS | PASS | PASS `sample.srt.zip` | PASS `sample.srt.tar` | PASS `sample.srt.tar.gz` |
| `sample.zip` | PASS | PASS | PASS `sample.zip.zip` | PASS `sample.zip.tar` | PASS `sample.zip.tar.gz` |
| `folder-sample` | PASS | PASS | PASS `folder-sample-2.zip` | PASS `folder-sample-2.tar` | PASS `folder-sample-2.tar.gz` |

#### Actions that write to real folders (run once, cleaned up)

| Slice | Sample | Result | Output |
|---|---|---|---|
| `actions.copyTo./Users/kevog/Downloads` | `sample.png` | PASS | `~/Downloads/sample.png` (removed afterwards; it did not exist before) |
| `actions.moveTo./Users/kevog/Downloads` | `moveme.png` (a throwaway copy) | PASS | `~/Downloads/moveme.png`; the source left the QA folder (removed afterwards) |

#### Several files at once

| Selection | Slice | Result | Output written | Note |
|---|---|---|---|---|
| 2 PNGs | `tools.collage` | PASS | sample-collage.jpg | 2 images |
| 2 PNGs | `convert.pdf` | PASS | sample-combined.pdf | 2 pages |
| 2 JPGs | `tools.compress.light` | PASS | big-photo-compressed-7.jpg,sample-compressed-10.jpg | 2.9 MB → 2.2 MB · 25% smaller |
| 2 PNGs | `tools.metadata.stripAll` | PASS | sample-clean-3.png,second-clean.png | Saved 2 files |
| 2 PNGs | `actions.copyPath.posix` | PASS |  | Copied 2 paths |
| 2 PDFs | `tools.merge` | PASS | sample-merged.pdf | 6 pages |
| 2 PDFs | `tools.split.everyPage` | PASS | sample-part-1-2.pdf,sample-part-2-2.pdf,sample-part-3-2.pdf,second-part-1.pdf,second-part-2.pdf,second-part-3.pdf | Saved 6 files |
| 2 MOVs | `tools.join` | PASS | sample-joined.mov | Saved 1 file |
| 2 MOVs | `tools.mute` | PASS | sample-muted-2.mov,second-muted.mov | Saved 2 files |
| PNG + PDF + WAV | `convert.zip` | PASS | Archive.zip | 3 items |
| PNG + PDF + WAV | `actions.archive.tgz` | PASS | Archive.tar.gz | 3 items |
| PNG + PDF + WAV | `tools.metadata` | PASS | sample-clean-3.jpg,sample-clean-2.pdf,sample-clean-2.wav | Saved 3 files |
| PNG + PDF + WAV | `tools.compress.medium` | PASS | big-photo-compressed-8.jpg,big-scan-compressed-6.pdf | 11.8 MB → 4.4 MB · 62% smaller |

## 5. Editor smoke check (headless)

`/Applications/Orbit.app/Contents/MacOS/Orbit --check-editors <png>` opens every editor panel offscreen and checks frame, visibility, release on close, the model-to-job-parameter mapping, and the PDF/media editors against generated samples.

| Run | Result |
|---|---|
| `--check-editors sample.png` | **PASS**: 177 checks passed, exit 0 (`all editor checks passed`) |
| `--check-editors sample.png sample.pdf` | 3 of 180 checks FAIL by construction: the Redact checks search the PDF for the word `Account`, which my text-only sample PDF does not contain. Not an app defect; run without a PDF argument (it generates its own sample). |

## 6. Findings from this pass

Fixed (each with a covering test):

1. **PDF "Fit under…" refused targets it could meet.** `PDFTools.compress` read the candidate's size through `URL.resourceValues`, which caches the size on the URL, so every level (light, medium, strong, 72 DPI) reported the first level's size. Dropping a 8.9 MB image PDF on "Under 5 MB" failed with "Can't get this PDF under 5000000 bytes" although Medium alone produced 3 MB. Now reads the size from the file system. Test: `PDFTests.compressFitUnderSeesEachLevelsOwnSize`.
2. **SVG showed a METADATA slice that could only fail** ("Orbit can't read this image."). ImageIO cannot open SVG and SVG has no EXIF/GPS block, so the slice is no longer offered for SVG-only selections (a mix of SVG and raster images still gets it). Test: `CatalogTests.svgHasNoMetadataSlice`.

Open (not fixed):

1. **"Fit under X" on a file already under X can make it bigger.** `big.mov` (6.2 MB) → Under 10 MB gave 9.4 MB; a 2 KB PNG → Under 500 KB gave 14 KB; `sample.jpg` 12 KB → 15 KB. The encoder aims at the target instead of leaving a smaller source alone. Spec §6.3/§6.4 do not say what should happen; a no-op or "already under" message would be friendlier. Needs a decision.
2. **JPG/PNG → PDF is much larger than the source** (2.9 MB JPG → 8.9 MB PDF) because the page image is re-embedded losslessly rather than as the original JPEG stream. Correct output, just heavy; Compress → Medium brings it to 3 MB.
3. **Hardware H.264 encoder contention**: the earlier ledger note that `VideoConversionTests.mkvToMP4`/`proxyIsCached` fail when several agents encode at once did not reproduce; both pass in this run.
4. Everything else in the ledger's "minor (deferred)" lists is unchanged.

## 7. Build verification

- `swift test`: 502 tests in 21 suites passed (4 iWork tests skipped without `ORBIT_IWORK_TESTS=1`; ffmpeg tests ran).
- `scripts/build-app.sh && scripts/install.sh`: succeeded; `lipo -archs /Applications/Orbit.app/Contents/MacOS/Orbit` → `x86_64 arm64`; `codesign -dv` → `Signature=adhoc`; Orbit is running (menu bar).
