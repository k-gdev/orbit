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

---

# Fix round 1

Task review items I1, M2, M1, M3 and the controller's robustness ruling on shake detection. All on `suite/shelf`, one commit
per fix (trailer `Co-Authored-By: Claude Sonnet 5.5`), not pushed. **This section supersedes the earlier text where they
disagree**: "missing files are pruned when the shelf is shown" (now: only when truly gone, see I1), "a move result removes the
item" (now: re-checked first, see M1), "the shake watcher uses a global `leftMouseDragged` monitor" (now: polling, see the
last item), and `ShelfStore.load()` doing the file checks at start-up (now: nothing on the main thread, see M2).

Commits, in order (new tests were written first and seen to fail to compile, `error: cannot find ... in scope`, each time):

| Commit | Fix |
|---|---|
| `cc315cc` feat(shelf): tell a missing file from one whose drive is offline | I1 core |
| `b6358b9` fix(shelf): never silently overwrite a shelf file that can't be fully read | M3 |
| `4577550` feat(shelf): ShakePoller, the polling decisions behind shake to open | shake ruling, core |
| `d2c3375` fix(shelf): a move result no longer removes the item at drop time | M1 |
| `e985b63` feat(shelf): ShelfItems.replace keeps a re-found file's place | I1 support |
| `c3c6a39` fix(shelf): keep items on an offline drive, and keep the file system off the main thread | I1 app + M2 |
| `a6be5f2` fix(shelf): shake to open polls instead of relying on drag events reaching a global monitor | shake ruling, app |

## I1 Items on an offline volume were deleted from the shelf

**Cause.** `removeMissing()` treated `!fileExists` as gone, and `fileExists` is also false for "permission denied", a timeout, or
an unmounted drive. It ran on every show and every tab appearance and rewrote `shelf.json`.

**Fix (core, tested).** `OrbitCore/Shelf/ShelfAvailability.swift`: `ShelfProbeResult` (`exists` / `absent` / `unavailable`),
`ShelfItemStatus` (`available` / `missing` / `unreachable`), `ShelfAvailability.status(of:probe:)`. A path is `missing` only when
the probe says **absent** and its volume is mounted: the volume is `/Volumes/<name>` for anything under `/Volumes` (checked with
the same probe: that folder exists only while the drive is mounted), otherwise the startup disk. An error (`EACCES`, `EPERM`,
`EIO`, `ETIMEDOUT`, `ESTALE`, ...) is never "gone": only `ENOENT`/`ENOTDIR` mean absent (`probeResult(errnoValue:)`, real probe is
`lstat` + `errno`). Everything else is `unreachable`. This also closes a second data-loss route in my first version: a TCC
"denied" answer on Documents/Downloads used to look like "missing".

**Fix (app).** `ShelfModel.refreshAvailability()` (replaces `removeMissing()`): checks every item concurrently on background queues
with a 3 s deadline (`ShelfScan`; a path whose check hasn't returned is never checked again, so a stuck mount can't pile up
threads). Result per item: available (nothing), **missing -> dropped, or followed through its bookmark and replaced in place**
(`ShelfItems.replace`, new, tested), **unreachable or no answer in time -> kept, `model.unreachable`**. Unreachable items show
dimmed with a warning mark, "Not connected" in the tab's list, a tooltip explaining it ("Can't reach this file right now: its
drive may be disconnected or asleep. It stays on the shelf until you remove it."), the header says e.g. "5 files, 2 offline",
they can't be dragged or opened or previewed (no thumbnail request, no "Drag all" inclusion), only removed or have their path
copied. `shelf.json` is only rewritten when something really changed.

Tests (`Tests/OrbitCoreTests/ShelfRobustnessTests.swift`, new suite `ShelfRobustnessTests`): `volumeRootComesFromThePath`,
`aFileThatIsThereIsAvailable`, `goneFileOnAMountedVolumeIsMissing`, `fileOnAnUnmountedVolumeIsUnreachableNotMissing`,
`anErrorIsNeverTreatedAsGone`, `errnoMapsToAProbeResult`, `realProbeSeesTheFilesystem`, `replaceKeepsTheItemsPlace`.
`--check-shelf` end to end: an item under `/Volumes/OrbitShelfCheck-<uuid>/` stays on the shelf, shows as unreachable, is not
in `availableURLs`, is still in `shelf.json` after a flush, and after a "relaunch" (new model, `load()`) is still there and
unreachable; a file deleted from the startup disk is dropped; a renamed file is followed and keeps its place.

## M2 Synchronous file system access on the main thread

- `ShelfModel.load()` returns immediately: `ShelfStore.loadStored()` (reads `shelf.json` only, **no stat of the listed files**)
  runs detached; items dropped before it finishes are kept after the saved ones; nothing is written before the saved list has
  loaded (so a drop at launch can't overwrite it).
- Saving is `save(_:)` on a serial background queue (last write wins); `flush()` waits at most 1 s (used by `stop()`, i.e. on
  disable and quit, and by the check). `ShelfStore` is now thread-safe (internal lock, `@unchecked Sendable`) and remembers when
  a bookmark could not be made, so a save doesn't re-stat dead paths.
- The availability checks (I1) and `ShelfIcon.prime` (real icons) run off the main thread. **Views never touch the file system**:
  `ShelfIcon.icon(for:)` returns the cached real icon or the icon for the file's type (`NSWorkspace.icon(for: UTType)`, no stat);
  tiles and rows read it; the drag source copies the cached icon instead of resizing the shared one; `ShelfThumbnails` is no
  longer main-actor and probes the file on the background pool first, and unreachable tiles don't ask for one.
- Paths loaded from `shelf.json` are `URL(fileURLWithPath:isDirectory: false)` so no hidden stat decides the trailing slash.

Tests/evidence: `ShelfStore.loadStored()` is covered by `loadStoredNeverTouchesTheFilesItListsAndLoadFollowsMovedOnes` (items on
`/Volumes/Gone Drive/...` come back from `loadStored()` untouched, `follow` finds a renamed file and nothing for the missing
drive, `load()` = `loadStored()` + following). `--check-shelf`: `load returns at once and reads in the background` (`!model.isLoaded`
right after `load()`), `add wrote shelf.json (in the background)`, `stopping releases the items and leaves the file`.
**Not provable here:** an actual stall on a dead SMB mount. By construction nothing on the main thread can wait for one now.

## M1 A `.move` drag result removed the item at drop time

`ShelfDragOutcome.removesFromShelf` is now `mayHaveMovedFiles(operationRawValue:)` (+ `recheckDelay = 1.5`). The drag source calls
`ShelfModel.verifyMoved(_:)` for a move or delete result; it waits 1.5 s, checks off the main thread with `ShelfAvailability`, and
removes **only** files that are `missing` (absent from a mounted volume). A cancelled Replace dialog or failed move keeps the
reference; an unreachable file stays. A large cross-volume move that is still in progress at 1.5 s is dropped at the next
`refreshAvailability()` (next show or tab appearance) when the file is really gone.
Tests: `dragOutMoveOrDeleteMeansLookAgain` (renamed from `dragOutMoveRemovesCopyKeeps`; asserts the AppKit constants, the delay, and
that copy/link/generic/none don't trigger it). `--check-shelf`: `nothing leaves the shelf at the drop itself (Finder hasn't done
anything yet)` then `after the re-check only the file that really went is dropped` (one file really moved, the other's "move"
cancelled, so it stays).

## M3 A corrupt or newer `shelf.json` was silently treated as empty and overwritten

`ShelfStore` now: decodes entries leniently (one bad entry, a bad bookmark, a non-object element no longer drops the others; a
bad bookmark just means no bookmark), checks `version` (writes 1; a larger one is read as far as possible and marked newer),
and **before the first save after a `load` that found anything it couldn't fully read** moves the original aside to
`shelf.json.corrupt-<yyyyMMdd-HHmmss>` (undecodable, unreadable, or some entries skipped) or `shelf.json.newer-<...>` (UTC; `-2`,
`-3`, ... appended so an earlier backup is never overwritten). If the move fails, `save` throws and writes nothing (the damaged
file stays). A clean file or no file never produces a backup. `load` itself never writes.
Tests: `aCorruptShelfFileIsMovedAsideBeforeTheFirstSave`, `aBackupNeverOverwritesAnEarlierOne` (three damages in the same second
give `...073320`, `-2`, `-3` with the right contents), `aNewerVersionIsReadAsFarAsPossibleAndPreserved`,
`oneBadEntryDoesNotDiscardTheRest`, `aCleanShelfFileMakesNoBackups`, `ifTheDamagedFileCannotBeKeptItIsNotOverwritten`.
`--check-shelf`: `a damaged shelf file is moved aside before the first save, with its content` + `and the new shelf file is valid`
(through the model, end to end).

## Shake detection no longer depends on `leftMouseDragged`

`ShakeWatcher` (rewritten) installs **one global `leftMouseDown` monitor** (nothing else) and, like the wheel's `InputSampler`,
polls: a press starts a timer that reads `NSEvent.pressedMouseButtons`, `NSEvent.mouseLocation` and the drag pasteboard and
feeds the new pure `ShakePoller` (core, tested), which wraps `FileDragGate` + `ShakeDetector`:
- waiting (button down, no file drag yet): 20 Hz, and the pasteboard's types are read **only when its change count moved** since the press;
- tracking (change count moved AND it holds file URLs): 60 Hz, samples go to `ShakeDetector`; after a shake the timer keeps
  running at the fast rate until release (the detector's 1 s lockout stops repeats);
- the button is up: the timer stops. A click costs one or two ticks.
The `leftMouseDragged` path is **removed** (it added nothing the poller doesn't have, and double-feeding the detector was a risk).
Nothing exists while Shelf is off or shake-to-open is off: `start()`/`stop()` install/remove the monitor, `stop()` also kills the timer.
`ShakeWatcher` takes an `Inputs` struct (buttons, change count, types, location, clock; default live) so the glue is checked
without a real drag. [builder's call] I did **not** add the wheel's 4 Hz idle backstop for a press the monitor missed (it would
cost a permanent timer): a global left-press monitor is the one mouse event every other app already depends on.
Tests: `pollerStopsWhenTheButtonIsReleased`, `pollerLeavesThePasteboardAloneUntilItChanges`, `pollerIgnoresATextDragEvenWhenShakenHard`
(types read once per change), `pollerReportsAShakeOnlyForAFileDrag` (tracks from the first file-drag tick, one shake, not before the third
reversal), `pollerStartsFreshOnTheNextPress`, `pollIntervalsKeepIdleCostLowAndShakingResponsive`. `--check-shelf` with a scripted mouse:
`an idle watcher has no timer`, `a press starts the timer, slowly`, `a stale file pasteboard never counts, however hard the mouse is
shaken`, `shaking a text drag does nothing`, `releasing the button stops the timer`, `shaking a file drag opens the shelf, once`,
`the timer is at the fast rate while the file drag lasts`, `the timer stops when the button is released`.
Still needs Kevo's Mac: a real Finder drag (the press monitor firing for a Finder press, the drag pasteboard changing as the drag
starts), exactly as the wheel already relies on.

## Commands and results

```
swift test --filter Shelf            ->  ✔ Test run with 47 tests in 2 suites passed   (26 ShelfTests + 21 ShelfRobustnessTests)
.build/debug/Orbit --check-shelf     ->  54 PASS, 0 FAIL, "all checks passed", exit 0
swift test                           ->  ✔ Test run with 608 tests in 27 suites passed after 82.263 seconds
swift build -c release --arch arm64 --arch x86_64   ->  Build complete! (exit 0)
```
RED evidence per unit (each time `swift build --build-tests` before the implementation): `cannot find type 'ShelfProbeResult' in
scope` / `cannot find 'ShelfAvailability' in scope`; `extra argument 'now' in call` and `value of type 'ShelfStore' has no member
'loadStored'`; `cannot find type 'ShakePoller' in scope`; `type 'ShelfDragOutcome' has no member 'mayHaveMovedFiles'` / `'recheckDelay'`;
`value of type 'ShelfItems' has no member 'replace'`.

Snapshots re-checked: `shelf-offline-light.png` (`--snapshot-shelf ... --offline 2 --hover 4`: two dimmed tiles with warning marks,
"5 files, 2 offline", hover ✕ still drawn), `panel-offline-dark.png` (tab row "Archive 2026.zip / Not connected" dimmed with the mark).
The `--snapshot-panel shelf` fixture now includes that one offline row.

## Known gaps added or changed by this round

- Only `/Volumes/<name>` is recognised as another volume's mount point. A drive mounted somewhere else is treated like the startup
  disk, so a file missing there would still be dropped when it is absent (an unmounted custom mount point is not detected).
- A file that is still being moved by Finder after 1.5 s (a big cross-volume move) leaves the shelf at the next show or tab view, not at once.
- No idle backstop for a press the global monitor misses (see the shake section).
