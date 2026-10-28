# Shelf (Task 12) report

Branch `suite/shelf` (base `1a84988 docs(suite): shell implementer report`), 10 commits, not pushed. Written by the
Shelf implementer (model: Sonnet 5.5).

NOTE: the brief asked for this file at `/Users/kevog/orbit/.claude/worktrees/suite-77e4bb/docs/suite/reports/shelf.md`, but my
write tools refused any path outside my own worktree, so it is here instead
(`/Users/kevog/orbit/.claude/worktrees/agent-ad5653fc89091221b/docs/suite/reports/shelf.md`, **uncommitted**). Copy it over.

## What was built

A floating glass **Shelf** that holds references to files while you move between windows and Spaces.

- **Opens** by shaking the cursor during a file drag (`ShakeWatcher`), from the new **SHELF** slice of the wheel's
  Actions ring (after FLOAT, only while the Shelf feature is on), and from the **Shelf** tab of the menu bar panel.
- **Drop files** on it (file URLs only); they are listed as tiles with Quick Look previews.
- **Drag them back out** (each tile, the list rows in the tab, and a "Drag all" chip). Drag sessions offer copy, move
  and generic, so Finder moves on the same volume, copies across volumes, and copies with ⌥. A drag that ends with a
  move or delete result removes the files from the shelf; a copy leaves them.
- Items **persist** (path + bookmark JSON in `~/Library/Application Support/Orbit/Shelf/shelf.json`) until removed
  (✕ on hover, right-click, Clear). The shelf never moves, copies or deletes a file itself.
- Menu bar tab: Show/Hide button, list of items (drag out from the list too), Clear. Settings page: shake to open,
  keep on top, item count and Clear Shelf.
- Off costs nothing: no monitor, no window, no timers. `start()` loads the items and installs one global mouse monitor
  (only if "shake to open" is on); `stop()` removes it and closes the window. No permission needed.

## Files

Core (`Sources/OrbitCore/Shelf/`): `ShakeDetector`, `FileDragGate`, `ShelfItems`, `ShelfStore`, `ShelfSettings`,
`ShelfPlacement`, `ShelfDragOutcome`. Tests: `Tests/OrbitCoreTests/ShelfTests.swift` (26 tests).

App (`Sources/OrbitApp/Features/Shelf/`): `ShelfFeature` (replaces the stub), `ShelfModel` (+ `ShelfIcon`,
`ShelfThumbnails`), `ShelfPanel` (`ShelfPanel`, `ShelfContentView` drop target, `ShelfResizeGrip`,
`ShelfWindowController`), `ShelfStripView` (floating content, `ShelfTile`, `ShelfWindowHandle`), `ShelfDragSource`
(`NSDraggingSource` overlay), `ShakeWatcher`, `ShelfPanelView` (menu bar tab), `ShelfSettingsView`, `ShelfSnapshot`
(debug CLI modes), `ShelfCheck` (headless glue check).

### Wheel files changed (the ones the task lists)

- `Sources/OrbitCore/Model/Slice.swift`: `ActionID.shelf` (appended last, so the others are unchanged).
- `Sources/OrbitCore/Catalog/CatalogSettings.swift`: `showShelfAction: Bool = false` (trailing init parameter, default false).
- `Sources/OrbitCore/Catalog/SliceCatalog.swift`: `act(.shelf, "SHELF", "tray")` inserted at index 1 (right after FLOAT) only when `showShelfAction`.
- `Sources/OrbitCore/Jobs/ActionText.swift`: `.shelf` progress title "Adding to Shelf" (`outputSuffix` is already "" for actions).
- `Sources/OrbitCore/Processors/Actions/ActionProcessor.swift`: doc comment only. Its switches have `default:` branches, so `.shelf` falls through to "can't handle", as intended (it is app-side).
- `Sources/OrbitApp/Jobs/JobCoordinator.swift`: `var openShelf: (([URL], CGPoint) -> Void)?`; `.shelf` joins `performSystemAction` (headless runs fail with the usual "needs the app" message, like Float and AirDrop).
- `Sources/OrbitApp/Overlay/WheelController.swift`: `var shelfActionEnabled: () -> Bool = { false }`; `content(for:items:)` sets `catalog.showShelfAction = shelfActionEnabled()`. Also `content(for:items:)` lost `private` so `--check-shelf` can read the ring.
- `Sources/OrbitApp/AppDelegate.swift`: after `makeSuite`, `wheel.shelfActionEnabled = { registry.isEnabled(.shelf) }` and `coordinator.openShelf = { (registry.feature(.shelf) as? ShelfFeature)?.open(adding:near:) }`.

With the Shelf off the wheel is exactly what it was: `CatalogSettings.showShelfAction` defaults to false, every existing
catalog/job test passes unchanged, and `--snapshot-shelf-wheel off` and `--check-shelf` show the old 7-slice ring.
`DragWatcher` and `InputSampler` are untouched; the shake watcher is independent of them.

### Shell changes (minimal, all listed)

1. `Sources/OrbitApp/main.swift`: two added lines, `ShelfSnapshot.runIfRequested(...)` and `ShelfCheck.runIfRequested(...)` (the brief asked for a snapshot mode for the floating panel itself; this is the only way to hook one in). **Expect a trivial merge conflict here with the other features' snapshot lines.**
2. `Sources/OrbitApp/Suite/SnapshotFixtures.swift`: copied byte-for-byte from `claude/suite-77e4bb` (`git checkout claude/suite-77e4bb -- <file>`) per the controller's note on throwaway defaults. Identical content, so it should merge without conflict. It was its own commit (`376d7bf`).

## Tests and TDD evidence

All in `Tests/OrbitCoreTests/ShelfTests.swift` (`@Suite struct ShelfTests`), using `Fixtures.defaults()` (absolute-path suite
in a temp folder) and `Fixtures.tempDir()`. Required names are all there: `shakeDetectedAfterThreeReversals`,
`slowWiggleIsNotShake`, `smallJitterIsNotShake`, `itemsUniqueAndOrdered`, `removeMissing`, `storeRoundTrip`,
`catalogShowsShelfOnlyWhenEnabled`, `settingsRoundTrip`; plus 18 more (two reversals are not enough, vertical shaking,
reset, reports once / lockout, stale timestamps, the file-drag gate, the store following a moved file via its bookmark,
a missing file kept by path, unreadable data, settings ignoring unusable frames, four placement tests, the Shelf
slice's shape, the processor not handling it, and the drag-out rule).

RED then GREEN per unit (RED = test written first; `swift build --build-tests` fails because the type does not exist):

| Unit | RED | GREEN (`swift test --filter ShelfTests`) |
|---|---|---|
| ShakeDetector | `error: cannot find type 'ShakeDetector' in scope` | `✔ Test run with 8 tests in 1 suite passed` |
| FileDragGate | `error: cannot find 'FileDragGate' in scope` | 9 tests passed |
| ShelfItems | `error: cannot find 'ShelfItems' in scope` (then a test-code fix: `#expect` cannot wrap a mutating call, so results are bound first) | 12 tests passed |
| ShelfStore | `error: cannot find 'ShelfStore' in scope` | 16 tests passed |
| ShelfSettings, ShelfPlacement | `cannot find 'ShelfSettings' / 'ShelfPlacement' in scope` | 22 tests passed |
| Catalog / ActionID | `type 'ActionID' has no member 'shelf'`, `value of type 'CatalogSettings' has no member 'showShelfAction'` | 26 pass with the drag-out test below; full suite after this step 586 tests, only the flaky `compressMKV` failed (see Flaky) |
| ShelfDragOutcome | test and implementation were written in the same step, so there was no separate RED at the time; afterwards I removed the implementation and confirmed `error: cannot find 'ShelfDragOutcome' in scope`, restored it, then 26 tests passed | 26 tests passed |

**Final full run (`swift test`, last commit): `✔ Test run with 587 tests in 26 suites passed after 89.819 seconds`**
(561 before this work + 26 new). `swift build` is green at every commit. **`swift build -c release --arch arm64 --arch x86_64`
succeeded (`Build complete!`, exit 0)**; I ran it once after the app was complete and again after the last small commit.

### Headless glue check (`Orbit --check-shelf`, nothing shown, 34 checks, all PASS)

Covers what unit tests cannot: the AppKit drop target driven with a stand-in `NSDraggingInfo` (a Finder-style drag gets
the copy cursor and highlight, both files handed over, a move-only source refused, a generic-only one accepted, a drag
that started on the shelf refused, a text drag refused), the model/store round trip and "files untouched", the panel's
window settings without ordering it front (never key, non-activating, all Spaces + full-screen auxiliary, floating),
the shake watcher's monitor install/remove idempotence, the real `WheelController` Actions ring with the Shelf off
(unchanged) and on (SHELF after FLOAT) and the Convert wheel unchanged, `JobCoordinator` handing the SHELF slice to
`openShelf` with the files and pointer (and refusing it headless), and `ShelfFeature` start/stop in any order creating
nothing on disk.

## Snapshots checked (looked at, light and dark where it applies)

Scratch folder: `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/shots/`

- `--snapshot-panel shelf`: `panel-light.png`, `panel-dark.png` (tab: Show button, hint, five-row list, Clear).
- `--snapshot-settings-page shelf`: `settings-light.png`, `settings-dark.png`.
- `--snapshot-shelf <png> [--empty] [--targeted] [--hover N] [--count N] [--dark] [--replace]` (new; the floating shelf itself over real temp fixture files, using the real `ShelfContentView` so the resize grip shows): `shelf-light.png` (second tile hovered, showing its ✕), `shelf-dark.png` (drop-targeted highlight), `shelf-empty.png`.
- `--snapshot-shelf-wheel on|off <png> [--highlight N] [--dark]` (new): `wheel-on.png` (SHELF highlighted; prints `FLOAT, SHELF, AIRDROP, COPY PATH, TERMINAL, COPY TO, MOVE TO, ARCHIVE`) and `wheel-off.png` (`FLOAT, AIRDROP, COPY PATH, TERMINAL, COPY TO, MOVE TO, ARCHIVE`, the old ring).

Glass renders as the flat fallback offscreen, so the real Liquid Glass look is unchecked (see below).

## [builder's call] list

- **Shake rule** (spec: 3 reversals, each leg >= 40 pt, within 0.6 s): a reversal is confirmed when the pointer comes back 40 pt from the end of a leg (zig-zag filter), so every counted leg is >= 40 pt and jitter never counts; "within 0.6 s" is the three reversal confirmations falling inside a 0.6 s window. In practice that is about four 40 pt+ legs. A 1 s lockout after a shake stops one long shake re-opening it; vertical movement is ignored. The numbers are `ShakeDetector` init parameters if Kevo wants it easier or harder.
- `shakeToOpen` default **on** (as the brief says), `keepOnTop` default on.
- A file drag is "drag pasteboard change count moved after the button went down AND it holds file URLs" (`FileDragGate`, the same rule as the wheel's trigger), so selecting text with a stale file pasteboard never triggers it. Until a file drag is confirmed the pasteboard is read at most 20 times a second; afterwards not at all for that press.
- Shake placement: shelf centred on the pointer (clamped to the visible frame) with the size the user last chose on that screen. If it is already open it jumps to the pointer. The wheel action does the same at the drop point. The tab opens it at its **last frame on the screen under the pointer**, else bottom centre 24 pt above the edge. So the remembered position is wherever it last was (a shake moves it).
- Frames are remembered **per display** under `shelf.frames` (JSON keyed by `DisplayIdentity.key`), saved 0.4 s after a move/resize and on hide; a saved frame is clamped onto the screen it opens on. If displays change while it is up, it is pulled back on screen.
- Order and uniqueness: new items append at the end; adding a file already there keeps its place; the same path in different spellings (`..`, folder slash) is the same item. Only `file:` URLs are accepted.
- Drop answer: the shelf answers a drop with **copy** (the "+" cursor) when the source allows it, else generic, else link, never move (so Finder never thinks its file was taken). Drags that started on the shelf are refused.
- A drag out that ends with **move or delete** (Finder same-volume move, the Trash) removes those files from the shelf; copy/generic/link leaves them. Pure rule in core (`ShelfDragOutcome`), asserted equal to AppKit's constants.
- Missing files are pruned (off the main thread) when the shelf is shown and when the tab appears, not at launch (a share that has not mounted yet at login would otherwise lose its items). A file moved/renamed on the same volume is followed through its bookmark; the stored path wins while it exists.
- Window: borderless non-activating `NSPanel`, `.floating` level (normal when keep-on-top is off), all Spaces, full-screen auxiliary, never key; moved by pressing any bare glass (a transparent background view calls `performDrag`), resized by a corner grip, min size 300 x 132, default 440 x 168; tiles are a scrolling adaptive grid of 76 pt cells.
- Hover (✕, highlight) uses tracking areas with `.activeAlways`, because SwiftUI's `onHover` does not fire for an app that is never active. The ✕ on a tile or row is drawn and handled by the AppKit overlay so drag, open and remove live in one place. (A headless hit-test probe confirmed SwiftUI buttons placed above an AppKit view do win clicks, which is what the header buttons rely on.)
- Double-click opens the file; right-click menu: Open, Show in Finder, Copy Path, Remove from Shelf. No Quick Look.
- A "Drag all" chip appears with two or more items and drags every file at once.
- Wheel: SHELF goes **right after FLOAT** (index 1). The ring is 8 slices, under the cap of 10.
- Tab: "Show" closes the menu bar panel first so the shelf is not left behind it.
- If something calls `open(adding:near:)` while the feature is off, a toast says Shelf is off (cannot normally happen: the slice is hidden while off).
- **Commit trailer**: the harness gave me `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` as the attribution for this session, the brief said `Claude Opus 5.5`. I used the harness one because it names the model that actually wrote the commits. If the controller wants the Opus line, `git rebase --exec` can rewrite it.

## Needs verification on Kevo's Mac (I could not drag anything real)

1. **Shake during a real Finder drag opens the shelf.** The global `leftMouseDragged` monitor is the brief's design and a standard technique, but whether macOS 26 delivers those events to a non-active app during another app's drag session is the one thing I could not prove headlessly. If it does not fire: the fallback is to poll `NSEvent.mouseLocation` at 60 Hz while `NSEvent.pressedMouseButtons & 1` and the drag pasteboard changed (the wheel's `InputSampler` does exactly that and is known to work), feeding the same `ShakeDetector` / `FileDragGate`. Also check it does not trigger when shaking while selecting text or moving a window.
2. **Drop on the shelf** from Finder accepts and adds the files; the Finder files stay untouched. Dropping right after a shake (the shelf appears under the cursor mid-drag).
3. **Drag out** to a Finder folder on the same volume moves the file (and the item leaves the shelf), on another volume copies, with ⌥ copies; to Mail/Slack/a browser attaches a copy; to the Trash removes it and the item.
4. The panel really stays on **all Spaces and over a full-screen app**, never steals focus (the frontmost app stays active while you click ✕ or Clear), and the first click on a button works without a prior click.
5. Resizing with the corner grip and moving by dragging bare glass feel right; the remembered frame per display restores after a relaunch.
6. Liquid Glass on macOS 26 (snapshots only render the flat fallback), the hover ✕ and the "+" drop highlight.
7. Turning Shelf off in Settings removes the SHELF slice (next time the wheel opens), the monitor and the window.
8. TCC: with Full Disk Access granted there is no prompt; without it, the first stat/thumbnail of a file in Documents/Downloads/Desktop may prompt for that folder (the wheel behaves the same).

## Known gaps

- No Quick Look on click, no multi-select, no reordering, no auto-hide; a file renamed outside the bookmark's reach looks like a new item until the old one is pruned.
- `ShelfStore.load()` runs on the main actor at `start()`. For items on an unreachable network share a `stat` could stall for a while; local files are instant.
- A shelved item from a drive that was unplugged is pruned the next time the shelf is shown.
- The shake detector relies on the 60 Hz-ish rate of drag events; at very low rates a shake is less likely to register.
- `--snapshot-shelf*` and `--check-shelf` are debug modes hooked in `main.swift`; about 700 lines of code that is not on the shipping path (the controller may prefer them behind a flag, or trimmed after review).

## Flaky tests seen under load (not caused by this work)

With seven other agents building and testing in parallel, three unrelated tests each failed once in full runs and passed
alone straight afterwards: `VideoToolTests/compressMKV` (the VideoToolbox hardware encoder was busy), `ProcessTests/cancellationTerminates`
(3.67 s against a 3 s limit) and `VideoToolTests/trimMKVStaysMKV` (0.17 against a 0.15 tolerance). The final full run was clean.

## Housekeeping

- No `~/Library/Preferences/*.plist` was created by my runs: tests and snapshots only use absolute-path suites in temp folders (`Fixtures.defaults()`, `SnapshotFixtures`). I checked read-only for new Orbit/fixture/snapshot/shelf plists since the session start: none (the only Orbit plist, `com.kevo.orbit.plist`, is Kevo's, dated Oct 20). `~/Library/Application Support/Orbit` was never created. (`MicMuteService.fixture()`, used by `--check-shelf` through the shell's own helper, writes its throwaway plist in the temp folder.)
- Nothing was pushed. I never launched the app. The snapshots and `--check-shelf` run offscreen and never order a window front; the shake monitor in `--check-shelf` is installed and removed within the process.
- Nothing under `.orbit-signing`, `Support/Brand/Concepts/` or `brag-output/` was touched. No file outside temp folders was created, moved, copied or deleted by tests or snapshots.
