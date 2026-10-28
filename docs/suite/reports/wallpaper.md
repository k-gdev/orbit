# Wallpaper (Task 13): implementer report

Branch `suite/wallpaper` (not pushed, per instructions). Status: **DONE_WITH_CONCERNS**. The feature is built and covered by tests, but it has not run on real hardware yet. The hardware list below needs checking before it can be called done.

## Commits

The branch was cut at `1a84988` as instructed, then rebased onto `claude/suite-77e4bb` @ `39ca1ca` (the shell fix round). The controller's note asked me to use `SnapshotFixtures`, which only exists there. My commits only add or replace Wallpaper files, and `git merge-tree` against the current suite tip (`0f575ab`, with Shelf merged) shows no conflicts.

| SHA | Subject |
|---|---|
| `cd0d91c` | feat(wallpaper): aerial catalog reads the downloaded aerials from the system manifest |
| `2edc5a0` | feat(wallpaper): wallpaper sources and per-display assignments |
| `84a0745` | feat(wallpaper): pause policy and per-display window plan |
| `8657744` | feat(wallpaper): settings, desktop picture ledger and still frame names |
| `d2b0c41` | feat(wallpaper): live wallpaper windows, panel tab and settings page |
| `ea77dd0` | fix(wallpaper): one bookmark refresh per file per run, shared still writes |

## What was built

**Core (`Sources/OrbitCore/Wallpaper/`, pure, tested)**
- `AerialCatalog.swift`
  - `Aerial` has `id`, `name`, `category`, and `videoURL`/`thumbnailURL` once located.
  - `AerialLocation` describes one layout: manifest, strings bundle, video folders, thumbnails.
  - `AerialCatalog.parse(entriesJSON:localizedStrings:)`:
    - Name comes from `localizedNameKey`, then `accessibilityLabel`, then `shotID`, then `id`.
    - Category is the localized name of the asset's first listed category.
    - Sorted by category order, then the asset's `preferredOrder`, then manifest order.
    - Bad JSON gives `[]`; a duplicated id is kept once.
  - `localizedStrings(locTable:)` / `localizedStrings(bundle:)` read either the macOS 26 `Localizable.nocache.loctable` or the older `<lang>.lproj/Localizable.nocache.strings`. They pick the user's language and fall back to English per key.
  - `locations` lists the macOS 26 per-user folder first, then macOS 14/15 `/Library/Application Support/com.apple.idleassetsd/Customer/`.
  - `downloaded(_:in:)` / `load()` offer an aerial only when `<id>.mov` is a non-empty regular file. They only read and never download.
- `WallpaperSource.swift`
  - `WallpaperSource` is `.video(path:bookmark:)` or `.aerial(id:)`; `identity` ignores the bookmark bytes.
  - `DisplayRef` is a key plus a name.
  - `WallpaperAssignment` is a source plus the display name at the time it was chosen.
  - `WallpaperAssignments` is keyed by display key, with `assign`, `remove`, `videos` and `adopt(_:)`. `adopt` is the name fallback, described under builder's calls.
- `WallpaperPausePolicy.swift`
  - `DisplayConditions` has exactly the brief's seven fields.
  - `PauseReason` is in precedence order and carries a short label.
  - `PlaybackState`, including `combined` for a player shared by several displays.
  - `WallpaperPausePolicy.state(for:)`.
  - `WallpaperPlan.desired` / `changes` decide which displays get a window, and close the window of an unplugged display.
- `WallpaperSettings.swift`
  - `WallpaperSettings` stores, under `wallpaper.` keys: `assignments` (JSON), `pauseOnBattery` (false), `pauseInLowPower` (true), `setStillFrame` (true) and `previousDesktopPictures`.
  - `previousDesktopPictures` is managed by `rememberDesktopPicture` and `desktopPictureToRestore`.
  - `StillFrame` names stills, recognises them, and picks unused ones to clean up.

**App (`Sources/OrbitApp/Features/Wallpaper/`)**
- `WallpaperWindow`:
  - Borderless, `level = CGWindowLevelForKey(.desktopWindow)`, `[.canJoinAllSpaces, .stationary, .ignoresCycle]`, `ignoresMouseEvents`, frame = `screen.frame`.
  - Never key or main; `constrainFrameRect` is overridden so it also covers the menu bar strip.
  - Holds one `AVPlayerLayer` with `.resizeAspectFill`.
  - `isCovered` comes from `occlusionState`.
- `WallpaperPlayer`: `AVQueuePlayer` plus `AVPlayerLooper`, muted, `preventsDisplaySleepDuringVideoPlayback = false`, no external playback.
- `WallpaperConditionsMonitor`:
  - Screen lock: `com.apple.screenIsLocked` / `Unlocked` distributed notifications, with the starting state from `CGSessionCopyCurrentDictionary`.
  - Sleep: `screensDidSleep` / `Wake` and `willSleep` / `didWake`.
  - Battery: an IOPowerSources run-loop source in common modes, whose callback context is retained until `stop()`.
  - Low Power Mode: `NSProcessInfoPowerStateDidChange`.
  - Runs only while at least one wallpaper window exists.
- `StillFrameWriter`:
  - Takes the frame at 1 s with `AVAssetImageGenerator`, off the main thread, and writes a PNG to `<support>/Wallpaper/stills/`.
  - Remembers the display's current picture, then calls `NSWorkspace.setDesktopImageURL(_:for:options:)` with fill scaling.
  - `restore` / `restoreAll` put the previous picture back.
  - `removeUnused` only ever deletes Orbit-named stills in that folder.
- `WallpaperManager`:
  - One window per connected display with a playable wallpaper, and one player per distinct source, shared between displays.
  - Applies the pause policy per display.
  - Rebuilds on `didChangeScreenParameters` and on settings changes; re-evaluates on occlusion, Space changes and monitor events.
  - `stop()` closes every window and releases players, observers and the monitor, and restores nothing else.
  - `WallpaperVideoFile` handles bookmark creation and resolution.
- `WallpaperModel` / `WallpaperThumbnails`: the view model (live or fixture), plus a thumbnail cache. Aerials use `thumbnails/<id>.png`; videos (and aerials without a thumbnail) get a frame from `AVAssetImageGenerator`, kept in memory.
- `WallpaperPanelView`:
  - One tile per connected display: a 16:9 preview (desaturated with a pause badge while paused), the display name, a "Choose…" `PanelMenuButton`, the source name, and a status line ("● Playing · Aerial · Landscape" or "Paused · Hidden behind a window").
  - A footnote: "4 Apple aerials downloaded on this Mac. Get more".
  - The Choose… menu offers Video File…, Your Videos, the aerials grouped by category with a check mark on the current one, and None.
- `WallpaperSettingsView` has four sections: Displays (including unplugged displays that still have a wallpaper, marked "Not connected"), Playback (the two pause switches), Desktop picture (the still-frame switch) and Apple aerials (the list, plus Open Wallpaper Settings…).
- `WallpaperFeature`:
  - Replaces the stub. `init` only loads `WallpaperSettings`; `start()` creates the manager.
  - `stop()` stops the manager, then `stills.restoreAll()`.
  - The live model is created lazily, on the first panel or Settings view.
  - `snapshotViews()` uses `SnapshotFixtures.defaults()` and fixture data.

## Tests (TDD evidence)

`Tests/OrbitCoreTests/WallpaperTests.swift` has 29 tests in 4 suites. Every test name the brief asks for is present.
- `AerialCatalogTests` (8): `parsesEntriesJSON`, `localizedNameWins`, `ordersByCategoryThenManifestOrder`, `badManifestGivesNothing`, `readsLocTablePreferringTheUsersLanguage`, `readsStringsBundleInEitherLayout`, `locationsCoverBothLayouts`, `onlyDownloadedAerialsOffered`. The fixture copies the real `entries.json` keys: `assets[].id/accessibilityLabel/localizedNameKey/categories/shotID/previewImage/url-4K-SDR-240FPS/...`, plus the top-level `categories`.
- `WallpaperAssignmentsTests` (5): `assignmentsRoundTrip`, `sourceIdentityIgnoresTheBookmark`, `adoptsAssignmentWhenDisplayKeyChanges`, `adoptNeverStealsAnotherDisplaysWallpaper`, `listsVideosAssignedAnywhere`.
- `WallpaperPausePolicyTests` (11), for review focus 5:
  - Pause rules: `playsOtherwise`, `pauseWhenCovered`, `pauseWhenLocked`, `pauseWhenAsleep`, `pauseOnBatteryOnlyIfEnabled`, `pauseInLowPower`, `strongestReasonIsReported`, `sharedPlayerPlaysWhileAnyDisplayPlays`.
  - Window plan: `windowForRemovedDisplayCloses`, `onlyAssignedConnectedDisplaysWithPlayableSourcesGetWindows`, `changedSourceSwapsInPlace`.
- `WallpaperSettingsTests` (5): `settingsRoundTrip`, `remembersOnlyTheFirstDesktopPicture`, `restoresOnlyWhileOrbitsStillShows`, `stillFrameNames`, `recognisesOrbitsOwnStills`.

Each unit was RED first: tests written, then `swift build --build-tests 2>&1 | grep error:`.
- Unit 1: `error: cannot find 'AerialCatalog' in scope` (saved at `scratchpad/wallpaper-13/red-1-catalog.txt`).
- Unit 2: `error: cannot find 'DisplayRef' in scope`, `cannot find 'WallpaperAssignments' in scope`.
- Unit 3: `error: cannot infer contextual base in reference to member 'screenLocked'` / `'aerial'` (the policy types didn't exist yet).
- Unit 4: `error: cannot infer contextual base in reference to member 'video'`, `'nil' requires a contextual type` (no `WallpaperSettings` / `StillFrame` yet).

GREEN, each with `swift test --filter <Suite>`:
- `AerialCatalogTests`: "Test run with 8 tests in 1 suite passed".
- `WallpaperAssignmentsTests`: 5 passed.
- `WallpaperPausePolicyTests`: 11 passed.
- `WallpaperSettingsTests`: 5 passed.
- At the end, `swift test --filter "Wallpaper|AerialCatalog"`: "29 tests in 4 suites passed".

Full suite before each commit:
- Commits 1–3: 569 → 574 → 585 tests, all passing.
- Since then, 591 tests with two failures at times. Neither involves Wallpaper code; both come from load on a machine where seven other agents run test suites at the same time:
  - `VideoToolTests.compressMKV`: the hardware encoder was busy (`-12903`, "the hardware encoder may be busy").
  - `ProcessTests.cancellationTerminates`: took 3.72 s against a 3 s bound.
  - Both pass when re-run alone: "Test run with 2 tests in 2 suites passed".

Builds:
- `swift build` is clean, with no warnings in Wallpaper files.
- `swift build -c release --arch arm64 --arch x86_64` reports "Build complete!", exit 0. The log is at `scratchpad/wallpaper-13/release-build.txt`.

I also checked the parser against Kevo's real manifest, read-only: I compiled `AerialCatalog.swift` with a scratch driver, outside the repo. It found 156 assets, 699 strings, and categories Cityscape, Earth, Landscape, Mac and Underwater. It took 23 ms.

## Aerials downloaded on Kevo's Mac

All four are in `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`, and each has a `thumbnails/<id>.png`:
- **Tahoe Day** (Landscape), `4C108785-A7BA-422E-9C79-B0129F1D5550`
- **Sequoia Sunrise** (Landscape), `6D6834A4-2F0F-479A-B053-7D4DC5CB8EB7`
- **Oregon Sunset** (Landscape), `8A57476A-E177-4AAD-B317-643F681584E1`. Its `accessibilityLabel` is "China Beach, Curry County, Oregon"; the localized name wins.
- **Alaskan Jellies Light** (Underwater), `C7AD3D0A-7EDF-412C-A237-B3C9D27381A1`

The macOS 14/15 folder `/Library/Application Support/com.apple.idleassetsd/` doesn't exist on this Mac.

## Snapshots checked

All in `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/wallpaper-13/`:
- **Final:** `final-panel-light.png`, `final-panel-dark.png`, `final-settings-light.png`, `final-settings-dark.png`.
- **Iterations:** `panel-1(-dark).png`, `panel-2.png`, `settings-1(-dark).png`, `settings-2-dark.png`.
- **Whole page:** `settings-tall-1.png`. I made it by temporarily changing the settings snapshot size in `SuiteSnapshot.swift`; that edit was reverted with `git checkout` and never committed.

The panel fixture is Kevo's four displays in left-to-right order:
- K272HUL: no wallpaper.
- P27u-20 (1): Tahoe Day, playing.
- Q27G4ZD: the video "Rain on glass", paused, hidden behind a window.
- P27u-20 (2): Alaskan Jellies Light, playing.

The aerial thumbnails are the real ones from the manifest folder, read-only; the video uses a drawn stand-in.

Two changes came from the iterations:
- The pause label shrank from "Covered by a full-screen window" (it truncated) to "Hidden behind a window".
- The settings rows split into a title line and a status line.

## [builder's call]s

1. **Display key.** I used the shell's `DisplayIdentity.key` (the CG display UUID, with vendor-model-serial only when there's no UUID) rather than the brief's vendor-model-serial. My read-only probe shows both P27u-20 report vendor 12462, model 25291, serial **0**, so vendor-model-serial would put both twins under one key. Their CG UUIDs differ (`3E97987E…`, `6F400F72…`). The brief's "fallback to localized name" is `WallpaperAssignments.adopt`: a connected display with no wallpaper of its own takes over an assignment saved under its name whose key isn't connected. It never takes a connected display's assignment, and the remembered desktop picture moves with it.
2. **Aerial naming and grouping.**
   - Names: the localized name, then the label, then the shot id, then the id.
   - Locale: the loctable picks the user's language with English as a per-key fallback, and the non-locale `LocProvenance` entry is ignored.
   - Category: the localized category name. Without strings it is the key minus its `AerialCategory` prefix, e.g. "Landscapes".
   - Order: category, then manifest `preferredOrder`, then manifest order.
3. **"Downloaded"** means `<id>.mov` is a regular file larger than 0 bytes, so an interrupted download is not offered.
4. **macOS 14/15 layout (unverified, no such Mac here):**
   - `Customer/entries.json` and `Customer/TVIdleScreenStrings.bundle` (loctable or lproj strings).
   - Videos looked for in `4KSDR240FPS`, `4KSDR`, `2KSDR240FPS`, `2KSDR`, `4KHDR240FPS`, `2KHDR240FPS`.
   - No thumbnails folder; thumbnails are generated from the video.
5. **Pause precedence:** display asleep > screen locked > covered > Low Power Mode > battery. Labels: "Display asleep", "Screen locked", "Hidden behind a window", "Low Power Mode", "On battery".
6. **"Covered"** means the window's occlusion state is not visible, but only once macOS has reported the window visible at least once. If occlusion is never reported for a desktop-level window, it keeps playing instead of freezing. It also pauses when an ordinary window covers the whole display, which nobody can see anyway.
7. **Shared player.** Displays showing the same source (by `identity`) share one `WallpaperPlayer`, i.e. one decoder. It plays while any of its displays plays.
8. **Still frames:**
   - Files are PNGs of the frame at 1 s at full video resolution, named `aerial-<id>.png` or `video-<FNV-1a(path|mtime)>.png`, so a replaced or moved video gets a new file.
   - Each is set with proportional scaling and clipping, so it fills the screen.
   - A still is set when a window opens or changes source, and on every window when the still-frame switch is turned on. It is **not** set on every rebuild, so a picture Kevo picks by hand isn't overwritten at the next screen change.
   - Displays sharing a source share one write.
9. **Restoring the desktop picture:**
   - When it happens: a display's wallpaper is removed (None), still frames are turned off, or Wallpaper stops. `stop()` also runs at quit, so quitting Orbit restores too, as the SuiteFeature contract's "restore any system state" asks.
   - Only the first picture before Orbit's still is ever remembered.
   - It is put back only if the display still shows Orbit's still. If Kevo chose another picture since, his choice stays and the entry is dropped.
   - An unplugged display keeps its entry and is put back when it returns, either on the next rebuild or at the next start.
10. **Still cleanup:** delete Orbit-named stills that no saved assignment uses (connected or not) and that no connected display currently shows.
11. **Video files:**
    - `NSOpenPanel` restricted to `.movie`, opened after closing the menu bar panel.
    - The file is checked with `AVURLAsset.load(.isPlayable)`; an error toast appears if it can't play.
    - Orbit isn't sandboxed, so it saves a plain bookmark, resolved with `.withoutUI` / `.withoutMounting`. The saved path is the fallback.
    - A moved or stale bookmark is refreshed and saved, at most once per file per run, so a bookmark that keeps reporting stale can't loop.
12. **Thumbnails** for videos are kept in memory only (a frame at 1 s, at most 480×270), not on disk.
13. **Panel layout:**
    - The menu button is labelled "Choose…" (the brief's wording), and the source name sits on its own line.
    - Displays are listed left to right by screen frame (top first on a tie), not in `NSScreen` order, which helps tell the twin P27u-20s apart.
    - A footnote shows the aerial count and a "Get more" link to `x-apple.systempreferences:com.apple.Wallpaper-Settings.extension`.
    - A "Your Videos" section in the menu lists videos already assigned to any display.
14. **Settings stay editable while Wallpaper is off.** Choices are stored and applied when it's turned on. Desktop pictures left from a None chosen while it was off are put back at the next start.
15. **Small window details:** title "Orbit Wallpaper", black background, shown with `orderFrontRegardless()`.
16. **`WallpaperSettings.previousDesktopPictures`** stores URL strings (`absoluteString`) only. A restore reapplies the display's current desktop image options, falling back to fill.

## Shell changes

None committed. The only shell-adjacent change is the rebase onto `claude/suite-77e4bb`, needed to use `SnapshotFixtures`.

## Needs hardware verification

During development I never launched Orbit, never opened a wallpaper window and never set a desktop picture. All of this is still unverified:
- **Window level on macOS 26, on all four displays:** the window should sit above the system wallpaper and below the desktop icons. If the system's own wallpaper draws over it, try `desktopWindow + 1`.
- **Spaces and Mission Control:**
  - The window should show on every Space.
  - Switching to a full-screen app's Space should pause playback, through occlusion.
  - Mission Control should show the still.
  - `setDesktopImageURL` probably applies only to the **current Space**, so other Spaces may keep the old picture during switches.
- **Occlusion reporting** for a desktop-level window behind Finder's transparent desktop window: does `occlusionState` ever report `.visible`? If not, the safeguard in call 6 keeps it playing, but full-screen pausing then never happens.
- **Pause and resume** on screen lock and unlock, display sleep and wake, system sleep, the Low Power Mode toggle, and battery power (the Mac is currently closed and on AC).
- **Unplugging and replugging a display:** its window should close and come back. Check the twin P27u-20 keys survive a reboot and a port swap.
- **What gets remembered when the current wallpaper is an Apple aerial:** check what `desktopImageURL(for:)` returns, and so what is remembered and restored.
- **CPU and GPU cost** of up to four 4K HEVC streams, and the saving when two displays share an aerial.
- **Quit, disable and crash:** windows close and desktop pictures come back.

## Known gaps

- **Aerial wallpapers can't be restored as aerials.** If a display was showing an Apple aerial before Orbit, "restore" can only set the image URL macOS reports for it, not re-select the live aerial. There is no public API for that.
- **Still frames only reach the current Space**, because of the public API, as noted above.
- **A crash leaves Orbit's still** as the desktop picture. The remembered picture is kept and put back at the next `stop()`.
- **No manual "pause all" control** (not in the spec).
- **The app layer has no unit tests.** OrbitApp is not a test target; only the pure core is tested, and the app is checked through the snapshots.

## Housekeeping

- I created no `~/Library/Preferences/*.plist`. The only matching files there predate this session: `com.apple.wallpaper*.plist` and Kevo's `com.kevo.orbit.plist`.
- Tests use `Fixtures.defaults()` and temp folders; snapshots use `SnapshotFixtures.defaults()`.
- In the **shared** scratchpad I left a read-only display probe at `probe/displays.swift` and `probe/displays`, which I created before switching to my own `wallpaper-13/` folder. Delete them whenever you like.
- My isolation hook blocked writing this report into the suite worktree, so this copy lives in my scratchpad. If the copy step failed, it is only at `scratchpad/wallpaper-13/wallpaper.md`.
