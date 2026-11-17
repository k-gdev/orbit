# Controls (Task 14, spec §8): implementer report

**Status: DONE.** Branch `suite/controls` (base `1a84988`), 9 commits, not pushed (per instructions).
All 18 changed files are inside the owned folders. **No shell changes.**

> Note: this report was meant to go to `suite-77e4bb/docs/suite/reports/controls.md`, but the agent
> harness refused writes outside this agent's own worktree. It lives in the scratchpad instead, for the
> controller to copy into place.

| Commit | Subject |
|---|---|
| `97d60da` | feat(controls): Keep Awake modes, sessions, expiry and labels |
| `1ba6476` | feat(controls): Keep Awake engine that releases its assertions on every exit |
| `792691f` | feat(controls): download detection and quick toggle restore records |
| `2559f89` | feat(controls): eject filter and Grab Text result formatting |
| `812ad8d` | feat(controls): Vision text and barcode recognition for Grab Text |
| `bc032ea` | feat(controls): persisted Controls settings |
| `3c991a1` | feat(controls): until-time occurrence and Focus Shortcut list parsing |
| `ebbe4f4` | feat(controls): Controls tab with Keep Awake, Quick Toggles and Grab Text |
| `9b2bf06` | fix(controls): re-read Screen Recording when the Controls tab opens |

Test summary: `swift test` passes **595 tests in 33 suites** (547 before + **48 new Controls tests in 8 suites**).
`swift build -c release --arch arm64 --arch x86_64` succeeded; `lipo -info` shows `x86_64 arm64`.

---

## What was built

### Keep Awake (replaces Amphetamine)
- Modes: Indefinitely; 15 min / 1 h / 2 h / 5 h / Custom (default 45 min, set in Settings, 1 min to 24 h); Until a time (an inline hour:minute picker in the tile; a time already past today means tomorrow); While an app runs (submenu of running regular apps); While downloading.
- Uses `IOPMAssertionCreateWithName` with `PreventUserIdleSystemSleep`, plus `PreventUserIdleDisplaySleep` when "display stays on" is on. The assertion name is "Orbit Keep Awake". The display option applies live to a running session.
- `KeepAwakeEngine` (OrbitCore) holds exactly the assertions the session needs, behind a `PowerAsserting` protocol. Every exit releases them: `stop()`, `evaluate` finding the session expired, and the engine's `deinit`. Switching modes keeps the one system assertion, with no gap and no duplicate. The app's `IOPMAsserter` is the real backend; tests use a fake that only records.
- `KeepAwakeController` (app) has one thing that ends each kind of session:
  - Timed sessions: one timer that fires at the deadline.
  - While downloading: a 10 s poll of `~/Downloads`, run only in that mode.
  - While an app runs: `NSWorkspace.didTerminateApplicationNotification`.
  - All modes: `didWakeNotification`, so a Mac that slept past the deadline ends the session on wake. (Run-loop timers pause during sleep.)
- Nothing runs while Keep Awake is off.
- Releases on stop, expiry, the feature's `stop()`, and quit (`FeatureRegistry.stopAll` calls `stop()`).
- Indicator: `context.setStatusIndicator("controls.keepAwake", active:)` follows the session and is cleared in `stop()`.
- The tile shows the time remaining ("1 h 12 m left · display stays on") through a `TimelineView` that only ticks while the panel is visible.
- When a session ends by itself, a toast says why ("Time's up." / "Xcode quit." / "Downloads finished.").

### Quick Toggles
All toggles are in a 2-column grid of Control Center–style buttons: a round glyph that turns accent when on, plus the title and the live state.

| Toggle | Read | Set | Permission |
|---|---|---|---|
| Dark Mode | `CFPreferencesCopyValue("AppleInterfaceStyle", AnyApplication)` | SkyLight `SLSSetAppearanceThemeLegacy(bool)` via `PrivateSymbol`, then waits up to 1 s for the preference to follow, else an error toast | none |
| Hide Desktop | `com.apple.finder CreateDesktop` (CFPreferences) | `CFPreferencesSetAppValue` + synchronize + read-back check, then Finder relaunch (SIGTERM like `killall Finder`; Orbit opens Finder itself if it isn't back after 1.5 s) | none |
| Hidden Files | `com.apple.finder AppleShowAllFiles` (handles bool / number / "YES" string) | same as Hide Desktop | none |
| Night Shift | CoreBrightness `CBBlueLightClient getBlueLightStatus:` (byte 1 = enabled), class reached via `PrivateSymbol.exists` + Obj-C runtime | `setEnabled:` + read-back check | none |
| Do Not Disturb | **no state read** (an action button) | `/usr/bin/shortcuts run "<user's Shortcut>"` | none |
| Eject Drives | `FileManager.mountedVolumeURLs` → `EjectableVolumeFilter` | in-panel confirmation tile, then `NSWorkspace.unmountAndEjectDevice` on a background queue; toast summary | none |
| Mute Mic | `context.micMute.isMuted / isAvailable` | `context.micMute.toggle()` (public API only; `MicMuteService.swift` untouched) | none |

- **No toggle needs Automation**, so nothing was added to the Features page or `SuitePermission`.
- Restore: `QuickToggleRestoreBook` (persisted in `ControlsSettings`) records the prior value when Orbit turns a toggle on. Turning it off writes exactly that value back; for example, Finder's `CreateDesktop` key is *removed*, not set to `true`. If something else changed the setting in between, the record is stale and dropped, and Orbit writes the plain "off" value.
- States are read on `panelDidAppear`. While the panel is open, the model follows `AppleInterfaceThemeChangedNotification`, mount/unmount and app launch/quit, and stops when the panel closes.
- The UI says Finder restarts (a footnote under the grid, and the toggle summaries in Settings).
- Unavailable toggles (no SkyLight symbol, no Night Shift support, no drives, no microphone) are dimmed and disabled with the reason as their subtitle.

### Grab Text (replaces TextSniper)
- Triggered by the global shortcut ⇧⌘2 (`KeyCombo.grabTextDefault`, HotKeyCenter id `controls.grabText`) or the Grab Text tile in the panel.
- Flow:
  1. Screen Recording is checked through `context.permissions` at grab time. If it isn't granted, `PermissionCenter.request(.screenRecording)` is called and an explanatory toast is shown (first use only). Nothing is prompted at enable time.
  2. A crosshair overlay appears: one borderless `.screenSaver`-level window per display, slightly dimmed, with the selection cut out and a size badge. Esc, a click without a drag, or switching apps cancels.
  3. `SCScreenshotManager.captureImage` captures the rectangle at the display's `pointPixelScale`, without the cursor, excluding Orbit's own app (so the overlay never shows in the capture).
  4. `TextRecognizer` (OrbitCore) runs Vision `VNRecognizeTextRequest` (accurate, `automaticallyDetectsLanguage`, language correction) and `VNDetectBarcodesRequest` in one pass, on a detached task.
  5. Lines are put in reading order, copied to `NSPasteboard`, and shown through the **existing** `ToastCenter` HUD: "Copied N lines", with the first line as detail.
- A QR code or barcode payload wins ("Copied code" / "Copied N codes"). With nothing found, the toast says "No text found" and the pasteboard is left alone.
- Registration failure is surfaced in Settings next to the recorder: "In use by another app" (TextSniper), or "Already used by Clipboard / Mute microphone" for Orbit's own ids.

### Settings page
The Keep Awake section has the display-awake option and the custom-duration stepper, with a footnote about pmset and lid close.

The Shortcuts section has two recorders:
- Grab Text, with its conflict message.
- The shared mic mute shortcut (`MicMuteSettings`). It's shown here too because mic mute works with Sound off.

The Do Not Disturb section has a Shortcut picker filled from `shortcuts list`, plus Open Shortcuts and an explanation. Quick Toggles has one checkbox per toggle for visibility in the tab.

### Files
- `Sources/OrbitCore/Controls/`: `KeepAwake.swift` (mode, session, engine, format), `DownloadActivity.swift`, `QuickToggles.swift` (ids, `PreferenceValue`, restore record/book), `EjectableVolumes.swift`, `GrabText.swift` (result, reading order), `TextRecognizer.swift`, `FocusShortcut.swift`, `ControlsSettings.swift`.
- `Sources/OrbitApp/Features/Controls/`: `ControlsFeature.swift` (replaces the stub; same class name and `init(context:)`), `ControlsModel.swift`, `ControlsPanelView.swift`, `ControlsSettingsView.swift`, `KeepAwakeController.swift` (+ `IOPMAsserter`), `QuickToggleService.swift` (+ `AppearanceSwitch`, `FinderPreferences`, `NightShiftClient`, `ShortcutsRunner`, `VolumeLister`), `GrabTextOverlay.swift`, `GrabTextCapture.swift`, `GrabTextController.swift`.
- `Tests/OrbitCoreTests/ControlsTests.swift`.

---

## Tests and TDD evidence

`Tests/OrbitCoreTests/ControlsTests.swift` contains 8 suites and 48 tests. Every brief-named test exists:

- **KeepAwakeTests:** `expiresAtDeadline`, `indefiniteNeverExpires`, `untilTimeLabel`, `whileAppRunningExpiresWhenAppQuits`, `whileDownloadingFollowsDownloads`, `remainingLabels`, `durationTitles`, `modeRoundTripsThroughJSON`, `resumeMode`, `modeTitles`. Engine tests with a fake asserter: `engineReleasesAtDeadline`, `engineReleasesOnStopAndDeinit`, `engineFollowsDisplayOption`, `engineEndsWithAppOrDownloads`, `engineRefusedByMacOS`.
- **DownloadActivityTests:** `downloadSuffixes`, `watchBridgesShortGaps`.
- **QuickToggleTests:** `togglesInOrder`, `preferenceParsing`, `onMeaning`, `restoreRecordsPriorState`, `staleRecordFallsBackToPlainOff`.
- **EjectTests:** `ejectableFiltersInternalAndNetwork` uses the volumes really mounted on Kevo's Mac as fixtures, including the CoreSimulator runtime images, which report removable+ejectable and must never be ejected. Also `confirmationAndSummaryText`.
- **GrabTextTests:** `hudLineCounts`, `barcodeWins`, `readingOrder`. Also `recognizesRenderedText` (real Vision OCR on Core Text rendered lines), `detectsQRPayload` (real Vision on a generated QR, via `Fixtures.qr`) and `blankImageFindsNothing`.
- **ControlsSettingsTests:** `settingsRoundTrip`, `badStoredValuesFallBack`. Both use `Fixtures.defaults()`, an absolute-path temp suite.
- **ControlsHelperTests:** `untilPicksNextOccurrence`, `shortcutListParsing`.

Each unit followed the same cycle: tests written, then `swift build --build-tests` (RED), then implementation, then `swift test --filter ControlsTests` (GREEN), then full `swift build` + `swift test`, then commit. The RED/GREEN outputs per unit:

| Unit | RED (`swift build --build-tests`) | GREEN (`swift test --filter ControlsTests`) |
|---|---|---|
| Keep Awake session | `error: cannot find type 'KeepAwakeSession' in scope` | `✔ Test run with 10 tests in 2 suites passed` |
| Engine | `error: cannot find type 'PowerAsserting' in scope` | `✔ Test run with 15 tests in 2 suites passed` |
| Downloads + restore | `error: cannot find 'DownloadActivity' in scope` | `✔ Test run with 22 tests in 4 suites passed` (after moving mutating calls out of `#expect`) |
| Eject + Grab Text result | `error: cannot find type 'VolumeInfo' in scope` | `✔ Test run with 27 tests in 6 suites passed` |
| Text recognizer | `error: cannot find 'TextRecognizer' in scope` | `✔ Test run with 30 tests in 6 suites passed after 1.066 seconds` |
| Settings | `error: cannot find 'ControlsSettings' in scope` | `✔ Test run with 32 tests in 7 suites passed` |
| Until/Shortcut helpers | `error: type 'KeepAwakeMode' has no member 'nextOccurrence'` | `✔ Test run with 34 tests in 8 suites passed` |

**Full-suite flakes under load (not Controls):** during this session the machine's load average was about 74, with seven agents building and testing at once. Three full runs each failed exactly one pre-existing timing or hardware test:
- `VideoToolTests.compressMKV`: the VideoToolbox encoder refused (`err=-12903`).
- `VideoToolTests.compressFits`
- `ProcessTests.cancellationTerminates`: took 5.5 s against a 3 s limit.

Each passed when re-run alone (`swift test --filter compressMKV` passed in 22.6 s; `--filter compressFits` passed). The final runs at commits `bc032ea`, `812ad8d`, `ebbe4f4` and `9b2bf06` were fully green: `✔ Test run with 595 tests in 33 suites passed`.

---

## Current toggle states read on Kevo's Mac (read-only, 2026-10-28 ~00:48)
- Dark Mode: **on**. `AppleInterfaceStyle = Dark`; `AppleInterfaceStyleSwitchesAutomatically` is not set, so the appearance is not on Auto. `SLSGetAppearanceThemeLegacy()` also returned `true`.
- Desktop icons: **shown**. `com.apple.finder CreateDesktop` is not set.
- Hidden files: **not shown**. `com.apple.finder AppleShowAllFiles` is not set.
- Night Shift: **off**. `getBlueLightStatus:` returned active=1, enabled=0, sunSchedulePermitted=1, mode=0 (no schedule), stored schedule 22:00–07:00, available=1. `supportsBlueLightReduction` = true.
- Focus / DND: unknown. `~/Library/DoNotDisturb/DB` returns "Operation not permitted" from my shell.
- Shortcuts: `shortcuts list` returns only **"Send Message"**. No Focus Shortcut exists yet.
- Ejectable drives: **none**. Mounted are only system volumes, the autofs `home` and two CoreSimulator runtime images under `/Library/Developer/CoreSimulator/Volumes`, which the filter correctly excludes.
- Power: `caffeinate` (pid 41252) is holding PreventUserIdleSystemSleep; Orbit holds nothing.
- Private symbols present on macOS 26.5: `SLSSetAppearanceThemeLegacy`, `SLSGetAppearanceThemeLegacy`, `SLSSetAppearanceThemeNotifying` and `OBJC_CLASS_$_CBBlueLightClient` (which responds to `getBlueLightStatus:` and `setEnabled:`).
- After the build, the Finder and global preference plists still show their Oct 27 evening modification times, and the three values above are unchanged.

## Do Not Disturb: shipped, as an action button
macOS has no public API to set or read Focus. The reliable route is a Shortcut the user picks (with the "Set Focus" action) that Orbit runs with `/usr/bin/shortcuts run <name>`. That works with no permission and needs no private API, so it ships.

There is **no state read**. The only source would be `~/Library/DoNotDisturb/DB/Assertions.json`, which is undocumented and TCC-protected (not readable from my shell). So the button is an action, not a toggle:
- With a Shortcut chosen, it says "Runs your Shortcut" and shows a "Ran “…”" toast.
- With none chosen, it says "Choose a Shortcut" and opens Settings → Controls.

Kevo currently has no Focus Shortcut, so he needs to create one; the Settings section explains how and has an Open Shortcuts button.

---

## [builder's call]s
1. **Indicator id** `"controls.keepAwake"`, following the `SuiteContext` doc example. The ruling said `"keepAwake"`; the id is only the asker's name.
2. **Section header "Sleep"** above the Keep Awake tile, to avoid "KEEP AWAKE / Keep Awake" twice. Headers "Quick Toggles" (with a "Customize" link to Settings) and none above the Grab Text tile.
3. **Quick toggles are not reverted on quit or disable.** They are system settings the user chose, like Control Center switches. The restore records persist, so turning a toggle off after a relaunch still restores the exact earlier value. Keep Awake (assertions) and the mic (via `MicMuteService`) *are* released and restored on stop and quit.
4. **Dark mode via SkyLight only, with no System Events fallback.** That avoids Automation and the `SuitePermission` shell change. If the symbol is missing, the toggle shows "Not available". If the call doesn't change the preference within 1 s, an error toast says so.
5. **Finder relaunch** uses SIGTERM (the `killall Finder` behaviour, no Apple Event, so no Automation), then opens Finder if it hasn't come back after 1.5 s.
6. **"While downloading"**: included. It polls the top level of `~/Downloads` every 10 s, only in that mode, for `.download`, `.crdownload`, `.part`, `.partial` and `.opdownload`. A 20 s grace bridges the gap between consecutive downloads. It refuses to start, with a toast, when nothing is downloading.
7. **Resume rule for the switch**: it restarts the last mode if that mode is indefinitely, a duration, or an until-time still ahead; otherwise it starts indefinitely. App and download modes are only started from the menu. Re-choosing a duration restarts its timer.
8. **Remaining-time format** rounds up to whole minutes ("1 h 12 m left", "2 h left", "1 m left"). Until labels use the user's clock format and add the weekday for another day.
9. **A toast when Keep Awake ends by itself**, with the reason.
10. **Eject filter**: the volume must be under `/Volumes/`, local, browsable and not the root filesystem, **and** at least one of ejectable, removable, or internal == false. Unknown "internal" alone is never enough. This excludes the CoreSimulator images (non-browsable, outside `/Volumes`), network shares, and internal partitions. A single drive gets "Eject “Name”?"; several get "Eject N drives?" with their names.
11. **Barcode HUD**: "Copied code" / "Copied N codes". Payloads are trimmed and de-duplicated, and the first line is previewed in the toast detail. "No text found" leaves the pasteboard untouched.
12. **Reading order**: rows are grouped by at least 50 % vertical overlap, top to bottom, left to right within a row, and joined by a space.
13. **`TextRecognizer` lives in OrbitCore**, not the app, so OCR and barcode detection are unit-tested on rendered images. Vision is already used there by `QRReader`.
14. **Overlay**: a 22 % black veil, a white 1 pt selection border and a size badge. A drag smaller than 4 pt, or a click, cancels; switching apps cancels. A selection stays on the display where it started.
15. **Screen Recording not granted**: the request goes through `PermissionCenter`, with a toast telling Kevo to allow it and possibly reopen Orbit. The panel tile's subtitle says "Asks for Screen Recording the first time" until it's granted. The permission is re-read without a prompt when the tab opens.
16. **A custom accent `PanelSwitch`** for Keep Awake, because AppKit's switch draws grey whenever the panel isn't the key window. It is private to `ControlsPanelView.swift`.
17. **The mic mute shortcut recorder is repeated** on the Controls settings page, since mic mute works with Sound off.
18. **Custom duration stepper** goes in 5-minute steps; the range is clamped to 1 min–24 h in `ControlsSettings`.
19. **Toggle titles describe "on"**: "Hide Desktop", "Hidden Files", "Mute Mic". Symbols: `circle.lefthalf.filled`, `menubar.dock.rectangle`, `eye` / `eye.slash`, `sun.horizon.fill`, `moon.fill`, `eject.fill`, `mic.fill` / `mic.slash.fill`.

## Shell changes
**None.** I used only the public shell APIs: `SuiteFeature`, `SuiteContext.setStatusIndicator`, `hotKeys`, `permissions`, `micMute` (public API only), `toasts`, `closePanel`, `openSettings`, `PrivateSymbol`, `PanelTile`/`PanelSectionHeader`/`PanelLinkButton`/`PanelMenuButton`/`PanelStyle`, `KeyComboRecorder`, `SettingsSection`.

**Optional suggestion for the controller (not done):** add `NSDownloadsFolderUsageDescription` to `Support/Info.plist`. Without it, a first "While downloading" session shows macOS's generic Downloads-folder prompt if Orbit doesn't already have Full Disk Access. It's user-initiated, so this is cosmetic.

## Safety log (unattended rule)
- I flipped no toggle and wrote no Finder or global defaults.
- I did not relaunch Finder, change Night Shift, run any Shortcut, eject anything, or mute the mic.
- I held no power assertion: the engine tests use a fake asserter, and snapshots use a fixture controller with no engine.
- The crosshair overlay was never shown.
- I never launched the built app; I only used `--snapshot-panel` / `--snapshot-settings-page`.
- Read-only probes, all scratch binaries under the scratchpad:
  - `defaults read`
  - `pmset -g assertions`
  - `shortcuts list`
  - `dlsym` lookups
  - `getBlueLightStatus:`, a getter
  - `class_copyMethodList`
  - `mountedVolumeURLs` resource values
- **Preferences**: tests use `Fixtures.defaults()`, an absolute-path temp suite. The snapshot fixture uses an absolute-path temp suite and only `register(defaults:)` (memory-only), so it never writes. No `~/Library/Preferences/*.plist` was created by my runs; a listing shows nothing new related to Orbit or Controls.
- **Scratchpad note:** the scratchpad is shared with other agents. My first probe file, `scratchpad/probe/probe.swift`, was later overwritten by another agent's Core Audio probe. My later files are prefixed `controls-`.

## Snapshots checked (light and dark; not committed)
In `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/snaps/`:
- `controls-panel-light.png` and `controls-panel-dark.png`: the final fixture. Keep Awake 48 min into 2 h, display on, dark mode on, one drive, a Focus Shortcut chosen.
- `controls-panel-variant-light.png` and `controls-panel-variant-dark.png`: from a temporary, reverted fixture. Keep Awake off, mic muted, desktop hidden, and the eject confirmation open.
- `controls-settings-light.png` and `controls-settings-dark.png`: the top of the page.
- `controls-settings-lower-light.png` and `controls-settings-lower-dark.png`: from a temporary, reverted reorder, showing the Do Not Disturb picker and the Quick Toggles checkboxes.

The tab follows the gallery's look: translucent 12 pt tiles, round accent glyphs, the capsule menu button and small-caps headers. It fits about 480 pt of content without scrolling.

## Needs hardware verification (could not be tested unattended)
1. **Dark Mode** via `SLSSetAppearanceThemeLegacy`: the symbol is present on 26.5, but flipping it was not allowed. Check that it switches the whole system and that `AppleInterfaceStyle` follows; otherwise the toggle shows an error toast. Also check the Auto appearance setting.
2. **Night Shift** `setEnabled:`: check that it matches the Control Center switch (my reading is that `enabled`, byte 1, is the switch).
3. **Finder**: check that the `CreateDesktop` / `AppleShowAllFiles` writes take effect after the SIGTERM relaunch, that Finder comes back, and that turning off removes the key (`defaults read` should say "does not exist").
4. **Keep Awake**: check that `pmset -g assertions` shows "Orbit Keep Awake" (plus the display assertion), and that it disappears on expiry, on the switch, on disabling Controls, on Quit, and after "While an app runs" when that app quits. The wake-after-deadline path needs a real sleep.
5. **"While downloading"**: run with a real Safari or Chrome download, and check the Downloads-folder TCC behaviour.
6. **Grab Text**:
   - The overlay on all four displays: the mixed 6016×3384 HiDPI and 2560×1440 framebuffers.
   - The `sourceRect` mapping on non-main displays.
   - Esc focus.
   - The Screen Recording first-use flow (macOS may require a relaunch).
   - Whether ⇧⌘2 conflicts with TextSniper if it is still running. Carbon may or may not refuse; if TextSniper uses an event tap, both could fire.
7. **Eject**: test with a real external drive and a DMG, including the "in use" failure toast.
8. **Mic Mute**: works once the Sound agent's `MicMuteService` hardware code lands. With the stub, the button shows "No microphone", as designed.
9. **Do Not Disturb**: create a "Set Focus → Do Not Disturb → Toggle" Shortcut, pick it in Settings, and run it from the panel.

## Known gaps
- Do Not Disturb has no live on/off state (see above).
- The Keep Awake session does not survive a relaunch of Orbit (the assertion dies with the process anyway); the last mode is remembered for the switch.
- There's no notification-centre banner when a session ends, only Orbit's toast.
- Grab Text selects within a single display (no drag across displays).
- The Settings snapshot is clipped at the window height, so its lower sections were checked through a temporary reorder rather than a scroll.

---

## Fix round 1 (task review)

Branch `suite/controls`, 4 new commits on top of `9b2bf06`, not pushed:

| Commit | Subject | Review items |
|---|---|---|
| `70252ea` | fix(controls): core decisions for the review fixes | Core + tests for every item below |
| `5e3b582` | fix(controls): Grab Text keeps the user's app focused | I1 |
| `5658dcf` | fix(controls): Keep Awake re-arms its timer, reads Downloads off main, admits a refused display assertion | M1, M8, M9 |
| `4c9352e` | fix(controls): quick toggles restore exactly and never block the panel | M2, M3/M4, M6, M7, M13 |

M1/M8/M9 share `KeepAwakeController.swift`, and M2/M3/M6/M7/M13 share `ControlsModel.swift` and `QuickToggleService.swift`. Each of those two commits therefore covers several items, and its message lists them one by one. No partial staging was available non-interactively.

(c) Quick toggles are not reverted on disable or quit. This is unchanged, per the controller's ruling (builder's call #3 stands).

### What changed

**I1, Grab Text focus.**
- The crosshair windows are now `NSPanel`s with `[.borderless, .nonactivatingPanel]`, `becomesKeyOnlyIfNeeded = false`, `hidesOnDeactivate = false`, `canBecomeKey = true`, and are shown with `makeKeyAndOrderFront`.
- `NSApp.activate(ignoringOtherApps:)` is **removed**. The panels take the keyboard without making Orbit the active app, so the user's app keeps focus and the next ⌘V lands there.
- Esc cancels three ways: a local `keyDown` monitor (no permission needed; a global monitor would need Accessibility), the panel's `keyDown` / `cancelOperation`, and the view's `keyDown`.
- A click without a drag, a right-click, another app activating (`didActivateApplicationNotification` for any app other than Orbit or the previous one) and Orbit resigning active all cancel.
- In `finish()`, `GrabTextFocus.afterOverlay(previousWasOrbit:orbitIsActive:previousAvailable:)` decides what happens next:
  - If Orbit did become active, the previous app is reactivated (`activate(options: [])`).
  - If that app is gone, Orbit hides itself.
  - If Orbit was already in front, for example with Settings open, it is left alone.

**M1, timer re-arm.**
- `KeepAwakeSession.nextCheck(now:)` returns the deadline while it is still ahead, and nil when the session is due or untimed.
- When `check()` finds a timed session not yet expired (the timer fired early because the clock moved), it re-arms the single timer for `nextCheck`.
- An `NSSystemClockDidChange` observer was added next to the wake observer, so a clock change re-checks at once.
- Observers are now stored as center/observer pairs and all removed in `stopWatching()`.

**M3/M4, no Finder restart for nothing.**
- `setToggle` re-reads the live value. If it already matches the requested state, the model refreshes the button and returns: no write and no SIGTERM.
- In Core, `change(on: false)` for an already-off setting returns the current value and drops any leftover record.
- The panel footnote now reads "Hide Desktop and Hidden Files restart Finder, which stops any Finder copy in progress." The Settings footnote says the same.

**M2, records with two toggles in flight.**
- `QuickToggleRestoreBook.change(_:on:current:automatic:)` is pure: it returns `QuickToggleChange(write, automatic, record)` without touching the book.
- After a successful write, `commit(_:_:)` stores the record into `settings.restoreBook` *as it is then*, a mutation in place on the published property. So a second toggle that finishes first is never overwritten.
- On a failed write, nothing is committed. `turnOn`/`turnOff` remain as `change` + `commit` wrappers.

**M13, Dark Mode and Auto.**
- `QuickToggleRestore` gained `priorAutomatic: Bool?`. It is optional, so old records still decode; a test covers that.
- Turning Dark Mode on while the appearance is on Auto plans `automatic: false`, records `priorAutomatic: true`, and turns Auto off first, as System Settings does when you pick Light or Dark, so the choice sticks.
- Turning it off restores the prior theme, verifies it, then turns Auto back on (`automatic: true`).
- Auto is read through SkyLight `SLSGetAppearanceThemeSwitchesAutomatically` (falling back to the `AppleInterfaceStyleSwitchesAutomatically` preference) and set through `SLSSetAppearanceThemeSwitchesAutomatically`, both via `PrivateSymbol`. A read-only probe confirmed both symbols exist on macOS 26.5; Auto is currently **off** on Kevo's Mac.
- The button shows "On · Auto" or "Off · Auto" while Auto is on.

**M6, volumes off main.**
- `VolumeLister.ejectable()` is now `async` and runs in `Task.detached(priority: .utility)`.
- It reads the kernel mount table with `getmntinfo_r_np(…, MNT_NOWAIT)`, which is cached, thread-safe and never waits on a server.
- `EjectableVolumeFilter.worthInspecting([MountEntry])` (Core, tested) keeps only local `/Volumes/…` mounts *before* any `URLResourceValues` read. Network mounts are never statted.
- The model's `refreshVolumes()` cancels a listing still running and replaces it. The live observers are split: theme changes refresh the toggles, mount/unmount refresh the volumes, and app launch/quit refresh the running-app list.
- A read-only probe of the mount table on this Mac shows the autofs `home` flagged remote and no local `/Volumes` mounts, so the result is no drives, which is correct.

**M8, Downloads.**
- `~/Downloads` is listed in `Task.detached` both when a "While downloading" session starts and on each 10 s poll. The poll skips a run while one is still in flight, and ignores a result that arrives after the session changed.
- The start path is asynchronous: `start(.whileDownloading)` returns at once, then starts the session or shows the "Nothing is downloading" toast when the listing returns.
- The mode menu now has a line under "While Downloading": "macOS may ask to let Orbit see your Downloads folder".
- **Shell change (allowed by the controller):** `Support/Info.plist` gains `NSDownloadsFolderUsageDescription` = "Orbit checks your Downloads folder for unfinished downloads while Keep Awake is set to “While downloading”." It sits alphabetically after `NSAudioCaptureUsageDescription`, and `plutil -lint` reports OK.

**M7, Shortcut timeout.**
- `FocusShortcut.timeout = 15` and `FocusShortcut.withTimeout(_:_:)` are in Core. The helper is a throwing task group racing the operation against a sleep. On timeout it throws `FocusShortcut.TimedOut` and cancels the operation; `ProcessRunner` then terminates the child.
- `ShortcutsRunner.run` and `.list` use it. The button can no longer sit on "Working…" forever; a timeout shows "“X” took too long: Orbit stopped it after 15 seconds."

**M9, refused display assertion.**
- `KeepAwakeEngine.holdsDisplayAssertion` reports what macOS actually granted. `session.keepDisplayAwake` stays what the user asked for.
- The controller publishes `displayHeld`. The tile uses `KeepAwakeFormat.status(_:now:displayHeld:)` (Core, tested), which says "· display can still sleep" instead of "· display stays on" when the display assertion was refused.

### Tests (Core, `ControlsFixRound1Tests`, 9 new)
- `rearmsWhenTimerFiresEarly`, `engineReportsRefusedDisplayAssertion`, `statusLineTellsTheTruth`.
- `turnOffWhenAlreadyOffChangesNothing`, `concurrentChangesKeepBothRecords`, `darkModeRestoresAuto` (includes legacy-record decoding).
- `skipsNetworkMountsBeforeReadingThem`.
- `shortcutRunTimesOut`: the helper with `Task.sleep`, plus a real `/bin/sleep 30` process cut off at 0.3 s.
- `focusGoesBackAfterOverlay`.

`FakeAsserter` gained `refuseKinds` so that it can refuse just the display assertion.

### Commands and output
- RED: `swift build --build-tests` failed with `value of type 'KeepAwakeSession' has no member 'nextCheck'`, `value of type 'QuickToggleRestore' has no member 'priorAutomatic'`, `type 'FocusShortcut' has no member 'withTimeout'`, `type 'FocusShortcut' has no member 'TimedOut'`, `type 'EjectableVolumeFilter' has no member 'worthInspecting'` (and more of the same).
- GREEN (Core, before the app changes): `swift test --filter ControlsTests` → `✔ Test run with 43 tests in 9 suites passed after 0.526 seconds.`
- After all four commits, `swift test --filter Controls` → `✔ Suite ControlsFixRound1Tests passed after 0.528 seconds.` / `✔ Test run with 43 tests in 9 suites passed after 0.528 seconds.`
- Full suite, once: `swift test` → `✔ Test run with 604 tests in 34 suites passed after 81.715 seconds.` This time no load flakes appeared.
- `swift build` produced no warnings or errors at each commit.
- Release: `swift build -c release --arch arm64 --arch x86_64` → `Build complete!` (exit 0); `lipo -info` reports `x86_64 arm64`. The new `getmntinfo_r_np` / `statfs` code compiles for x86_64.

**Correction to the original report:** the baseline at `1a84988` was **561** tests, not 547 (the shell had added tests since the brief was written). So the original Controls work added **34** tests in 8 suites, not 48. With this round, Controls has **43 tests in 9 suites**, and the suite total is 604.

### Snapshots (light and dark, checked)
All four are in `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/snaps/`:
- `controls-fix1-panel-light.png`
- `controls-fix1-panel-dark.png`
- `controls-fix1-settings-light.png`
- `controls-fix1-settings-dark.png`

The panel is unchanged apart from the two-line Finder footnote, which wraps cleanly. The tile still reads "1 h 12 m left · display stays on", because the fixture's display assertion is held.

### Unattended rule
Nothing was flipped, written, ejected, muted, asserted or overlaid. The new probes were read-only and used scratch binaries:
- `controls-probe-auto` used `dlsym` and the Auto getter.
- `controls-probe-mounts` read the mount table.

### Still needs hardware verification (additions)
- That the non-activating overlay panels take Esc and show the crosshair cursor while another app stays active, on all four displays.
- That `SLSSetAppearanceThemeSwitchesAutomatically` turns Auto off and back on as System Settings does.
- That a stale SMB share no longer stalls the panel (needs a real share).
