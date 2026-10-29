# Final fix wave

Branch `claude/suite-77e4bb`, on top of a90da38. Ten items from the whole-branch review, one commit each, plus this report. `swift build` and `swift test` were green at every commit except 9dac92d, which only changes a comment: that one was built, and the full suite ran at the next commit. Sound files were not touched, and the version was not bumped.

| # | Commit | Item |
|---|---|---|
| 1 | 052c3aa | Hidden Edit menu and panel key equivalents |
| 2 | 9dc0afe | Resolution applied `.permanently` up front; confirm card is key |
| 3 | 7c58253 | Panel closes on app switch and display change |
| 4 | 29399f4 | Shelf never follows a file into the Trash |
| 5 | 890e0fa | Clipboard ingest generation guard |
| 6 | 2032efe | Dock preview: 0.4 s capture wait, 2 s window-list cache |
| 7 | 9dac92d | Contract wording (transient state only) |
| 8 | 03e1695 | Legacy `--snapshot-settings` on `SnapshotFixtures` |
| 9 | 4c50bbe | Generic fixture names |
| 10 | 2591208 | Windows and Clipboard fixtures on `SnapshotFixtures.defaults()` |

Final state: 876 tests in 67 suites pass (865 before this wave). `swift build -c release --arch arm64 --arch x86_64` succeeded.

## Items

1. **Edit menu.**
   - `EditMenu.install()` runs first thing in `applicationDidFinishLaunching`. It sets a hidden `NSApp.mainMenu` with two menus:
     - an app menu holding Quit Orbit ⌘Q;
     - an Edit menu: Undo ⌘Z, Redo ⇧⌘Z, Cut, Copy, Paste, Select All, sending the standard selectors.
   - `MenuBarPanel` and `ClipboardPopupPanel` override `performKeyEquivalent(with:)`. When a text view is first responder, they send the same actions down the responder chain. They use `NSApp.sendAction(_:to: nil, from:)` while the panel is the key window, and otherwise start the chain at the window's first responder. Any other key goes to `super`, so ⌘Q, ⌘, and the SwiftUI shortcuts behave as before.
   - The key mapping is `TextEditingShortcut` in OrbitCore.
   - TDD: `TextEditingShortcutTests` first failed with "cannot find type" (red), then passed 3/3 (green).
   - Probe: an offscreen non-activating panel in an accessory process that was not active, run as a scratchpad binary. ⌘A selected `{0, 11}`, ⌘Z undid an insert, and ⌘Q was left to super. Copy, Cut and Paste were not probed, to keep the real pasteboard untouched.
   - Settings and the editors activate Orbit, so the main menu covers them; no override was needed there.
2. **Resolution.**
   - `select` applies the new mode `.permanently`.
   - Keep only ends the confirmation.
   - Revert and the 15 s timeout re-apply `previous` `.permanently`, with the `CGRestorePermanentDisplayConfiguration` fallback kept.
   - The card calls `makeKey()` after `orderFrontRegardless()`.
   - Doc comments are updated in `DisplaysModel`, `DisplayModeService`, `ResolutionConfirm` and `ResolutionConfirmation`. The pure model encoded no `.forSession`, so there was no test to change.
   - In `displays.md`, the stale Known-gaps line is struck through and a "Final wave" section is appended.
   - Snapshot `displays-busy.png` (light and dark) is unchanged.
3. **Panel dismissal.**
   - While the panel is open it also observes `NSWorkspace.didActivateApplicationNotification` and `NSApplication.didChangeScreenParametersNotification`. Observers are now stored with their own notification center and removed on close.
   - `MenuBarPanelDismissal` (OrbitCore) keeps the panel open in two cases:
     - Orbit itself became active;
     - an app became active within 1 s of a click in the panel. Hiding or quitting the frontmost app from the Windows tab makes macOS activate the next app, and the panel should not close for that.
   - TDD: red (type missing), then green 3/3.
4. **Shelf and Trash.**
   - `ShelfAvailability.isInTrash` checks for a `.Trash` or `.Trashes` path component. `ShelfStore.follow` refuses such a URL.
   - The `panelDidAppear` comment is fixed: moved files are followed, trashed ones leave the shelf.
   - TDD: `storeDoesNotFollowAFileIntoTheTrash` (a real temp file moved into `<tmp>/.Trash`) failed with 4 issues. The store followed the file into the Trash. It passed after the fix.
   - `--check-shelf`: all checks passed.
5. **Clipboard after stop.**
   - Each queued copy records an `ingestGeneration`, and `cancelIngest()` bumps it.
   - A copy from an older generation is dropped at three points: before decoding, at the start of `add`, and right after its blob write (that blob is deleted again).
   - A new `--check-clipboard` case queues three copies and cancels at once:
     - Before the fix it FAILED: entries "second" and "first" were added and two `.txt` blobs written.
     - After the fix it passes: no entry, no blob. A copy made after the cancel is still added.
6. **Dock preview.**
   - The Accessibility read and the capture list now start together. If the list hasn't arrived within 0.4 s of the hover firing, the strip shows Accessibility's windows as title cards. Thumbnails and other-Space windows are filled in when the list arrives, under the same generation guard. With no Accessibility windows, the strip waits for the list.
   - `WindowThumbnailer` caches the window list for 2 s (a single-entry `TimedCache`) and shares a fetch already in flight.
   - The timings and the early-show rule are in `DockPreviewFill` (OrbitCore). TDD: red (type missing), then green with 3 new tests.
   - The `--snapshot-dock-preview` fixture snapshot is unchanged. The live hover path was not exercised.
7. **Contract wording.** `stop()` undoes transient state: taps, mutes, assertions, gamma, windows. User-chosen settings such as Controls' quick toggles stay as the user set them.
8. **Legacy snapshot.** It now uses `SnapshotFixtures.scopedDefaults()`. The PNG is byte-identical to the one the old code renders; both include ImageRenderer's yellow placeholders for AppKit controls, so those were not introduced here. No `orbit.snapshot.*` plist and no temp folder is left behind.
9. **Fixture names.**
   - The System fixture shows "AirPods Pro" (`system.png` checked).
   - The metadata editor's artist is "Demo Artist" (`editor-metadata.png` checked).
   - `SystemTests` uses "AirPods", "AirPods Case" and "Office’s Magic Keyboard" / "office's magic keyboard". The name still has a curly apostrophe, so the apostrophe-insensitive de-dup is still tested; one expected order changed to match the new name.
10. **Fixture helpers.** `FixtureDefaults` (Windows) and `FixtureCleanup` plus the temp-path suite (Clipboard) are removed. Both features now use `SnapshotFixtures.defaults()`. Snapshots checked: Windows panel (light and dark), Windows settings, Clipboard panel, Clipboard settings, clipboard popup, Dock preview. `--check-clipboard` passes.

Snapshots are in the session scratchpad under `final-wave/`.

## Incident: the debug build ran as an app for about 10 minutes
While checking item 9 I ran `.build/debug/Orbit --help` to look for a usage line. No debug mode handles `--help`, so the binary fell through to `app.run()` and started as a full app at 03:17:44 local (log: `Orbit launched`, then starting system, displays, shelf, wallpaper, controls). It used the unbundled binary's own `Orbit` defaults domain, not `com.kevo.orbit`. A direct `kill` was denied, so I stopped the background shell task that owned it, around 03:28. Because it was killed, `stopAll()` never ran. Kevo's `/Applications/Orbit.app` (pid 68762) kept running throughout.

What I checked afterwards:
- `orbit.log` has no `wallpaper:` or `displays:` lines from that run, so it set no desktop picture and wrote no gamma or software-dim value.
- `~/Library/Application Support/Orbit` does not exist, so Wallpaper's `removeUnused` had no stills folder and deleted nothing.
- `com.kevo.orbit.plist` was last modified on Oct 20.
- `~/Library/Preferences/Orbit.plist` (an empty dictionary, 42 bytes) has an mtime of 03:17, so that run created or touched it. I don't know whether it existed before, so I left it alone.

While it ran it may have shown a second Orbit menu bar icon, possibly the Welcome window, a second drag watcher and the Grab Text hot key; all of that ended when it was stopped. Every later binary call used only the documented snapshot and check flags.

## Concerns and things not done
- **Item 2 fallback:** with the new mode applied `.permanently`, `CGRestorePermanentDisplayConfiguration` restores the new mode, so the fallback can no longer revert anything. It was kept per the ruling. The resolution flow has not been run on hardware.
- **Item 3 side effect:** a resolution change from the Displays tab now closes the panel, because the screen parameters change. The floating confirm card stays up and is key.
- **Item 1:** ⌘Q now also quits Orbit from Settings and the editors (through the main menu's Quit). The key handling was verified in a probe, not in the running app.
- **Items 1, 3 and 6** were not exercised live: the app was not deliberately launched in this wave. (Controller's correction: the debug build did run as a full app once by accident, about 03:17–03:28, when `.build/debug/Orbit --help` was tried; see the Summary of `docs/suite/REPORT.md`.)
- **Left alone:** `Tests/OrbitCoreTests/SoundTests.swift:272` still has "Kevo's AirPods Pro", because the Sound agent is working in parallel. Controls (`fixtureModel`) and System (`SystemFixtures.throwawayDefaults`) still make their own temp-path suites; they weren't on the list.
