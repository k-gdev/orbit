# Orbit Suite: Windows (Task 10) report

Branch **`suite/windows`**, built on `1a84988 docs(suite): shell implementer report`. Not pushed, as instructed.
There are 15 commits. Each one was checked out on its own and passed `swift build` and
`swift test --skip "VideoToolTests|VideoConversionTests"`. The final full `swift test` passed:
**581 tests in 26 suites** (561 before, plus 20 in `WindowsTests`). The universal release build
`swift build -c release --arch arm64 --arch x86_64` printed `Build complete!` with no warnings, and
`lipo -archs` reports `x86_64 arm64`. A dry-run `git merge-tree` against the current `claude/suite-77e4bb`
merges with no conflicts. None of my internal type names exist on that branch or on `suite/sound|system|displays|controls`.

| Commit | Subject |
|---|---|
| 500c5f3 | feat(windows): match Accessibility windows to capture windows |
| 058a200 | feat(windows): Dock preview strip layout |
| 63500f1 | feat(windows): running app list order |
| 303f9c9 | feat(windows): Windows settings |
| ab21b1e | feat(windows): Dock hover policy |
| 62c4f38 | feat(windows): timed cache for window thumbnails |
| bd047a0 | feat(windows): which windows are listed |
| ea41193 | feat(windows): hit-test the Dock preview's thumbnails |
| be03ccd | feat(windows): Dock preview readiness |
| bcf5737 | feat(windows): Accessibility window service and app control |
| a8f1a50 | feat(windows): Windows tab |
| 18e2f78 | feat(windows): Dock preview |
| 247595f | feat(windows): Windows feature and settings page |
| ba99939 | feat(windows): Dock preview and Windows tab snapshots |
| 7326f94 | fix(windows): re-attach to a restarted Dock through the process list |

## What was built

### OrbitCore (`Sources/OrbitCore/Windows/`): all the logic that can be decided without the OS
- **`WindowMatcher.match(axWindows:captureWindows:) -> [(ax: Int, capture: Int)]`** with `WindowDescriptor`
  (number?, title?, frame in top-left global space).
  - When both sides know the window number, the number decides: equal numbers match, different numbers never
    match.
  - Otherwise the titles must be equal (nil counts as "") and every edge must be within **2 pt**. Among
    candidates the closest frame wins. Each index is used once.
- **`DockPreviewLayout.make(aspectRatios:iconFrame:edge:visibleFrame:)`** returns the strip frame (AppKit
  coordinates), a header frame, and thumbnail frames (strip-local, top-left origin).
  - Sizes: max thumbnail height **140**, spacing **10**, padding 10, title line 18, icon gap 16, screen
    margin 8, minimum content width 160.
  - Placement: bottom Dock → centred above the icon; left/right Dock → beside the icon, centred vertically.
    The strip is clamped inside the visible frame.
  - When one row would shrink the thumbnails, they wrap into several rows (it picks the row count that gives
    the tallest thumbnails).
  - Aspect ratios are sanitised: 0, NaN or negative → 1.6; anything else is clamped to 0.5…3.
  - Also: `hoverRegionContains(_:)` (strip, icon and the gap between them, with 6 pt slack),
    `thumbnailIndex(at:)` (pointer → thumbnail), `capturePixelSize(for:scale:)`, and
    `sanitizedAspectRatio`.
  - Also here: `DockEdge(orientation:)`, `PixelSize`, and `ScreenSpace.flip` (top-left ↔ bottom-left global
    coordinates).
- **`RunningAppList.sort(_:)`** with `RunningAppInfo`: regular apps only, frontmost first, then by
  `localizedStandardCompare` name, then by pid.
- **`WindowsSettings`**: `windows.dockPreviewEnabled` (true), `windows.previewDelay` (0.35 s, clamped to
  0…1.5; non-numbers fall back to the default), `windows.showMinimised` (true).
- **`DockHoverPolicy`** (state machine): opens after the delay. Moving off before then cancels; sliding to
  another icon restarts the wait, and a stale timer is ignored. While open, another app's icon switches at
  once, and leaving the Dock keeps the strip until the pointer leaves the hover region. `dismissed()` resets.
- **`TimedCache<Key, Value>`**: lifetime plus capacity, oldest entry evicted first; time is injected. Used for
  thumbnails: 3 s, 48 entries.
- **`WindowListing`**: lists windows with subrole `AXStandardWindow`/`AXDialog` (or no subrole) that are at
  least 40×40 pt. Order is front to back, minimised last or left out. `displayTitle` falls back to the app
  name for untitled windows.
- **`DockPreviewReadiness`**: off / needsAccessibility / titlesOnly / ready. `watchesDock` is true only for
  the last two.

### OrbitApp (`Sources/OrbitApp/Features/Windows/`)
- **`AXWindowService`** reads an app's windows: title, frame, minimised, subrole, and window number via
  **`_AXUIElementGetWindow` through `PrivateSymbol`** (HIServices). If that symbol is missing, the number is
  nil and matching falls back to title + frame.
  - Bring forward: unhide, un-minimise, `kAXRaiseAction`, `kAXMainAttribute`, app `kAXFrontmostAttribute`,
    then `activate`.
  - Minimise and restore via `kAXMinimizedAttribute`; close by pressing `kAXCloseButtonAttribute`.
  - Every element gets a 0.25 s messaging timeout, and nothing runs without `AXIsProcessTrusted()`.
- **`AppControlService`** (NSWorkspace, no permission): lists running apps.
  - Focus: unhide, then `NSWorkspace.openApplication` (behaves like a Dock click; falls back to `activate`).
  - Hide/show, quit (`terminate()`), force quit (`forceTerminate()`).
  - Workspace observers are installed only while the tab is visible.
- **`DockWatcher`**: an `AXObserver` on the Dock's `AXList` for `kAXSelectedChildrenChangedNotification`.
  - Hovered `AXApplicationDockItem` → `AXURL` (or title) → running app, plus the icon frame flipped to AppKit
    coordinates.
  - Retries attaching up to 5 times. It re-attaches when the Dock's pid changes, via KVO on
    `NSWorkspace.runningApplications`.
- **`WindowThumbnailer`**: `SCShareableContent` (all Spaces, layer 0, this pid) and
  `SCScreenshotManager.captureImage`, sized by `capturePixelSize` (≈ 140 pt × backing scale), with no cursor
  and no shadow. It is only called after `CGPreflightScreenCaptureAccess()`, so it never prompts.
- **`DockPreviewPanel` / `DockPreviewStrip` / `DockPreviewModel`**: a non-activating borderless `NSPanel` at
  `.popUpMenu` level that never becomes key. The glass strip (`GlassBackground`) has a title line (the app
  name, or the hovered window's title) and a window count, then the thumbnails.
  - Without a thumbnail, a cell shows a card with the app icon and window title. Minimised windows get a
    "Minimised" badge.
  - The hovered cell gets an accent ring and a 1.025× scale.
  - A container view takes every mouse-down. The controller hit-tests the thumbnails itself, because SwiftUI
    hover is unreliable in a panel of an inactive app.
- **`DockPreviewController`**: wires the watcher, the policy, the delay timer, the panel and the thumbnails.
  - Windows are read on a background queue. The strip shows at once with title cards, and thumbnails fill in
    as they are captured. A generation counter drops late results.
  - While the strip is visible: a 30 Hz pointer check (hover index, plus closing after 0.12 s outside the
    region), a global mouse-down monitor (clicks elsewhere close it), and a Space-change observer. All three
    are torn down when it hides.
  - The Dock edge is read via `CFPreferencesCopyAppValue("orientation", "com.apple.dock")` (read-only; no
    defaults object).
- **`WindowsPanelModel` / `WindowsPanelView`** (the tab):
  - A "Running apps · N apps" header, then one tile per app: chevron, icon, name, subtitle such as
    "Frontmost · 3 windows" or "Hidden · 1 window".
  - Round buttons per app: bring to front, hide/show, and a power menu with Quit and Force Quit…. Force Quit
    asks for confirmation inline. A context menu offers the same actions.
  - Expanded, an app lists its windows. Clicking a row brings that window forward; each row has
    minimise/restore and close buttons, and minimised windows are tagged.
  - Without Accessibility the expanded area shows a grant row: "Windows need Accessibility" with an
    **Allow…** button, which calls `PermissionCenter.request(.accessibility)`. App actions keep working.
  - Accessibility reads happen on a background queue, only between `panelDidAppear` and
    `panelDidDisappear`. A grant made while the tab is open is picked up from `$statuses`.
- **`WindowsSettingsView`**:
  - Dock preview section: the toggle, a delay slider (0–1.5 s, rounded to 0.05 in the binding so no tick
    marks are drawn), and a readiness row. It shows "Off", "Needs Accessibility… [Allow…]", "Without Screen
    Recording the preview shows window titles… [Allow…]" or "Ready".
  - Window lists section: "Show minimised windows".
- **`WindowsFeature`**:
  - `init` only loads settings. `start()` subscribes to `permissions.$statuses` and
    `settings.$dockPreviewEnabled`, plus the system's `com.apple.accessibility.api` distributed notification
    (it re-reads permissions 0.5 s later). It then creates `DockPreviewController` only when
    `DockPreviewReadiness.watchesDock` holds; otherwise it releases the controller.
  - `stop()` releases everything: subscriptions, the observer, the controller, and the panel model.
  - It never prompts by itself; prompts come only from the registry and the user's own "Allow…" clicks.
- **`WindowsFixtures`**: fixture apps using system app icons (symlinks resolved, so Safari has no alias
  badge) and fake window art rendered with `ImageRenderer`. **`FixtureDefaults`** is an absolute-path suite
  in its own temp folder, removed at exit. It does the same job as the shell's `SnapshotFixtures.defaults()`,
  which exists on `claude/suite-77e4bb` but not in my base, so the controller can swap it in on merge.
- **`WindowsSnapshot`**: `--snapshot-dock-preview <png> [--dark] [--titles-only] [--replace]` (the real strip
  laid out by `DockPreviewLayout` over a mock desktop and Dock) and
  `--snapshot-windows-panel <granted|no-access|force-quit> <png> [--dark] [--replace]`.

## Files
New in OrbitCore: `Sources/OrbitCore/Windows/{WindowMatcher,DockPreviewLayout,RunningAppList,WindowsSettings,DockHoverPolicy,TimedCache,WindowListing,DockPreviewReadiness}.swift`.

New in OrbitApp: `Sources/OrbitApp/Features/Windows/{AXWindowService,AppControlService,DockWatcher,WindowThumbnailer,DockPreviewPanel,DockPreviewController,WindowsPanelModel,WindowsPanelView,WindowsSettingsView,WindowsFixtures,WindowsSnapshot}.swift`.

Replaced: `Sources/OrbitApp/Features/Windows/WindowsFeature.swift`. New test file:
`Tests/OrbitCoreTests/WindowsTests.swift`. One line in `Sources/OrbitApp/main.swift` (see Shell changes).

## Tests and TDD evidence (`swift test --filter WindowsTests`)
There are 20 tests. The brief's 8 are present under its exact names: `matchesByNumber`,
`matchesByTitleAndFrame`, `noMatchBeyondTolerance`, `layoutCentresOverIcon`, `layoutClampsToScreen`,
`layoutLeftAndRightDock`, `appListOrder`, `settingsRoundTrip`. The 12 extras are `hoverRegionBridgesIconAndStrip`,
`thumbnailUnderPointer`, `captureSizeIsSmall`, `dockEdgeFromPreference`, `flipsBetweenTopLeftAndBottomLeft`,
`hoverWaitsForDelay`, `switchingAppsWhileOpenIsImmediate`, `leavingClosesPreview`, `dockPreviewReadiness`,
`thumbnailCacheExpires`, `windowListFilters` and `untitledWindowsTakeTheAppName`. Settings tests use
`Fixtures.defaults()` (temp-folder suite).

For each unit I wrote the test, ran it red, implemented, ran it green, then committed. RED is always a
compile failure on the missing API:
| Unit | RED (`swift test --filter WindowsTests`) | GREEN |
|---|---|---|
| matcher | `cannot find 'WindowDescriptor' in scope` (×20), `cannot find 'WindowMatcher' in scope` | first run 2 passed, `noMatchBeyondTolerance` failed: my fixture was wrong (width 602 moves the right edge 4 pt); after fixing the fixture, `✔ Test run with 3 tests in 1 suite passed` |
| layout | `cannot find 'DockEdge' in scope` ×10, `'PixelSize'` ×8, `'ScreenSpace'` ×8, `cannot find type 'DockPreviewLayout'` ×4 | `✔ … 10 tests … passed` |
| app list | `cannot find 'RunningAppList' in scope` ×6, `'RunningAppInfo'` ×6 | `✔ … 11 tests … passed` |
| settings | `cannot find 'WindowsSettings' in scope` ×14 | `✔ … 12 tests … passed` |
| hover policy | `cannot find 'DockHoverPolicy' in scope` ×18 | `✔ … 15 tests … passed` |
| cache | `cannot find 'TimedCache' in scope` ×2 | `✔ … 16 tests … passed` |
| listing | `cannot find 'WindowListing'` ×12, `'WindowSummary'` ×12 | `✔ … 18 tests … passed` |
| hit-test | `value of type 'DockPreviewLayout' has no member 'thumbnailIndex'` ×10 | `✔ … 19 tests … passed` |
| readiness | `cannot find 'DockPreviewReadiness' in scope` ×10 | `✔ … 20 tests … passed` |

Full suite: the final `swift test` → `✔ Test run with 581 tests in 26 suites passed`.

**Flaky existing tests during development.** Several mid-session full runs failed only in
`VideoToolTests`/`VideoConversionTests`, with a different test each time. The errors were
`h264_videotoolbox … Cannot create compression session: -12903 … The hardware encoder may be busy` and
`Error retrieving the supported property dictionary`, plus once `trimMKVStaysMKV` (1.17 s vs 1 ± 0.15). This
is consistent with seven other agents building and testing on the same Mac at the same time. My changes
touch no video code. Each commit was therefore gated on `swift test --skip "VideoToolTests|VideoConversionTests"`
(503–512 tests, all passing). The last full run, including the video suites, passed.

## Snapshots I checked (light and dark, with the image tool)
All are in `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/windows/shots/`:
- `preview-light.png`, `preview-dark.png`: Dock preview with thumbnails, the first one hovered (accent ring;
  the title line shows its window title), plus a minimised card.
- `preview-titles-light.png`, `preview-titles-dark.png`: the same without Screen Recording (title cards).
- `panel-light.png`, `panel-dark.png` (`--snapshot-panel windows`): Safari frontmost and expanded with 3
  windows, one minimised; Messages hidden; Notes with no windows.
- `panel-noaccess-light.png`, `panel-noaccess-dark.png`: the grant row, and subtitles without window counts.
- `panel-forcequit-light.png`, `panel-forcequit-dark.png`: the inline force-quit confirmation.
- `settings-light.png`, `settings-dark.png` (`--snapshot-settings-page windows`).

Re-render all 12 with
`bash /private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/windows/shots.sh <path to .build/debug/Orbit>`.

Fixed by iterating on the snapshots:
- The Safari icon had an alias badge, because `/Applications/Safari.app` is a symlink on macOS 26.
- The strip sat tight against the Dock's glass; the icon gap went from 8 to 16 pt.
- The delay slider drew 31 tick marks.
- A settings section was titled "Windows", repeating the page name.

## [builder's call] list
1. **App action set (per app):** bring to front (unhide + `openApplication`, i.e. Dock-click behaviour,
   which reopens a window for an app with none; closes the panel), **hide/show** toggle, **quit**
   (`terminate()`, no confirmation; the app may ask to save), **force quit** (`forceTerminate()`, after an
   **inline** confirmation in the row rather than an NSAlert, because a modal doesn't suit a non-activating
   menu panel). Quit and Force Quit share one round "power" menu. A context menu on the row offers all four.
2. **Window action set (per window):** **bring forward** (click the row; closes the panel), **minimise ↔
   restore** (one toggle button), **close** (presses the window's close button). There is no separate
   bring-forward button, because the whole row is that button.
3. Clicking an app's row **expands** it (chevron). The app list shows every regular app; Orbit (an accessory
   app) never appears.
4. Window counts and titles need Accessibility. Without it the subtitle shows only Frontmost / Hidden /
   Running, with no window-list estimate from CGWindowList.
5. **Without Screen Recording the Dock preview still works** with Accessibility alone: title cards (app icon
   + window title) instead of thumbnails, and ScreenCaptureKit is never called (no prompts). The Dock is
   watched only with Accessibility (ruling).
6. Hover delay range is **0–1.5 s** in 0.05 steps (the default 0.35 s is from the brief). While a strip is
   open, moving to another app's icon **switches immediately** without the delay.
7. The strip **closes**: 0.12 s after the pointer leaves the icon, the gap and the strip (6 pt slack); on any
   click outside it, including on the Dock icon itself; on a Space change; or when a window is picked. An app
   with no listed windows shows **nothing**.
8. **Layout:** one row whenever thumbnails fit at 140 pt; otherwise the row count giving the tallest
   thumbnails. Side Docks get a horizontal row beside the icon (not a vertical column). The icon gap is 16 pt
   so the strip clears the Dock's background. It may cover the Dock's own name tooltip, but the strip's
   title line names the app.
9. Thumbnail cache: **3 s**, 48 windows; it is cleared when the preview turns off. Thumbnails are captured
   at ≈140 pt × backing scale, with no cursor and no window shadow.
10. Listed windows are standard windows and dialogs ≥ 40×40 pt (palettes and helpers are skipped).
    Minimised windows come last, and "Show minimised windows" applies to both the preview and the tab.
11. The window number comes from `_AXUIElementGetWindow` via `PrivateSymbol` (loaded from
    `/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices`;
    I probed that it exists on this Mac, read-only). If it is missing, matching uses title + frame.
12. The panel level is `.popUpMenu`, above the Dock. The panel never becomes key and never activates Orbit.
13. The Dock edge comes from the `com.apple.dock` `orientation` preference, read with
    `CFPreferencesCopyAppValue` (no `UserDefaults(suiteName:)` object). Missing means bottom; Kevo's Mac has
    none set, so bottom, with auto-hide on.
14. Robustness: the Dock watcher re-attaches when the Dock restarts, via KVO on the process list (up to 5
    retries). A Dock hover only counts while the pointer is within 60 pt of that icon (covers magnification),
    so a hover the Dock never cleared can't pin the strip open.
15. The feature also listens to the system's `com.apple.accessibility.api` distributed notification while
    on and refreshes `PermissionCenter`. A grant made in System Settings then starts the Dock preview without
    Orbit needing to become active first. This follows the controller note about late grants.
16. The settings readiness row has **Allow…** buttons that call `PermissionCenter.request` (user-initiated).
    The shared header above it already shows the permission rows with "Open System Settings".

## Shell changes
- `Sources/OrbitApp/main.swift`: **one line**, `WindowsSnapshot.runIfRequested(CommandLine.arguments)`, after
  `EditorCheck`. It registers the two snapshot flags. A dry-run merge with the current suite branch is clean.
- Nothing else outside my folders. No changes to Suite/, Settings/ or MenuBar/.

## Needs hardware verification (Accessibility + Screen Recording granted to the signed build)
My build isn't trusted for AX/Screen Recording on this Mac, and I never ran it as an app. None of the
following has been seen live:
- **DockWatcher**: does the Dock fire `kAXSelectedChildrenChangedNotification` on hover, and does it clear on
  leaving? Does `AXURL` match `bundleURL` for every app (Safari's cryptex path in particular; the title
  fallback should cover it)? Do icon frames come out correct on all four displays, including the display
  above the main one (negative top-left y) and with auto-hide and magnification?
- **Thumbnails**: does SCK capture work for windows on other Spaces, and is the matching right for
  multi-window apps (Chrome, Finder)? Check the thumbnail quality at 2x, and that capture time is acceptable
  with ~10 windows (captures run one after another).
- **Panel**: does it sit above the Dock (`.popUpMenu`) without stealing focus? Does a click on a thumbnail
  raise the right window and activate the app (`kAXRaiseAction` + frontmost + `activate`, which may need a
  check under macOS 26 cooperative activation)? Does the strip close when the pointer moves off, and does a
  click on the Dock icon close it?
- **Tab actions on real apps**: focus, hide/show, quit, force quit, minimise/restore, close. I deliberately
  never invoked any of them on Kevo's apps; only NSWorkspace listing was read.
- **Late grant**: turn Windows on, grant Accessibility in System Settings, and the Dock preview should start
  within ~0.5 s (via the distributed notification or PermissionCenter polling).

## Known gaps
- AX enumeration runs per app on a background queue with 0.25 s timeouts. A hung app delays only its own
  row's window count.
- Captures run one after another, not in parallel. That is fine for a few windows, but slower for apps with
  many.
- With Dock magnification, the strip is positioned from the icon frame at hover time, so it may sit slightly
  off the magnified icon.
- No VoiceOver path into the Dock strip itself: it is a non-key panel. The tab and settings have labels.
- `FixtureDefaults` duplicates the shell's newer `SnapshotFixtures.defaults()`; it can be swapped after merge.
- No new `~/Library/Preferences` plists came from my runs. Tests use `Fixtures.defaults()`, snapshots use
  temp-folder suites, and no `orbit-windows-fixture-*` folders are left in `$TMPDIR`. One new file did appear
  during the session: `~/Library/Preferences/TokenBucketRateLimiter.plist` (01:31). Its contents are
  `SKDUserDefaults` data from a macOS Spotlight/Siri knowledge service, and no Orbit source mentions it. I
  left it alone.
- **Report location:** the agent's worktree isolation refused a direct write into the suite worktree, so the
  report was written to
  `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/windows/windows-report.md`
  and copied (uncommitted) to `docs/suite/reports/windows.md` in the suite worktree.

---

## Fix round 1 (task review)

Branch `suite/windows`, 10 new commits on top of `7326f94`, not pushed. Each commit passed `swift build` and
`swift test --skip "VideoToolTests|VideoConversionTests"` before it was made. Nothing was ever run against
Kevo's real apps.

| Commit | Subject | Item |
|---|---|---|
| 2bc6f64 | fix(windows): short Accessibility timeout on every element; actions off main | I1 |
| 9c3005a | fix(windows): cooperative activation when bringing windows and apps forward | R1 |
| a7997bf | feat(windows): Dock preview window list across Spaces | M1 (core, TDD) |
| 94d208b | fix(windows): Dock preview shows windows on other Spaces | M1 (app) |
| a546224 | fix(windows): place the strip from the icon's current frame | M2 |
| 715a993 | fix(windows): a click during the hover delay cancels the preview | M3 |
| f1a959d | fix(windows): purge expired thumbnails when the strip hides | M6 (core, TDD) |
| 8ad0bf9 | fix(windows): Dock preview panel is transient only | M8 |
| 5b81636 | fix(windows): readiness accounts for the Windows feature being off | M11 (core, TDD) |
| 1fdea4a | fix(windows): reset cleanly when the hovered app is gone at show time | follow-on to M3 |

### What changed
- **I1: Accessibility timeouts and the main thread.** The reviewer is right: my original report said
  "every element gets a 0.25 s messaging timeout", and that was **false**. A timeout set on one element
  doesn't carry over to elements copied from it. The close button, the Dock's `AXList` and every hovered Dock
  item used the ~6 s default, and `close` pressed the button on the main thread.
  - `AX` now hands out elements only through `AX.application(pid)`, `AX.element(_:_:)` and
    `AX.elements(_:_:)`, and each of them sets `AX.timeout` (0.25 s) on every element it returns. Plain values
    go through `AX.value` (renamed from `copy`, so it is never used for elements).
  - `grep -n "AXUIElementCopyAttributeValue|AXUIElementCreateApplication|AX.copy"` over the Windows folder
    now finds only the four calls inside those helpers.
  - The Dock watcher uses them for the Dock, its list and each selected item. It used 0.5 s before, on the
    app element only.
  - `bringForward`, `setMinimised` and `close` send their Accessibility messages on a serial
    `AXWindowService.actionQueue`. An app answering with an app-modal alert, or not answering, can no longer
    freeze the wheel, the panel or the Dock preview. Reads were already on background queues.
- **R1: cooperative activation.** New `AppActivation.activate(_:allWindows:)`: unhide, then
  `NSApp.yieldActivation(to: app)`, then `app.activate(from: .current, options:)`, falling back to
  `activate(options:)` if refused. These are macOS 14 APIs, which is the deployment target, so no
  `#available` is needed.
  - Bring forward activates cooperatively, raises the AX window on the action queue, and raises it again
    0.25 s later, once activation has landed.
  - App Focus uses the same activation with all windows, then a Launch Services reopen, so an app with no
    windows opens one (Dock-click behaviour).
  - Choosing an "Other Space" window activates its app the same way.
- **M1: other Spaces.** New in OrbitCore, `PreviewWindowList.merge(accessibility:capture:showMinimised:)`, with
  `AccessibilityWindowInfo`, `CaptureWindowInfo` and `PreviewWindowEntry`.
  - Listed Accessibility windows come first (`WindowListing` order), each paired with its capture window via
    `WindowMatcher`.
  - Then come ScreenCaptureKit windows that are unmatched, off screen, layer 0, titled and at least 40×40 pt:
    windows on other Spaces or in full screen.
  - Matching runs against **all** Accessibility windows, so a skipped palette, or a minimised window hidden by
    "Show minimised windows", never comes back as an "elsewhere" window.
  - The controller reads AX windows (background) and, only when `CGPreflightScreenCaptureAccess()` is true,
    the app's `SCWindow`s, merges them, and lays out the strip from the merged frames. Elsewhere windows get an
    **"Other Space"** badge and a thumbnail when capture works (otherwise a title card). Clicking one activates
    the app, and macOS switches Space.
  - The **Windows tab** stays on the current Space plus minimised windows and now says so in a caption under
    the list: "Window lists show this Space and minimised windows. With Screen Recording, the Dock preview also
    shows other Spaces." It appears only when Accessibility is granted.
- **M2: stale icon frame.** `DockHover` keeps the Dock item (`item: AXUIElement`, with the timeout).
  `DockWatcher.currentIconFrame(of:)` re-reads its position and size. The controller calls it when the delay
  fires and when switching apps, before laying out the strip.
- **M3: click during the delay.** The global mouse-down monitor is installed when the hover delay starts
  (`.schedule`), not only once the strip is visible. A click cancels the pending show (`dismiss()`). The
  monitor is removed on `.cancelSchedule` (when no strip is up) and on hide. Follow-on fix (1fdea4a): if the
  delay fires for an app that is no longer hovered, the controller now dismisses (which removes the monitor)
  instead of returning silently.
- **M6: thumbnail purge.** `TimedCache.removeExpired(now:)` is new and used by `insert`.
  `WindowThumbnailer.purgeExpired()` runs from `hideStrip()`, and once more 3.1 s later (one cancellable work
  item, cancelled on `stop()`), so a one-off hover keeps no images.
- **M8:** `DockPreviewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`
  (`.stationary` removed).
- **M11:** `DockPreviewReadiness` gains `.featureOff`, which takes precedence and never watches the Dock (new
  `featureOn:` parameter, default true).
  - `WindowsSettingsView` now takes `suite: SuiteSettings` and shows "Not running: turn on Windows above to use
    the Dock preview." while Windows is off. It no longer says "Ready".
  - `WindowsFeature.updateDockPreview` uses the same readiness with `featureOn: isRunning`.
  - The settings snapshot fixture leaves Windows off, matching the shell-rendered header.

### Tests (TDD for the three core changes)
- M1, RED: `swift test --filter WindowsTests` → `cannot find 'PreviewWindowList' in scope` ×10,
  `cannot find type 'AccessibilityWindowInfo' / 'CaptureWindowInfo' / 'PreviewWindowEntry' in scope`.
  GREEN: `✔ Test run with 23 tests in 1 suite passed`. The new tests are
  `previewListAddsWindowsOnOtherSpaces` (helpers, tiny, on-screen, layer-3 and matched-palette windows are
  excluded), `previewListHidesMinimisedEverywhere` (also without AX window numbers) and
  `previewListWithoutScreenRecording`.
- M6, RED: `value of type 'TimedCache<Int, String>' has no member 'removeExpired'` ×4. GREEN: 24 tests pass.
  New test: `thumbnailCachePurgesExpired`.
- M11, RED: `extra argument 'featureOn' in call` ×6, `type 'DockPreviewReadiness' has no member 'featureOff'` ×6.
  GREEN: `dockPreviewReadiness` passes (it has new `.featureOff` expectations). The app's exhaustive
  `switch` in the settings view then failed to compile until the new case was handled.
- I1, R1, M2, M3, M8 are OS glue (Accessibility, activation, AXObserver, NSEvent monitors, NSPanel behaviour)
  and can't be unit-tested here. They are covered by build plus review, the grep above for I1, and they need
  the hardware checks below.
- Final runs:
  - `swift test --filter Windows` → `✔ Test run with 24 tests in 1 suite passed`.
  - Full `swift test` once → `✔ Test run with 585 tests in 26 suites passed` (no video flakes this time).
  - `swift build -c release --arch arm64 --arch x86_64` → `Build complete!`, 0 warnings; `lipo -archs` →
    `x86_64 arm64`.

### Snapshots re-checked
All 12 in `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/windows/shots/`
were re-rendered with `shots.sh`.
- `preview-light/dark.png` now shows 4 windows: two thumbnails, a minimised card, and a full-screen window from
  another Space with the "Other Space" badge. The scene is 1000 pt wide.
- `preview-titles-*` (no Screen Recording) shows the 3 Accessibility windows only, as it should.
- `panel-light/dark.png` show the new caption under the list.
- `settings-light/dark.png` show the "Not running" readiness row.

### New or changed [builder's call]s
- Elsewhere windows must be **titled**, off screen, layer 0 and at least 40×40 pt. Untitled off-screen windows
  are almost always helpers, so a real untitled window on another Space is missed.
- They come after the Accessibility windows, in ScreenCaptureKit's order, with the badge "Other Space". In
  full screen it is also another Space, so the same badge is used.
- The preview waits for ScreenCaptureKit's window list (when Screen Recording is granted) before showing, so
  the layout doesn't jump. Thumbnails still fill in afterwards.
- Thumbnails are purged on hide and 3.1 s after.
- The Focus action is now cooperative activation plus a Launch Services reopen (it was reopen alone).

### Still needs hardware verification (in addition to the list above)
- Whether `SCScreenshotManager` captures windows on other Spaces, or full-screen windows, as thumbnails; if
  not, they show as title cards.
- Whether `yieldActivation` + `activate(from:)` activates the target from Orbit's non-activating panels on
  macOS 26.
- That the delayed re-raise picks the right window.
- That an auto-hiding Dock places the strip correctly after the delay (M2).
