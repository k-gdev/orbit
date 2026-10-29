# Orbit Suite shell: report (Tasks 1–6 + controller scope additions)

Branch `claude/suite-77e4bb`, built on top of 4d97081 (plus the controller's docs commit 6d8f90c). Every
commit was pushed. `swift build` and `swift test` were green at each commit; one ffmpeg test flaked once
(see Concerns).

| Commit | Subject |
|---|---|
| 3428772 | feat(suite): feature, permission and settings model |
| ae0e183 | feat(suite): feature registry, permissions, hot keys |
| 35f12f4 | feat(suite): shared panel tiles and pill sliders |
| ec93cc3 | feat(suite): tabbed menu bar panel |
| 2a5e637 | feat(suite): settings window with side rail and Features page |
| 31f912f | feat(suite): headless panel and settings snapshots |
| e7bae9f | fix(suite): self-review fixes for snapshots, mic mute and permissions |

Tests: 547 → **561** (14 new in `Tests/OrbitCoreTests/SuiteTests.swift`), all passing.
Universal release build: `swift build -c release --arch arm64 --arch x86_64` → `Build complete!`; `lipo -archs`
reports `x86_64 arm64`. No compiler warnings in new or changed files (debug or release).

## What was built, per task

### Task 1: Suite model in OrbitCore (`Sources/OrbitCore/Suite/`)
- `FeatureID`: **eight** cases in tab order: sound, system, displays, windows, clipboard, shelf, wallpaper,
  **controls**. Each has `title`, `symbol`, `summary`, `permissions`, `isOnByDefault`, all with the brief's
  values verbatim. `controls` follows the controller's addition (symbol `switch.2`, on by default, Screen
  Recording "Grab Text captures the area you select", not requested on enable).
- `SuitePermission` (title, `settingsURL` with `Privacy_AudioCapture` / `_Accessibility` / `_ScreenCapture`) and
  `PermissionUse`.
- `SuiteSettings` (same idiom as `SettingsStore`): `enabledFeatures` stored at `suite.enabledFeatures` as raw values
  in tab order; unknown ids are dropped. Defaults: system, displays, shelf, wallpaper, controls. Also `lastTab`
  (`suite.lastTab`), `isEnabled`, `setEnabled`, `enabledInOrder`. An empty set persists as empty, not reset to the
  defaults.
- `KeyCombo`: `display` in ⌃⌥⇧⌘ order, `keyName(for:)` (letters, digits, punctuation, F1–F12, Space, ↩, ⇥, ⌫, arrows),
  `isUsableAsHotKey`, `micMuteDefault` (⌃⌥M/46), `clipboardDefault` (⇧⌘V/9), **`grabTextDefault` (⇧⌘2/19)**.
  `ModifierSet.symbols` moved here from `TriggerRecorder.swift` (now public) so KeyCombo can share it.
- `PillScale` (`hasBoost`, `boostStartFraction`, `fraction(for:)`, `value(forFraction:step:)`, `isBoosted`,
  `clamped`, `nudged`, `wheelStep`, `wheelNudged`) and `PillTrack` (fill width / pointer→fraction geometry), so
  all of the pill slider's math is tested.
- `SettingsPage` (`title`, `symbol`, `railOrder` = 12 pages, `argument`, `init?(argument:)`).
- **`MicMuteSettings`** (controller addition): `muteShortcut: KeyCombo`, key `micMute.shortcut` (JSON), default ⌃⌥M.

TDD evidence:
- RED: `swift test --filter SuiteTests` → exit 1; 257 compile errors, all "cannot find '…' in scope"
  (`FeatureID` ×28, `KeyCombo` ×52, `PermissionUse` ×2, `PillScale` ×6, `SettingsPage` ×28,
  `SuitePermission` ×8, `SuiteSettings` ×22).
- Controller additions RED: `swift test --filter SuiteTests` → exit 1, `cannot find 'MicMuteSettings' in scope` ×16.
- GREEN: `swift test --filter SuiteTests` → `✔ Test run with 12 tests in 2 suites passed`; then `swift test` →
  `✔ Test run with 559 tests in 25 suites passed`.
- Task 3's geometry got the same treatment: RED `cannot find 'PillTrack' in scope` ×6 and
  `value of type 'PillScale' has no member 'wheelStep'` ×8. GREEN: 14 tests in 2 suites; full run 561.
- Test names include `SuiteTests.SuiteSettingsTests/enabledSetRoundTrips()` (the Review Focus 4 name; the outer
  `SuiteTests` suite keeps `--filter SuiteTests` matching everything).

### Task 2: protocol, registry, permissions, hot keys (`Sources/OrbitApp/Suite/`)
- `SuiteFeature.swift`: the contract in a header comment (cheap side-effect-free `init(context:)`, idempotent
  `start`/`stop`, no work while off, `stop` releases everything, appear/disappear bracketing, fixture-only
  `snapshotViews()`, where persisted data goes). The protocol includes `init(context:)` (so the registry can build
  features from `featureType(for:)`), the default no-op appear/disappear, and a static `managesOwnScrolling`.
  `FeatureSnapshotViews`, `PanelMetrics` (390 wide, 12 inset, 366 content width, radius 18) and
  `\.panelContentMaxHeight` live here too.
- `SuiteContext` (ObservableObject): settings, suite, defaults, hotKeys, permissions, **micMute**, **toasts** (the
  coordinator's single `ToastCenter`, now internal instead of private), `supportDirectory` plus
  `directory(for:)` (creates `…/Orbit/<Title>/` lazily), `openSettings`, `closePanel`, and
  **`setStatusIndicator(_:active:)`** / `statusIndicators`.
- `FeatureRegistry`: `standard(context:)`, `featureType(for:)` (one switch), `feature(_:)`, `running`,
  `startEnabled()` (never prompts), `setEnabled` (refreshes, requests only `requestOnEnable` permissions that
  aren't granted, then starts; off stops), and `stopAll()`, which also calls `micMute.restoreOnQuit()`. After
  launch and after every toggle: `micMute.setActive(sound || controls)`.
- `PermissionCenter`: `statuses`, `status(_:)`, `refresh()` (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`,
  `TCCAccessPreflight("kTCCServiceAudioCapture")` through `PrivateSymbol`, unknown below 14.2 or when the symbol is
  missing), `request(_:)` (AX prompt, `CGRequestScreenCaptureAccess`, `TCCAccessRequest`; opens the pane when
  macOS won't prompt again) and `openSettings(_:)`. Statuses refresh on app activation, when Settings becomes key,
  when the Features or feature pages appear, and once a second for two minutes after a request (bounded).
  `init(live: false, fixed:)` gives snapshots a fixture.
- `PrivateSymbol.load(_:from:as:)` / `exists(_:in:)`: `dlopen(RTLD_LAZY)` handles cached under a lock; logs once
  per miss; refuses non-pointer-sized `T`.
- `HotKeyCenter`: Carbon `RegisterEventHotKey`. `register` returns false when another Orbit id owns the combo or
  macOS refuses it. The event handler exists only while at least one hot key does. Hot keys are suspended
  while a `KeyComboRecorder` records. Also `owner(of:)`, `combo(for:)`.
- `Suite/UI/KeyComboRecorder`: click, press, Esc cancels, rejects unusable combos with a hint, shows `conflict`.
- `DisplayIdentity.key(for:)` / `displayID(for:)` / `key(for screen:)` (ruling).
- **`MicMuteService`** (controller addition): `isMuted`, `isAvailable`, `setMuted`, `toggle`, `setActive`,
  `restoreOnQuit`, plus `fixture(muted:available:)` for snapshots. While active it registers hot key id `micMute`
  (re-registers when the shortcut setting changes) and shows a `mic.slash.fill` status item while muted (clicking
  it unmutes). The hardware section is a **no-op stub** marked `// MARK: Hardware — Implemented by the Sound task`,
  with notes on what to fill in; it never touches audio.
- Eight stubs `Features/<Name>/<Name>Feature.swift`, Controls included, each a placeholder tile ("Coming in this
  build") with idempotent start/stop and `snapshotViews()` returning the placeholders.
- `AppDelegate`: builds context and registry, creates the status item, wires `openSettings`/`closePanel`, then
  calls `startEnabled()`. `applicationWillTerminate` → `registry.stopAll()`. The Welcome window and its launch
  behaviour are untouched.
- `Info.plist`: `NSAudioCaptureUsageDescription` with the brief's text.

### Task 3: shared panel UI (`Sources/OrbitApp/Suite/UI/`)
`PanelTile`, `PanelSectionHeader`, `PanelLinkButton`, `PanelStyle` (light/dark colours, plus `accent(for:)`, which
lifts the accent 50 % toward white in dark), `PillSlider`, `PanelMenuButton`, `PanelRoundButton`,
`PanelRoundMenu`, `LevelBars`, `Stripes` and `PanelGallery` (every control in realistic use, added in Task 6).
`PillSlider` details:
- A capsule. The white fill is never narrower than its icon circle (Control Center style).
- Leading content sits inside the pill, with an optional `label` slot (app name + `LevelBars`). Value text is
  inside on the right and turns accent when boosted.
- Accent stripes run from `boostStart` to the end regardless of the fill; the filled part of the boost zone is
  tinted.
- Content is drawn twice (track ink, then fill ink masked to the fill), so it stays readable wherever the fill
  ends, in both modes.
- Input: drag anywhere sets the value; a mouse wheel nudges by `wheelStep`; a sideways trackpad swipe moves it
  continuously; VoiceOver can adjust it. `onLeadingTap` turns the leading content into a button.
- `onEditingEnded` fires on drag end and 0.35 s after scrolling settles. `isDimmed` gives the muted look.

### Task 4: menu bar panel (`Sources/OrbitApp/MenuBar/`)
- `MenuBarPanel`: borderless, `.nonactivatingPanel`, can become key, transparent, `.statusBar` level, Escape →
  close.
- `PanelHostingView` reports size changes so the panel follows its content, top-anchored.
- `MenuBarPanelController`:
  - Placement: centred under the status button, clamped to the visible frame. Content max height is the visible
    height minus chrome.
  - Tabs: kept in step with `enabledFeatures`; the last tab is remembered.
  - Appear/disappear: called on open, close and tab switch.
  - Closing: global and local mouse-down monitors plus a Space-change observer, installed only while open. The
    feature view is dropped on close.
- `PanelView` / `PanelModel`:
  - Tab row: icon over a small label; the selected tab sits on a white pill.
  - Content: wrapped in a measured scroll area (natural height up to the max, then it scrolls; heights are
    remembered per tab), or a fixed frame for features that manage their own scrolling.
  - Footer: Settings… (⌘,), Quit Orbit (⌘Q), and a … menu with Open Files…, Wheel enabled, Recent results and
    About Orbit.
  - Empty state when no feature is on.
- `StatusItemController`:
  - Left mouse-down toggles the panel; right or ⌃ mouse-down pops the existing menu, unchanged (attached only for
    that click). The button highlights while the panel is open.
  - **Indicator dot** (controller addition): a 6 pt accent dot subview on the icon while any
    `statusIndicators` entry is active. The template glyph and the busy dashed ring are unchanged.

### Task 5: Settings window (`Sources/OrbitApp/Settings/`)
- `SettingsWindowController.show(page:)`: 760×560 window with a full-size content view and transparent title bar.
  New autosave name `OrbitSettingsRail`, because the old frame was 560 wide.
- `SettingsRootView`: side rail (General, Wheel, Features section with eight pages marked "Off" when disabled,
  About) and the selected page. `SettingsDependencies` makes it renderable with fixtures.
- Pages:
  - General: launch at login, haptics, accent, Full Disk Access, Show welcome again.
  - Wheel: Enabled plus Triggers, Output, Copy & Move, Terminal, Helpers.
  - Features: a `FeatureCard` per feature with icon, summary, switch → `registry.setEnabled`, and each
    `PermissionUse` with a status badge, an "Optional" tag when not requested on enable, and Open System Settings.
    Sound shows a "needs macOS 14.2" note on older systems.
  - Feature pages: the same card, a note when the feature is off (settings stay editable), then
    `makeSettingsView()`.
  - About: version from the bundle, MIT licence, log path with Show in Finder, GitHub link.
- `SettingsView.swift`: the old page is split into `SettingsSection` (shared; feature pages should use it),
  `WheelSettingsSections`, `TriggerSettingsRows`, `OutputSettingsRows`, `FolderSettingsRows`,
  `TerminalSettingsRows`, `HelperSettingsRows` and `GeneralSettingsRows`. Every control is kept.
  `SettingsContent` composes them in the original order, so `--snapshot-settings` works unchanged (verified,
  same output as before, ImageRenderer placeholders included).

### Task 6: snapshots (`Sources/OrbitApp/Debug/`)
- `SnapshotRenderer.png(of:size:dark:)`: an offscreen, never-ordered-front borderless window at −20000,−20000
  hosting an `NSHostingView`. It runs six layout/run-loop passes, then `cacheDisplay` into a 2x bitmap under the
  right `NSAppearance`. Glass renders flat. Real AppKit controls draw: switches, checkboxes, sliders, pop-ups,
  colour well, lists, buttons.
- `SuiteSnapshot`:
  - `--snapshot-panel <feature|empty|gallery>`, `--snapshot-settings-page <page>`, `--snapshot-suite <dir>`.
  - Refuses to overwrite without `--replace` (the suite mode checks every target before writing anything),
    rejects non-.png output, and exits 64 on bad arguments.
  - Uses throwaway defaults in a temp folder and fixture permissions (Accessibility granted, the others not).
- `main.swift`: one line.

## Snapshot paths I looked at
All under `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/shell-shots/`
(the full set, 44 PNGs, is in `suite/`):
- `legacy-settings.png` (`--snapshot-settings`, unchanged behaviour)
- `try-panel-system.png`, `try-features.png` (first passes, which found the rail problem)
- `gallery-light.png`, `gallery-dark.png` (pill sliders, boost stripes, menu buttons, round buttons, level bars)
- `suite/panel-controls-dark.png`, `suite/panel-empty-light.png`, `suite/panel-displays-light.png`
- `suite/settings-wheel-light.png`, `suite/settings-general-light.png`, `suite/settings-sound-dark.png`,
  `suite/settings-about-dark.png`, `suite/settings-about-light.png` (cropped as `about-crop.png`)

What they showed: real controls everywhere; no yellow placeholders in the new modes. Eight tabs fit at 9.5 pt.
The gallery matches the mockup's feel: stripes appear past 100 even when the fill stops short (Discord 85 %,
Music 60 %), with a tinted fill for Chrome 130 % and the ThinkVision at 120.

## [builder's call] list
1. **Status item clicks**: left mouse-down toggles the panel; right or ⌃ mouse-down shows the old menu unchanged.
   Both act on mouse-down, like system menu extras.
2. **Footer**: Settings… and Quit Orbit, plus a … menu with Open Files…, Wheel enabled, Recent results and About
   Orbit. ⌥ Debug stays in the right-click menu only.
3. **Settings rail is a plain sidebar `List` in an `HStack`, not `NavigationSplitView`.** On macOS 26 the split
   view's sidebar is floating Liquid Glass, which renders blank offscreen (first snapshot showed an empty white
   rail). The rail never needs collapsing, and this way the live window and the snapshots draw the same thing.
4. **Scroll on pills**: a mouse wheel nudges by `PillScale.wheelStep` (a fiftieth of the range); a mostly-sideways
   trackpad swipe adjusts; vertical trackpad scrolling goes to the panel's scroll view, so long mixers stay
   scrollable.
5. **PillSlider extras beyond the brief's signature** (all defaulted, so the brief's call shape compiles):
   `height` (app rows use 34), `isDimmed`, `label: AnyView?` (name/LevelBars after the tappable icon),
   `systemImage:` convenience init.
6. **Extra shared pieces**: `PanelLinkButton`, `PanelRoundMenu` (round button with a menu, for Sound's per-app
   output), `PanelStyle`, `PanelGallery`, `SettingsSection`, `SettingsPageScroll`.
7. **`managesOwnScrolling` is a static protocol requirement** (default false), so snapshots can honour it
   without an instance.
8. **Mic mute shortcut registers only while an input device is available** (and the service is active). The
   stub reports no device, so this interim build doesn't take ⌃⌥M from other apps for a no-op. The Sound task's
   `refreshAvailability()` turns it on.
9. **KeyCombo key names** go beyond the brief's list (punctuation, ⇥, ⌫) so more combos display; Esc is kept for
   cancelling the recorder.
10. **Permission polling**: once a second for two minutes after a request or after Open System Settings, then
    stops.
11. **Dark-mode accent**: text and icons use the accent lifted 50 % toward white on dark glass (`PanelStyle.accent(for:)`).
    Fills such as the round button's "on" state keep the true accent.
12. **`SuiteContext` is an `ObservableObject`** (for `statusIndicators`), and also carries `toasts` (the
    coordinator's single `ToastCenter`, so suite and job toasts stack rather than overlap).
13. **Panel window level `.statusBar`**, so SwiftUI menus (pop-up level) open above it.

## Self-review findings (fixed in e7bae9f unless noted)
- My first snapshot runs left 51 empty `orbit.snapshot.<uuid>.plist` files in `~/Library/Preferences`
  (`UserDefaults(suiteName:)` with a plain name). I fixed the code to use absolute-path suites in a temp folder.
  I then removed exactly those 51 files: each was checked to have a birth time of 00:23–00:28 today, during my
  runs, and to be an empty dict. A re-run left none. The legacy `--snapshot-settings` uses the same naming
  pattern but writes nothing, so I left it alone.
- Turning Sound on after a denial would have sent a request macOS ignores; it now opens the pane.
- On reopen, the panel briefly had zero content height until measured; heights are now remembered per tab.
- My Task 6 commit chain used `swift test | grep … && git commit`, which committed despite one flaky failure (see
  Concerns). I re-ran immediately: green. The final commit checks `swift test`'s own exit code.

## Concerns
- **No live check of the status item or panel.** `/Applications/Orbit.app` was running the whole time
  (`pgrep -lfx` showed `/Applications/Orbit.app/Contents/MacOS/Orbit`), so per instructions I never launched my
  build. Click routing (left/right/⌃), outside-click closing, key focus in the non-activating panel, the dot's
  position on the icon and the Settings window chrome (traffic lights over the rail's 30 pt top inset) are
  unverified on screen.
- **Trackpad swipe direction** in `PillSlider` is derived from AppKit's delta conventions
  (`isDirectionInvertedFromDevice`), not tested on hardware.
- **Snapshot fidelity**: an offscreen window is never key, so "on" switches draw with the grey inactive track and
  rail labels look dimmer than they will live. Liquid Glass and materials render as the flat fallback.
- **Flaky test**: `VideoToolTests/trimMKVStaysMKV` (existing ffmpeg test) failed once in a full parallel run
  (6.7 s vs 0.76 s normally) after 31f912f, which changed only app-target files. It passed 3/3 in isolation and
  on both later full runs.
- `TCCAccessPreflight`/`TCCAccessRequest` are private. Return-code meaning (0 granted, 1 denied, other unknown)
  is the community-documented one; a missing symbol shows "Unknown" and Open System Settings still works.
- With Controls on by default, the mic mute service is active at launch. Once the Sound task reports an input
  device, ⌃⌥M is registered globally by default, which is the spec's intent but worth knowing.
- The working tree's `docs/suite/SPEC.md` and `PLAN.md` changes came from the controller's commit 6d8f90c; I
  didn't touch them. This report is uncommitted as asked.

## Files
New: `Sources/OrbitCore/Suite/{FeatureID,SuitePermission,SuiteSettings,KeyCombo,PillScale,PillTrack,SettingsPage,MicMuteSettings}.swift`,
`Tests/OrbitCoreTests/SuiteTests.swift`,
`Sources/OrbitApp/Suite/{SuiteFeature,SuiteContext,FeatureRegistry,PermissionCenter,PrivateSymbol,HotKeyCenter,DisplayIdentity,MicMuteService}.swift`,
`Sources/OrbitApp/Suite/UI/{PanelTile,PillSlider,PanelMenuButton,PanelRoundButton,LevelBars,Stripes,KeyComboRecorder,FeaturePlaceholder,PanelGallery}.swift`,
`Sources/OrbitApp/Features/{Sound,System,Displays,Windows,Clipboard,Shelf,Wallpaper,Controls}/<Name>Feature.swift`,
`Sources/OrbitApp/MenuBar/{MenuBarPanel,MenuBarPanelController,PanelView}.swift`,
`Sources/OrbitApp/Settings/{SettingsRootView,FeaturesPage,FeatureSettingsPage,AboutPage}.swift`,
`Sources/OrbitApp/Debug/{SnapshotRenderer,SuiteSnapshot}.swift`.
Modified: `AppDelegate.swift`, `main.swift`, `MenuBar/StatusItemController.swift`, `Settings/SettingsView.swift`,
`Settings/SettingsWindowController.swift`, `Settings/TriggerRecorder.swift` (moved `symbols`),
`Jobs/JobCoordinator.swift` (`toasts` internal), `Support/Info.plist`.

## Fix round 1 (commit edfabe8)

All changes are additive: every existing signature still compiles. I didn't touch `Suite/MicMuteService.swift`
or anything under `Features/`.

1. **PillSlider scroll monitor** (`Suite/UI/PillSlider.swift`)
   - An invisible, hit-test-transparent `PillWindowProbe` (`NSViewRepresentable`) sits behind each pill.
   - `handleScroll` acts only when `event.window` is the pill's window, that window `isVisible`, and
     `locationInWindow` falls inside the probe's rect (converted to window coordinates, so scroll offset
     counts). Everything else passes through untouched.
   - Momentum-phase events (trackpad inertia after lift-off) are ignored.
   - A monitor whose pill view is gone removes itself.
   - Events merely outside the pill pass through without removing the monitor. This is deliberate: after a
     missed hover-exit, SwiftUI may never re-send hover-enter, so removing it there would leave the pill
     without wheel input.
2. **Late permission grants**
   - `MenuBarPanelController.show(from:)` calls `context.permissions.refresh()` before the visible feature's
     `panelDidAppear()`.
   - `SuiteFeature.swift` has a new "Permissions" paragraph: `start()` may precede grants; observe
     `context.permissions.$statuses` or re-check in `panelDidAppear()`; gate work on `.granted`; never prompt
     directly, only through `PermissionCenter.request`.
3. **Fixture storage** (`Suite/SnapshotFixtures.swift`, new)
   - `defaults()` is an absolute-path suite in a temp folder; the domain and folder are removed at exit via
     `atexit`.
   - `scopedDefaults()` returns the defaults with a cleanup closure; `directory()` gives a temp folder removed
     at exit.
   - The contract comment now points at these instead of `UserDefaults(suiteName:)`, and the snapshot CLI uses
     `scopedDefaults()`.
4. **Screen Recording double prompt** (`Suite/PermissionCenter.swift`)
   - `request(_:)` records `suite.permissionAsked.<permission>` in `UserDefaults` (via a new
     `init(…, defaults: = .standard)` parameter).
   - Screen Recording opens the pane only if it was requested before and is still not granted. A first
     request now shows only macOS's prompt.
   - Accessibility is unchanged: its prompt carries its own Open System Settings button, and Orbit opens no
     pane.
   - Audio is unchanged: it opens the pane only when TCC reports denied.
5. **Same-state `setEnabled`** (`Suite/FeatureRegistry.swift`): when `isEnabled(id) == on` it returns early after
   reconciling the running state (start if on, stop if off) and the mic mute activity. No requests, no panes.
6. **Sound on macOS 14.0/14.1**
   - New in OrbitCore: `SuitePermission.minimumSystemVersion` and `isAvailable(on:)` (System Audio Recording:
     14.2), tested in `SuiteTests.permissionSystemRequirements`.
   - App side: `SuitePermission.isAvailableOnThisMac` / `unavailableReason` ("Needs macOS 14.2 or later") and
     `PermissionCenter.isAvailable(_:)`.
   - `setEnabled` requests nothing for a feature with `unavailableReason` and skips unavailable permissions.
     `request` and `openSettings` are no-ops for an unavailable permission (no nonexistent pane).
   - The Features card's Sound note now reads "…need macOS 14.2 or later, so Orbit won't ask for System Audio
     Recording here. The mic mute shortcut still works." The permission row shows the reason instead of the
     status badge and button (`PermissionRow` gained a defaulted `unavailableReason:` parameter).

### Commands and output
- TDD for item 6:
  - RED: `swift test --filter SuiteTests` → 12× `value of type 'SuitePermission' has no member 'isAvailable'`
    and 4× `… no member 'minimumSystemVersion'`.
  - GREEN: `✔ Test run with 15 tests in 2 suites passed`.
- `swift build` → exit 0, no warnings.
- `swift test`:
  - First full run → exit 1, 1 issue: `VideoToolTests/compressFits()` threw `.targetTooSmall("Can't fit this
    video under 500 KB.")`. That's an existing ffmpeg test. My diff touches only `SuitePermission.swift` and
    `SuiteTests.swift` in OrbitCore/Tests.
  - Run alone 3×: passed, **failed** (same error), passed. So it's nondeterministic independent of these
    changes; left untouched (outside my scope).
  - Second full run → exit 0, `✔ Test run with 562 tests in 25 suites passed after 87.831 seconds`. I committed
    only after that, with the commit gated on `swift test`'s own exit code.
- `swift build -c release --arch arm64 --arch x86_64` → exit 0, `Build complete!`, `lipo -archs` → `x86_64 arm64`,
  0 warnings.
- `.build/debug/Orbit --snapshot-suite <scratch>/shell-shots/suite --replace` → exit 0, 44 files.
  `~/Library/Preferences` held 0 `orbit.snapshot|fixture` plists before and after, and no fixture temp folders
  were left. I looked at `suite/settings-features-light.png`: unchanged on macOS 26.5. The 14.0/14.1 branch
  can't be rendered on this Mac.

### Still unverified
Live behaviour, as before: `/Applications/Orbit.app` is still running, so I didn't launch the build. The probe
geometry check and the momentum guard are compiled and reasoned through, not exercised with a real wheel or
trackpad.
