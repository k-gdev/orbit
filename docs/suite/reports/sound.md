# Orbit Suite — Sound (Task 7): report

(Meant for `/Users/kevog/orbit/.claude/worktrees/suite-77e4bb/docs/suite/reports/sound.md`. My sandbox is limited to
my own worktree, which refused that write, so this copy is in the session scratchpad.)

Branch **`suite/sound`** off `1a84988 docs(suite): shell implementer report`. Not pushed (per instructions).
`swift build` and `swift test` green at every commit. **595 tests** in the final full run (561 at base + 34 new),
all passing. Universal release build `swift build -c release --arch arm64 --arch x86_64` → `Build complete!`,
`lipo -archs` → `x86_64 arm64`, no warnings in new or changed files (debug or release).

| Commit | Subject |
|---|---|
| e5ccd60 | feat(sound): Sound settings and per-app audio preference |
| 73ec8d4 | feat(sound): volume curve, soft clip and gain ramp |
| 84abf23 | feat(sound): tap plan decides when an app needs a process tap |
| 2a729f5 | feat(sound): group helper processes under their app and filter the apps list |
| f7e7edc | feat(sound): device names, icon hints and preferred-mic policy |
| 7288f53 | feat(suite): mic mute state that restores exactly what Orbit changed |
| 2de70c0 | feat(sound): tap renderer copies tap audio to the output with gain and soft clip |
| c16d3bd | feat(suite): hardware mic mute with exact restore, input following and crash recovery |
| 53c41f8 | feat(sound): audio hardware, process monitor, private process taps and the tap engine |
| 42d918c | feat(sound): Sound tab, settings page and feature lifecycle |
| fb1b09c | feat(sound): Same as Output keeps an app on the device it chose itself |

(53c41f8 was also built on its own from a `git archive` export, since it was staged out of a larger working tree:
`Build complete!`.)

## Safety summary (Review Focus 1 and 6)

- **No tap unless needed.** `TapPlan.needsTap` is false for an app at 100 %, unmuted, on the output it would use
  anyway (`TapPlanTests.noTapAtUnityOnDefaultOutput`). There is also no tap without an output device, and none
  without **granted** System Audio Recording: `.unknown` is not enough, because a tap without permission could
  mute an app while delivering silence.
- **Muted only while Orbit reads.** Taps use `muteBehavior = .mutedWhenTapped`, so if Orbit's IOProc stops for any
  reason the app is heard again as usual. Tap (`isPrivate`) and aggregate (`kAudioAggregateDeviceIsPrivateKey: true`)
  are private to Orbit's process, so the system destroys them when Orbit exits, crash included.
- **Teardown.** `AppAudioTap.invalidate()` does AudioDeviceStop + DestroyIOProcID, then destroys the aggregate, then
  the tap. `SoundEngine.stop()` invalidates every tap (and any tap being replaced) and waits for the teardown, bounded
  at 2 s total. `SoundFeature.stop()` runs it when the feature is turned off and from `applicationWillTerminate` via
  `registry.stopAll()`.
- **Fails closed.** Tap creation is abandoned and everything already built is destroyed (the app is left untouched)
  when any of these hold:
  - the tap's format isn't Float32 PCM;
  - the aggregate's input stream layout doesn't match "device inputs + tap channels" (`TapStreamLayout`);
  - the destination device has input streams (Kevo's headset mic) and `kAudioDevicePropertyIOProcStreamUsage` can't
    switch them off. Otherwise its mic would start and show the orange indicator.

  The renderer never reads non-tap buffers anyway (`SoundRenderTests.skipsDeviceInputStreams`).
- **Mic mute.** `MicMuteState` (pure, tested) restores exactly what Orbit changed:
  - It never undoes a mute (or a zero volume) the user had applied before (`doesNotUnmuteUserMute`).
  - It restores on unmute, on going inactive, and on quit (`restoresPreviousState`, `volumeFallbackRestoresVolume`).
  - It follows default-input changes: the old device is restored and the new one muted.
  - If the user unmutes outside Orbit, Orbit drops its mute.
  - Crash recovery: while Orbit has the mic muted, the record is kept at `micMute.pendingRestore` in
    `UserDefaults.standard`. The next launch's first `setActive` (even with Sound and Controls both off) undoes the
    mute, but only if the device is still exactly as Orbit left it.
- **Nothing on this Mac was changed during development.** I never launched Orbit as an app and never created a tap.
  The only hardware access was a scratch **read-only** probe (device list, volumes, mute flags, the process list,
  responsible PIDs, process output devices).

## What was built

### OrbitCore (`Sources/OrbitCore/Sound/`, plus `Suite/MicMuteState.swift`)
- **`SoundSettings`** with keys `sound.pinnedBundleIDs`, `sound.appStates` (JSON), `sound.rememberAppStates`
  (default true), `sound.preferredMicUID`, `sound.keepPreferredMic` (default false) and `sound.showAllApps`. Helpers:
  `preference(for:)`, `setPreference` (unity removes the entry), `pin`/`unpin`/`isPinned`, `forgetAppStates`.
  **`AppAudioPreference`** holds `volume` 0…150 (clamped, NaN → 100), `muted`, `outputUID` (nil = Same as Output),
  `unity` and `isDefault`.
- **`VolumeCurve.gain(forPercent:)`**: 0 → 0, 100 → 1, 150 → 1.5, monotonic. **`SoftClip.apply`**: tanh knee at 0.9,
  never past ±1, symmetric, NaN → 0. **`GainRamp`**: linear per-frame ramp that lands exactly on the target.
- **`TapPlan`**: `needsTap`, `destinationUID`, `gain`, `muted`, `isRoutedAway`, `routeUnavailable`, `isBoosted`. Also
  **`TapPlan.followedOutput(appDeviceUIDs:systemOutputUID:availableOutputUIDs:)`**, which gives "Same as Output" its
  meaning (see the builder's calls).
- **`AudioAppGrouping.appBundleID(processBundleID:responsibleBundleID:processIsApp:)`** and `helperParent(of:)`.
  **`AudioAppCandidate`** and **`AudioAppList.visible(...)`** decide which apps the list shows, in what order.
- **`PreferredMicPolicy.shouldSwitchBack(currentUID:preferredUID:availableUIDs:keep:)`**.
- Device helpers: **`AudioTransport`** (from FourCC), **`AudioDeviceSummary`** (with `symbol(forInput:)`) and
  **`AudioDeviceNaming.displayNames`** (numbers duplicates: Kevo's two "P27u-20").
- **`TapRenderer.render(input:output:tapBuffers:ramp:)`**: the IOProc body. It reads only the tap's buffers, applies
  ramped gain plus soft clip past unity, sends stereo to the first two channels, mixes down for mono outputs,
  duplicates a mono tap, and leaves extra channels and missing frames silent. **`TapStreamLayout.tapBuffers(...)`**.
- **`MicMuteState`** (with `MicDeviceReading` and `MicMuteAction`): `mute`, `restore`, `retarget(to:)`,
  `deviceChanged`, and the static `recoveryActions(for:current:)`. Codable.

### OrbitApp (`Sources/OrbitApp/Features/Sound/`)
- **`SoundHAL`**: typed HAL property helpers. **`SoundHALListener`**: block listener on the main queue, removed in
  `remove()`/deinit.
- **`AudioHardware`**:
  - Reads: devices (UID, name, channel counts, transport); hides hidden devices and Orbit's own
    `com.kevo.orbit.tap.*` aggregates.
  - Defaults: default output, system ("alerts") output and default input, each with get and set.
  - Volumes: output virtual main volume and mute; input virtual main volume.
  - Listeners (devices, defaults, volumes) exist only between `start()` and `stop()`. The setters run only from the
    user's clicks (and the opt-in preferred-mic watcher).
- **`AudioProcessMonitor`** (14.2+):
  - Reads `kAudioHardwarePropertyProcessObjectList`, and for each process its PID, bundle ID,
    `IsRunningOutput` and output `Devices`.
  - Groups processes through `AudioAppGrouping`, using the private `responsibility_get_pid_responsible_for_pid`
    (via `PrivateSymbol`, from `/usr/lib/libSystem.B.dylib`) and `NSRunningApplication`.
  - Excludes Orbit's own PID. Listeners exist only while the engine asks for them.
- **`AppAudioTap`** (14.2+):
  - Built from `CATapDescription(stereoMixdownOfProcesses:)` with `.mutedWhenTapped` and `isPrivate`, then
    `AudioHardwareCreateProcessTap`.
  - The private aggregate has the destination as main sub-device plus the tap (drift compensation, TapAutoStart).
    The IOProc block runs on the HAL IO thread, and input stream usage is restricted to the tap.
  - All HAL work for one tap runs on that tap's own serial queue.
  - `setGain` is a single aligned Float write that the IO thread reads.
- **`SoundEngine`** (14.2+):
  - Keeps taps keyed by bundle ID and runs `TapPlan` per app on every change: preferences, default output, device
    list, processes, permission.
  - On each pass it creates, retargets (new tap first, then the old one is released), updates gain or releases.
  - Back at 100 % on the same device, a tap plays at unity for 1 s before release, so dragging across 100 doesn't
    rebuild it. A failed build is not retried with identical parameters. `stop()` waits for the teardown.
- **`PreferredMicWatcher`**: switches the input back while Keep is on; at most one switch per 2 s.
- **`SoundPanelModel`** (with `SoundPanelActions` implemented by the feature), `SoundAppDirectory` (names and icons),
  and `SoundFixtures` (Kevo's devices from hardware.md, the mockup's apps).
- **`SoundPanelView`** (structure per the mockup's Sound tab):
  - "Output & Input" header. Output tile: device menu, master volume pill (DisplayPort devices show a dimmed
    "Fixed" pill), and an "Alerts & system sounds" row with its own device menu.
  - Microphone tile: device menu, input level pill, mute `PanelRoundButton` bound to `context.micMute`, and the
    "Muted · ⌃⌥M to unmute" caption.
  - "Apps" header with the "Show all apps" / "Show fewer" link.
  - One 0–150 pill per app: icon (click = mute), name, `LevelBars` while playing or a pin when pinned and quiet.
    Beside it, a `PanelRoundMenu` "Play <App> on" offering Same as Output (device name) or any output device, with
    an accent ring when routed and a warning icon when the routed device is unplugged.
  - Context menu: Pin/Unpin, Reset.
  - Notices: "Allow per-app control" (button → `PermissionCenter.request(.systemAudioRecording)`), "needs
    macOS 14.2", "No apps are playing sound".
- **`SoundSettingsView`**: Microphone section (preferred mic and Keep), Mute Shortcut (`KeyComboRecorder` on the
  shared `MicMuteSettings`, with a conflict message from `HotKeyCenter.owner`), Apps section (remember toggle,
  pinned list with Add App from running Dock apps and remove, Forget All App Settings).
- **`SoundFeature`**:
  - `init` only loads settings.
  - `start()` starts the hardware listeners, the engine (with the current permission) and the mic watcher. It
    observes `context.permissions.$statuses` (controller note 2), so taps begin when the grant arrives.
  - `stop()` stops the engine (waiting), then the watcher, then the hardware.
  - `panelDidAppear`/`Disappear` gate the process listening and the model refresh.
  - `snapshotViews()` uses fixtures only, with throwaway absolute-path defaults suites (controller note 1).

## Files
New:
- `Sources/OrbitCore/Sound/{SoundSettings,VolumeCurve,TapPlan,AudioAppGrouping,AudioDevices,TapRenderer}.swift`
- `Sources/OrbitCore/Suite/MicMuteState.swift`
- `Sources/OrbitApp/Features/Sound/{SoundHAL,AudioHardware,AudioProcessMonitor,AppAudioTap,SoundEngine,SoundModel,SoundPanelView,SoundSettingsView}.swift`
- `Tests/OrbitCoreTests/SoundTests.swift`, `Tests/OrbitCoreTests/SoundRenderTests.swift`

Replaced: `Sources/OrbitApp/Features/Sound/SoundFeature.swift` (stub → real feature; class name and
`init(context:)` kept).

Changed: `Sources/OrbitApp/Suite/MicMuteService.swift` (hardware part only; see Shell changes).

## Tests and TDD evidence
Every unit was RED (`swift test --filter SoundTests` or `--filter SoundRenderTests`), then implemented, then GREEN,
then the full `swift test`, then committed.

| Unit | RED (compile errors, counts) | GREEN |
|---|---|---|
| SoundSettings | `cannot find 'SoundSettings' in scope` ×18, `cannot find 'AppAudioPreference' in scope` ×20+ | `✔ Test run with 2 tests in 1 suite passed` |
| VolumeCurve / SoftClip / GainRamp | `cannot find 'SoftClip'` ×24, `'VolumeCurve'` ×18, `'GainRamp'` ×2 | 6 tests in 1 suite |
| TapPlan | `cannot find 'TapPlan' in scope` ×34 | 12 tests in 2 suites |
| Grouping + AppList | `cannot find 'AudioAppList'` ×8, `type 'AudioAppGrouping'` ×4, `'AudioAppCandidate'` ×4 | 14 tests in 2 suites |
| Devices + PreferredMicPolicy | `'PreferredMicPolicy'` ×14, `'AudioTransport'` ×14+2, `'AudioDeviceSummary'` ×12+2, `'AudioDeviceNaming'` ×2 | 17 tests in 2 suites |
| MicMuteState | `cannot find 'MicMuteState'` ×36, `'MicDeviceReading'` ×20 | 23 tests in 3 suites |
| TapRenderer | `cannot find 'TapRenderer' in scope` ×4 | 32 tests in 4 suites |
| TapStreamLayout | `cannot find type 'TapStreamLayout' in scope` ×4 | 33 tests in 4 suites |
| Apps order (mockup) | 3 expectation failures, e.g. `pinned.map(\.name) → ["RingCentral","Spotify","Google Chrome","Music","Slack"]` | 33 tests in 4 suites |
| followedOutput | `type 'TapPlan' has no member 'followedOutput'` ×14 | 34 tests in 4 suites |

Notes on the table:
- The MicMuteState tests first used `#expect(state.mute(x) == …)`. The `#expect` macro can't call mutating methods,
  so I rewrote those lines through locals (`let r1 = state.mute(x); #expect(r1 == …)`); behaviour unchanged.
- Test names:
  - `SoundTests`: `settingsRoundTrip`, `settingsRejectBadData`, `gainEndpoints`, `gainMonotonic`, `softClipBounded`,
    `gainRampConverges`, `helperGroupsUnderApp`, `visibleAppsFilterAndOrder`,
    `preferredMicSwitchBackOnlyWhenAvailable`, `duplicateDeviceNamesAreNumbered`, `deviceIconHints`.
  - `SoundTests.TapPlanTests`: `noTapAtUnityOnDefaultOutput`, `tapWhenBoosted`, `tapWhenRoutedElsewhere`,
    `noTapWhenRoutedToCurrentDefault`, `routedDeviceMissingFallsBack`, `sameAsOutputFollowsTheAppsOwnDevice`,
    `noTapWithoutOutput`.
  - `SoundTests.MicMuteStateTests`: `restoresPreviousState`, `volumeFallbackRestoresVolume`, `doesNotUnmuteUserMute`,
    `followsInputChange`, `externalUnmuteClearsState`, `crashRecoveryRestoresOnlyIfUnchanged`.
  - `SoundRenderTests`: `unityPassesThrough`, `rendersGainAndClip`, `mutedWritesSilence`, `gainRampsAcrossTheBuffer`,
    `skipsDeviceInputStreams`, `monoOutputMixesDown`, `extraOutputChannelsStaySilent`, `nonInterleavedBuffers`,
    `tapStreamLayout`, `shortInputLeavesSilentTail`.
- **Flakes under load.** Load average ran around 70 from the parallel agents. Some full runs failed
  `ProcessTests.cancellationTerminates` (3 s timing bound, measured 3.2–3.7 s) and VideoToolbox tests (`compressMKV`,
  `cropMKV`, `proxyIsCached`, ...: ffmpeg `err=-12903`, "The hardware encoder may be busy"). Each passed when re-run
  alone, and the final full run is green (595/595). These suites are untouched by this task.

## Snapshots checked (light and dark, looked at each)
All under
`/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/snap/`:
- `sound-2.png` and `sound-2-dark.png`: final panel. It matches the mockup's Sound tab: Discord 85 %, Chrome 130 %
  boosted and routed to the MacBook speakers (laptop icon, accent ring), Music 60 %, RingCentral pinned, Slack muted
  and pinned, mic muted with "Muted · ⌃⌥M to unmute".
- `sound-1.png` and `sound-1-dark.png`: first iteration (pinned-first order, slashed mic in the pill), both fixed.
- `sound-perm.png`: the "Allow per-app control" state (from a temporary fixture edit, reverted).
- `sound-settings-1.png` and `sound-settings-1-dark.png`: the settings page.
- `sound-settings-apps.png`: the below-the-fold Apps section (pinned rows, Add App, Forget All App Settings), from a
  temporary render offset, reverted.

The temporary edits were backed up and restored with `cp` from the scratchpad (files created in this task only).

## [builder's call] decisions
1. **Volume curve.** Square law below 100 (50 % ≈ −12 dB), linear 100 → 150 (1.5× ≈ +3.5 dB). The soft clip (tanh
   knee at 0.9) applies only while the gain is past 1.
2. **Ramp.** Linear, 480 frames per unit of gain (≈ 10 ms at 48 kHz). A new tap starts at its target gain, with no
   fade-in.
3. **Stored states.** Unity per-app states aren't stored. With "remember" off, the stored copy is deleted and states
   live for the current run only; turning it back on saves the run's states.
4. **"Same as Output"** means the device the app plays on by itself: its processes' single connected output device
   (`kAudioProcessPropertyDevices`), otherwise the system output. An app that chose a device in its own settings
   (Discord, Teams) is therefore never moved by a volume change, and a route to its own device needs no tap. The row
   menu shows "Same as Output (<that device>)".
5. **Unplugged route.** A route to an unplugged device falls back to the followed output (the row shows a warning
   icon). With no output device there is never a tap.
6. **Taps require `.granted` System Audio Recording**, never `.unknown`.
7. **Grouping.** A regular app keeps its own ID. Otherwise the process goes to its responsible app, then to the
   `…helper…` / `…-helper` prefix, then to its own ID. On this Mac, Cursor's `com.anysphere.sand.electron-helper`
   only groups correctly through the responsible PID.
8. **Apps list order**, as in the mockup: playing apps by name, then quiet pinned apps in pinned order, then the rest
   by name.
   - Listed: Dock and menu bar apps only (daemons appear only if pinned); never Orbit.
   - A running app with custom settings stays listed while silent, so a muted app is visible.
   - Pinned apps that aren't running are listed (name and icon from NSWorkspace), and their settings apply when they
     start.
9. **TapAutoStart and queues.** `kAudioAggregateDeviceTapAutoStartKey: true` as the brief says. The SDK header says
   `AudioDeviceStart` "will wait until a tapped process begins receiving its first audio", so all HAL work runs per tap
   on its own serial queue (never the main thread), and `stop()` waits at most 2 s total.
10. **Replacing a tap.** The new tap starts before the old one is released (a brief overlap instead of an unattenuated
    blip).
11. **Unity grace.** Back to 100 % on the same device, a tap plays at unity for 1 s, then is released.
12. **Failed builds** are not retried for the same app, device and processes. Failures are forgotten on a device-list
    or permission change.
13. **Tap scope.** A tap covers every audio process of the app, not just the playing ones. A new process triggers a
    rebuild.
14. **Process-list listening** runs while the panel is visible, a tap exists, **or an app has non-default settings**,
    so stored settings apply as soon as the app starts. The brief said panel or tap; HAL listeners cost nothing until
    they fire.
15. **Level bars** animate generically while `IsRunningOutput` (controller ruling); no RMS.
16. **Output pill.**
    - Devices without volume control show a dimmed "Fixed" pill.
    - Raising the volume while the output is muted also unmutes it, like the volume keys.
    - A muted output shows "Muted".
17. **Alerts menu** lists every output device; there is no "follow output" item (the HAL has no such property).
18. **Mic tile.** Caption variants: "On · ⌃⌥M to mute", "No microphone", "This microphone can't be muted". The pill
    keeps the plain mic icon; the round button carries the slash.
19. **Choosing a mic in the panel while Keep is on** makes it the preferred mic, so Orbit doesn't fight an explicit
    choice. The watcher also switches back when the preferred mic reconnects.
20. **Duplicate device names** are numbered ("P27u-20 (2)"). Icons: laptop (built-in), headphones (headsets,
    Bluetooth, AirPods by model), display (DP/HDMI), waveform (virtual), speaker or mic otherwise.
21. **Small UI choices.**
    - Row context menu: Pin/Unpin, "Reset to 100 %, Same as Output".
    - The header link toggles "Show all apps" ↔ "Show fewer".
    - Settings has a "Forget All App Settings" button.
22. **How the mic is muted.**
    - It prefers the mute control: the main element, else every settable channel.
    - Fallback: input volume 0 (virtual main volume, else volume scalar).
    - The restore record survives a crash in `micMute.pendingRestore` (UserDefaults.standard, `micMute.` prefix like
      the shared shortcut).
23. **Snapshot fixture.** Mic muted (as in the mockup), Kevo's real device names, the mockup's apps drawn as SF Symbol
    tiles (deterministic, no app icons read).

## Shell changes
- **`Sources/OrbitApp/Suite/MicMuteService.swift`**: only the hardware part the brief assigns to Sound.
  - The public API is unchanged: `isMuted`, `isAvailable`, `settings`, `init(hotKeys:settings:)`,
    `fixture(muted:available:)`, `setMuted`, `toggle`, `setActive`, `restoreOnQuit`, `hotKeyID`.
  - Additions:
    - `init` gained a defaulted `restoreDefaults: UserDefaults = .standard`.
    - New constant `pendingRestoreKey`.
    - `setActive` first calls the one-time crash recovery, then starts or stops listening (default input, device
      list, and the muted device's mute/volume).
    - `restoreOnQuit` stops listening.
    - The three stubs are implemented.
    - Private `MicHAL` and `MicHALListener` are kept in the file, so the shared mute has no dependency on the Sound
      folder and no tap code.
- `Sources/OrbitCore/Suite/MicMuteState.swift`: new, as the brief asks.
- Nothing else outside the owned folders.

## Needs hardware verification on Kevo's Mac
1. **Turning Sound on** shows the System Audio Recording prompt. Once it is granted, the Apps list switches from
   "Allow per-app control" to sliders (PermissionCenter polls for 2 min).
2. **Taps, with Chrome playing:**
   - 50 % (quieter), 150 % (louder, no harsh clipping), mute (silent), back to 100 % (the tap goes away after about
     1 s; `Orbit.log` shows "released com.google.Chrome").
   - Route Chrome to the MacBook Pro Speakers while the headset is the default.
   - **No orange mic indicator** when an app is routed to the headset (the stream-usage switch). If the log says
     "couldn't switch off the output device's own input streams", the tap failed closed instead.
3. **The `AudioDeviceStart` wait (TapAutoStart)**: mute a *silent* app and check its tap starts when it next plays.
   Log line timing: "tapped …".
4. **Turning Sound off, quitting, and `kill -9` Orbit** while an app is tapped: the app must play normally right away.
5. **`pmset -g assertions`** while an app is tapped: a running aggregate may hold off idle sleep.
6. **Same as Output following an app's own device**: set Discord's output to the headset in Discord and the system
   output to the speakers, then change Discord's volume; it must stay on the headset. At probe time no process had
   running output, so the per-process device lists were empty, as expected.
7. **Grouping on real playing processes**: Chrome's audio helper → Chrome; Safari's WebKit GPU process → Safari;
   Discord helpers → Discord.
8. **Mic mute on the Arctis Nova 5** (the probe shows a settable input mute):
   - ⌃⌥M toggles; the badge appears; unmute, Sound off and quit all restore.
   - Changing the input while muted moves the mute to the new mic.
   - Unmuting in System Settings clears Orbit's mute.
9. **Master volume and input level pills**; the DisplayPort outputs show "Fixed". The Alerts menu changes the system
   output.
10. **Keep preferred microphone**: switch input in System Settings and it comes back.

## Known gaps
- **No real per-app level meter**: bars animate while the app is playing.
- **Taps are unverified on hardware.** By rule, no tap was created during development; the tap path compiles, is
  gated (macOS 14.2, `.granted`, `needsTap`) and fails closed.
- **Sleep impact.** A tapped app keeps its aggregate device for as long as the app is an audio client, so a running
  aggregate may prevent idle system sleep (unverified).
- **TCC status.** If the private TCC preflight disappears in a future macOS, the status stays `.unknown` and per-app
  control can't turn on (fail-safe).
- **External unmute detection** listens on the main element only. A mic with per-channel-only mute won't report an
  outside unmute; Orbit's state corrects on the next toggle.
- **App processes launched later** (a new Chrome helper) cause a tap rebuild, with a brief overlap.
- **Two small departures from the mockup.** The muted row's value is the text "Muted" without the mockup's speaker
  glyph (`PillSlider.valueText` is a string). The per-app round buttons use the shared `PanelRoundMenu` track fill,
  where the mockup shows white.
- **Settings page fold.** At the 760×560 snapshot size the settings Apps section sits below the fold; it scrolls in
  the real window.
- **No stray preference files.** No `~/Library/Preferences/*.plist` was created by my runs (checked with `find` for
  anything newer than the worktree): tests use `Fixtures.defaults()`, snapshots use absolute-path suites in the temp
  folder.

## Fix round 1

Seven commits on `suite/sound` on top of fb1b09c. Not pushed. No taps were created and no device, volume or mute
was changed (no app launched; only tests and headless snapshots ran).

| Commit | Subject | Review items |
|---|---|---|
| 20971c0 | fix(sound): refuse tap stream layouts that can't be told apart | M5 |
| 59673f4 | fix(sound): Same as Output remembers an idle app's device | I2 |
| 3dc66e8 | fix(sound): pause a tap's aggregate while its app is quiet | I3 |
| 4a46a80 | fix(suite): mic mute never loses its record; shows the live state | I1, M3, M1, M2 |
| 8c47eae | fix(sound): show a failed tap in the app's row | M6 (+ shorter M2 caption) |
| 5c801c4 | fix(sound): write per-app volume once a drag ends | M7 |
| f194ceb | fix(sound): retry a throttled mic switch; re-watch re-enumerated devices | M8, M9 |

I1, M3, M1 and M2 share one commit because they rewrite the same state type and the same service flow; I couldn't
split them into commits that each build alone.

### What changed

**I1: a failed unmute is no longer swallowed.**
- `MicMuteState` (Core): undoing is now two steps.
  - `restoreActions()` is non-mutating: it returns what to write and forgets nothing.
  - `commitRestore()` forgets the record once every write took. (`restore()` remains as a convenience that does
    both.)
- `MicMuteService.restoreOrbitMute()` returns success and handles three cases:
  - **Write fails** (e.g. hog mode): the state, `isMuted`, the badge and the defaults record all stay; returns
    false.
  - **Device gone**: the record is set aside in `pending` (see M3); returns true.
  - **Success**: commit, then save or clear the record.
- `setMuted(false)` uses it.
- `setActive(false)` undoes only Orbit's own mute. The badge stays while that mute is still in effect: the badge
  rule is `(active && isMuted) || state.isMuted`. Clicking the badge while inactive retries. Default-input and
  device-list events also retry while inactive.
- `restoreOnQuit()` tries the undo and the pending records, then `saveRecord()`. Whatever couldn't be undone stays
  in `micMute.pendingRestore` for the next launch.
- A failed *mute* write is put back (`restoreActions`) or, if that fails too, set aside.

**M3: a muted device that disappears keeps its record.**
- `MicMuteState.pending` holds mutes on devices that went away (`setAside()`).
- `pendingWork(reading:)`: per connected pending device, the actions that undo it. The list is empty when the user
  changed the device meanwhile (resolve without writing). Disconnected devices are left out, so the record keeps
  waiting.
- `resolvePending(deviceUID:)`.
- `mute(_:)` on a device still pending inherits its original state, so the later unmute really unmutes.
- Following an input change (`followInput()`): the old mic is restored if it is connected and the write takes;
  otherwise it is set aside. Then the new mic is muted.
- Launch after a crash or failed quit: `MicMuteState.fromPreviousRun(record)` turns everything pending. Devices
  present now are processed; the rest keep their record. System listeners (default input and device list) stay
  installed while `state.hasRecord`, even with Sound and Controls off, so an unplugged mic is unmuted when it comes
  back.
- The record decodes the earlier format (no `pending` key).

**M1:** `restoreOnQuit()` sets `shortcutSubscription = nil`.

**M2: live state.**
- `isMuted` is now the input device's live state: Orbit's mute, or the device's own mute control being on.
- New published `isMutedByOrbit`.
- `MicMuteState.presentation(for:)` returns `.unavailable`, `.unmuted`, `.mutedByOrbit` or `.mutedElsewhere`.
- While active, the service listens to the current input device's mute and volume. Listeners attach by object ID,
  so they are re-attached on re-enumeration.
- Unmuting a mute made elsewhere is a direct user action (`MicMuteState.directUnmute`). Orbit never undoes it on
  its own: going inactive and quitting only touch Orbit's mute.
- The Sound tab's caption reads "Muted outside Orbit", and the badge tooltip differs.
- The public API is unchanged apart from two additions: `isMutedByOrbit`, and `fixture(... mutedElsewhere:)` with a
  default value.

**I2: Same as Output survives idle.**
- New `AppOutputMemory` (Core) keeps each app's last non-empty output devices while it has audio processes, and
  forgets them when the processes are gone.
- `SoundEngine` observes every app on each pass, and `followedOutput(for:)` plans with the remembered devices.
- The old `[] → system output` assertion still holds for `followedOutput` itself, meaning "nothing ever reported";
  its comment now says so.

**I3: idle taps stop doing IO.**
- New `TapActivity` (Core): after `idleDelay` (5 s) with `IsRunningOutput` false it returns `.pause`, once per quiet
  spell, and `nextCheck()` gives when to look again.
- `SoundEngine` tracks one `TapActivity` per tap, updated on every pass (IsRunningOutput changes come through the
  monitor), with a single one-shot `DispatchWorkItem` for the next check; there is no polling timer.
- `AppAudioTap.pauseUntilNextAudio()` runs on the tap's queue: `AudioDeviceStop`, then `AudioDeviceStart` again
  (TapAutoStart: IO resumes with the app's next audio). Tap and aggregate stay.
- While the queue waits in that start, `isWaitingForAudio` is true and `SoundEngine.stop()` doesn't wait on it: its
  IO isn't running, so the app isn't muted, and the queued teardown runs right after.
- A failed re-arm reports through the tap's `onFailure`; the engine invalidates the tap and marks the app failed
  (see M6).

**M5: refuse ambiguous layouts.** `TapStreamLayout.tapBuffers` returns nil when both "device inputs first" and "tap
first" fit but point at different buffers (e.g. a stereo-input device next to a stereo tap). The tap then fails
closed.

**M6: failed taps show.**
- `SoundEngine.failedBundleIDs` is exposed, and `SoundAppItem.tapFailed` carries it.
- The row shows an orange warning triangle after the app name, and its help text explains the setting isn't
  applied.
- Stale failures are cleared once the app no longer needs a tap.

**M7: no defaults write per drag tick.**
- `SoundSettings.setPreference(_:for:persist:)` with `persist: false` publishes the change (the engine follows it
  live) without writing; `persistAppStates()` writes.
- The app row's pill calls `finishVolumeChange()` from `onEditingEnded`. Closing the panel and stopping the feature
  also flush.

**M8:** `PreferredMicPolicy.retryDelay(lastSwitch:now:)` (Core, 2 s throttle). `PreferredMicWatcher` schedules one
retry when the window ends instead of dropping the change.

**M9:** `AudioHardware` tracks `watchedOutput`/`watchedInput` object IDs and re-attaches its volume and mute
listeners when the object changes, even with the same UID. Devices with no volume control aren't re-tried on every
refresh.

### Covering tests (TDD: RED, then GREEN)

| Test | RED | GREEN |
|---|---|---|
| `SoundRenderTests/ambiguousTapStreamLayoutIsRefused` | 3 expectation failures, e.g. `tapBuffers(aggregateInputs: [2, 2], deviceInputs: [2], tapChannels: 2) → 1 ..< 2` | 11 tests in 1 suite |
| `TapPlanTests/sameAsOutputSurvivesIdle` (play → idle → play, switch device, processes gone, prune) | `cannot find 'AppOutputMemory' in scope` ×2 | 25 tests in 3 suites |
| `TapPlanTests/tapPausesAfterIdleDelay` | `cannot find 'TapActivity' in scope` ×22 | 26 tests in 3 suites |
| `MicMuteStateTests`: `unmuteFailureKeepsRecord`, `deviceGoneKeepsRecordUntilItReturns`, `remutingAPendingDeviceKeepsItsOriginalState`, `liveStateShowsOutsideMute`, and rewritten `followsInputChange` and `crashRecoveryRestoresOnlyIfUnchanged` (includes a legacy-record decode) | `no member 'restoreActions'` ×12, `'commitRestore'` ×6, `'setAside'` ×10, `'pendingWork'` ×8, `'fromPreviousRun'` ×10, `'presentation'` ×16, `'directUnmute'` ×4, ... | `swift test --filter MicMuteStateTests` → 10 tests in 2 suites |
| `SoundTests/settingsDeferWritesDuringDrag` | `extra argument 'persist' in call` ×4, `no member 'persistAppStates'` ×4 | 31 tests in 3 suites |
| `SoundTests/preferredMicThrottleRetriesInsteadOfDropping` | `no member 'retryDelay'` ×16, `no member 'throttle'` ×12 | 32 tests in 3 suites |

The old `MicMuteState.retarget(to:)` and the static `recoveryActions(for: MicMuteState, …)` were replaced by the
primitives above. Their tests were rewritten, and they are no longer used anywhere.

### Commands and output (final)
- `swift test --filter Sound` → `✔ Test run with 46 tests in 6 suites passed` (TapPlanTests, MicMuteStateTests,
  SoundRenderTests, SoundTests, plus AudioTests and VideoConversionTests, which the filter also matches).
- `swift test --filter MicMuteStateTests` → `✔ Test run with 10 tests in 2 suites passed`.
- Full `swift test` (once) → `✔ Test run with 604 tests in 29 suites passed after 83.707 seconds` (595 + 9 new).
- `swift build` after every commit: no errors and no warnings.
- Snapshots (light and dark, looked at), under
  `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/snap/`:
  - `fix1-panel.png`, `fix1-panel-dark.png`, `fix1-settings.png`, `fix1-settings-dark.png`: unchanged from the
    reviewed look.
  - `fix1-failed-elsewhere.png`: a temporary fixture with Music's tap failed and the mic muted outside Orbit. It
    shows the orange warning in the row. The caption wrapped there, so I shortened it to "Muted outside Orbit". The
    fixture edits were reverted from scratchpad backups.
- `swift build -c release --arch arm64 --arch x86_64` → `Build complete!` (no Sound or mic-mute warnings).

### Hardware checklist additions
- **`pmset -g assertions`** with a tapped app playing, then about 5 s after it stops. There should be no coreaudiod
  `PreventUserIdleSystemSleep` assertion once the tap has paused. Orbit's log shows "… is quiet; its output waits
  for the next sound".
- **After a pause**, the app's next sound must again play at its Orbit volume and route. This checks that the
  re-armed TapAutoStart restarts IO. If the first few milliseconds of each sound after a quiet spell come through
  unattenuated, note it.
- **Turning Sound off or quitting with an idle (paused) tap** must be quick, with no 2 s stall.
- **Discord on the headset** by its own setting, with the system output on the speakers: set Discord to 50 % and
  let it go quiet, then ping. It should stay on the headset with no tap rebuild; the log shows no new "tapped"
  lines.
- **Mic mute in Sound settings**: the tab shows "Muted outside Orbit", the badge appears, and ⌃⌥M unmutes.
  Turning Sound off must not unmute it.
- **Mute with ⌃⌥M, then unplug the headset**: the mute moves to the MacBook mic. Plug the headset back in and it
  comes back unmuted.
- **Hog mode, if available** (an app taking exclusive access): unmute fails, the badge stays, and the record is
  kept.

## Fix round 2

Seven commits on `suite/sound` on top of f194ceb. Not pushed. No taps were created and no device, volume or mute
was changed (only tests and headless snapshots ran).

| Commit | Subject | Item |
|---|---|---|
| 77411fb | fix(sound): never queue an idle pause behind a tap's first start | N2 |
| bcc5363 | fix(sound): release a tap at once even while its start waits for audio | N3 |
| dbc2844 | fix(sound): idle followers of the system output follow its switch | N4 |
| d446a43 | fix(suite): don't mistake Orbit's own mute write for an outside unmute | N1 |
| 79208bf | fix(suite): drop the mic mute's system listeners once nothing is left to undo | N5 |
| c48d389 | fix(suite): keep Orbit's mic mute record clearable off the current input | N6 |
| 6b036d7 | fix(suite): watch the input device by object, without retrying each refresh | Nit |

To keep every commit compiling on its own, I wrote all the new Core tests first and saw them RED together. I then
parked the N1, N3 and N4 blocks and re-added each with its own fix, re-running RED each time.

### What changed

**N1: Orbit's own write is no longer mistaken for an outside unmute.**
- New `MicWriteConfirmation` (Core). After `wrote(at:)`, `mayConclude(from:state:now:)` ignores readings until one
  shows Orbit's mute (`MicMuteState.reflects(_:)`: mute control on, or volume at 0, on Orbit's device), or until
  `timeout` (2 s) has passed (the write evidently didn't take). Readings of another device are ignored while
  waiting.
- `MicMuteService.muteInput()` calls `wrote(at:)` after a successful non-empty write; this covers `followInput()`
  too.
- `refreshLiveState()` only feeds a reading to `state.deviceChanged` when `mayConclude` allows it. Meanwhile the UI
  already shows `.mutedByOrbit`, because `presentation` prefers Orbit's record for its device.

**N2: no idle pause is queued behind a tap's first start.**
- `TapActivity(now:isPlaying: false)` starts paused: its own TapAutoStart start already waits. It pauses only after
  it has played and gone quiet again. This updates the test at the old lines 719–722.
- `SoundEngine` pauses only taps with `hasStarted` (set when create()'s start has returned).
- `pauseUntilNextAudio()` re-checks on the tap's queue that none of its processes reports `IsRunningOutput` before
  stopping; if one does, it leaves the IO running.

**N3: release is immediate in every state.**
- New `TapLifecycle` (Core):
  - `beginWaitingStart()` returns false once the tap is released.
  - `endWaitingStart()` returns false when the tap was released meanwhile.
  - `invalidate()` returns `.onQueue`, `.fromOutside` or `.alreadyDone`.
  - `claimTeardown()` is true exactly once.
- `AppAudioTap` keeps that state and the HAL object IDs behind one lock.
- `invalidate()` while the queue sits in a waiting start (create()'s initial start or a re-arm) tears down at once
  on a global queue, outside the tap's own queue: AudioDeviceStop, destroy IOProc, destroy aggregate, destroy tap.
  When the start later returns, `endWaitingStart()` is false and the queue stops. It reports neither `onStarted`
  nor a failure.
- A release during creation stops it at the next step (`ensureAlive()`) without a failure report.
- `waitUntilReleased(deadline:)` waits for the teardown itself (a semaphore signalled once).
  `SoundEngine.stop()` waits for every tap's release, and the old "skip waiting taps" rule is gone.
- Safety against the queue returning later: the queue checks the lifecycle flag under the lock right after every
  waiting start. The teardown's HAL objects are taken and cleared under the same lock, so each object is destroyed
  once, by one party.

**N4:**
- `AppOutputMemory.systemOutputChanged(from:)` drops remembered entries made only of the old system output, so idle
  followers follow the switch. Apps on their own device keep their memory.
- `SoundEngine.noteSystemOutput()` runs at each pass and in `followedOutput(for:)`.

**N5:**
- `restoreOrbitMute()` calls `updateSystemListening()` after a successful undo.
- `processPending()` does the same on its early return, so the listeners go away once nothing is left to undo with
  both features off.

**N6:**
- `badgeClicked()` undoes Orbit's own mute whenever one is on record.
- `setMuted(false)` gets through while one is on record, even when that mute sits on a mic that is no longer the
  input (it then doesn't show in `isMuted`).
- `setActive(true)` retries the undo of a leftover Orbit mute on a mic that isn't the current input. I chose retry
  over follow because nobody asked to mute at that moment; the record only exists because an earlier undo failed.

**Nit:** `watchInput` re-attaches only when the device object changes. `watchedInput` is set even when no listener
could be installed, so it isn't retried on every refresh (mirrors M9).

### Covering tests (TDD)

| Test | RED | GREEN |
|---|---|---|
| `MicMuteStateTests/ownWriteIsNotMistakenForOutsideUnmute` (N1) | `cannot find 'MicWriteConfirmation' in scope` ×6, `no member 'reflects'` ×4 | 11 tests in 2 suites |
| `TapPlanTests/tapPausesAfterIdleDelay`, updated (N2) | 3 failures, e.g. `quiet.update(isPlaying: false, now: at(idleDelay)) → .pause) == nil` | 9 tests in 2 suites |
| `TapPlanTests/tapReleaseNeverWaitsForABlockedStart` (N3) | `cannot find 'TapLifecycle' in scope` ×8 | 10 tests in 2 suites |
| `TapPlanTests/systemOutputChangeDropsFollowers` (N4) | `no member 'systemOutputChanged'` ×4 | 11 tests in 2 suites |

N5, N6 and the nit are app-only (listener and badge flow in `MicMuteService`). They are covered by the existing
`MicMuteState` primitives and listed for hardware checks below.

### Commands and output (final)
- `swift test --filter Sound` → `✔ Test run with 49 tests in 6 suites passed`.
- `swift test --filter MicMuteState` → `✔ Test run with 11 tests in 2 suites passed`.
- Full `swift test` (once) → `✔ Test run with 607 tests in 29 suites passed after 80.114 seconds` (604 + 3 new).
- `swift build` after every commit: no errors and no warnings.
- `swift build -c release --arch arm64 --arch x86_64` → `Build complete!`.
- Snapshots: `fix2-panel.png` and `fix2-panel-dark.png` in the scratchpad `snap/` folder, unchanged from round 1
  (this round changed no UI).

### Hardware checks added
- **Arctis mute race (N1):** press ⌃⌥M on the SteelSeries Arctis Nova 5 several times in a row.
  - Each press must leave the Sound tab saying "Muted · ⌃⌥M to unmute", never "Muted outside Orbit".
  - Orbit's log must not show "was unmuted outside Orbit" after its own presses.
  - Turning Sound off must then unmute the mic.
- **Silent app (N2):** set a silent app (Slack, not playing) to muted. Its first notification must stay silent:
  no dropout and no full-level leak. The log shows no "is quiet" pause line until it has played and then gone
  quiet for 5 s.
- **Paused tap released at once (N3):** with an app's tap paused (quiet over 5 s), turn Sound off, reset the app to
  100 %, or reroute it. The log shows "released <app>" at once, not only at the app's next sound. Quitting takes no
  2 s pause.
- **System-output switch (N4):** with Chrome idle at 50 % and Same as Output, switch the system output. Chrome's
  next sound plays on the new output.
- **Badge and listeners (N5, N6):** mute, then switch the input to another mic. Clicking the badge or pressing
  unmute clears Orbit's mute on the old mic. With Sound and Controls off, after a retried undo succeeds, no default-
  input or device-list listener remains (by design; there's no direct observation).

## Fix round 3

Five commits on `suite/sound` on top of 6b036d7. Not pushed. No taps were created and no device, volume or mute
was changed (only tests ran).

| Commit | Subject | Item |
|---|---|---|
| 6d85515 | style(sound): fix blank-line spacing between tests | R5 |
| 84633fb | fix(sound): releasing an app releases the taps it replaced | R1 |
| 15c4920 | fix(suite): confirm Orbit's unmute writes too, not only its mutes | R3 |
| 6ab02ca | fix(suite): look at the mic again when a write's confirmation window ends | R2 |
| 76d5a46 | chore(sound): log waiting starts and outside teardowns for hardware checks | R4 |

### What changed

**R1: replaced taps can no longer be stranded.**
- New pure `TapRoster<ID>` (Core) keeps each app's current tap and the replaced ("retiring") ones still alive,
  oldest first.
  - `install` makes a new tap current; the previous current one retires.
  - `started(tap)` releases every tap of the app built before it. If a newer tap is already current, only the older
    ones go.
  - `failed(tap)` releases it and every older tap.
  - `release(app)` releases the current tap and all predecessors.
  - `releaseAll()` empties everything.
  - Late reports from taps already released return nothing.
- `SoundEngine` now uses the roster plus a map of live taps keyed by never-reused serial numbers.
  - The old `taps` and `retiring` dictionaries and the per-build `retire` closure are gone.
  - I used serials rather than `ObjectIdentifier`, so a late callback from a released, deallocated tap can't match
    a newer tap that reused its address.
  - `onStarted` releases what `roster.started` returns. `onFailure` releases what `roster.failed` returns, and marks
    the app failed only if that tap was current.
  - `release(_:)` releases everything `roster.release` returns, so a successor released before it got going (which
    reports nothing) takes its predecessors with it.
  - `stop()` releases all.
- Scenario 1 (paused A replaced by a waiting B, then reset to 100 %) and scenario 2 (release during B's creation)
  both release A with B. Scenario 3 (A → B → C, where C starts first) releases A and B on C's start.

**R3: Orbit's unmute writes are confirmed too.**
- `MicWriteConfirmation` now records the actions Orbit wrote: `wrote(_ actions:at:)`.
- `review(_:now:)` returns the reading to show and whether it can be trusted. While a write to that device hasn't
  shown up yet (and 2 s haven't passed), it projects the reading to what the write will leave (mute flag or volume)
  and marks it untrusted. A confirming or expired reading ends the wait. Readings of other devices pass through.
- The service records Orbit's mute, its unmute (restore) and a direct unmute of an outside mute.
  `refreshLiveState()` presents the reviewed reading, and only feeds trusted readings to `deviceChanged`.
- So, right after Orbit's unmute, the tab doesn't flash "Muted outside Orbit", and a quick second ⌃⌥M mutes.

**R2: the timeout is checked on its own.** `noteWrite` schedules one `DispatchQueue.main.asyncAfter(timeout + 0.1 s)`
that refreshes the live state. Each write replaces the previous check, and quitting cancels it.

**R4: logs for the hardware checks.**
- First start: "first start returned after X s", or "…returned after its release (blocked X s, status N)".
- Re-armed start: "is playing again (its start waited X s)", or "…returned after its release (blocked X s,
  status N)".
- Outside teardown: "releasing … from outside its waiting start", then "outside teardown of … finished in X s".

**R5:** blank-line spacing fixed around `systemOutputChangeDropsFollowers` and before
`tapReleaseNeverWaitsForABlockedStart` (I scanned the whole file for others; none left).

### Covering tests (TDD)

| Test | RED | GREEN |
|---|---|---|
| `TapPlanTests/releasingAnAppReleasesItsReplacedTaps` (scenario 1), `releasingDuringCreationReleasesThePredecessor` (scenario 2), `aStartReleasesEveryOlderTap` (scenario 3 and its "B starts after C was built" variant), `aFailureReleasesItAndOlderTaps` | `cannot find 'TapRoster' in scope` ×10 | 15 tests in 2 suites |
| `MicMuteStateTests/ownWriteIsNotMistakenForOutsideUnmute` (moved to `review`/`wrote(_:at:)`, plus other-device and empty-write cases), new `ownUnmuteDoesNotFlashOutsideMute` | `no member 'review'` ×28, `extra argument in call` ×18 | 12 tests in 2 suites |

R2 (timer) and R4 (logs) are app-only.

### Commands and output (final)
- `swift test --filter Sound` → `✔ Test run with 54 tests in 6 suites passed`.
- `swift test --filter MicMuteState` → `✔ Test run with 12 tests in 2 suites passed`.
- Full `swift test` (once) → `✔ Test run with 612 tests in 29 suites passed after 81.985 seconds` (607 + 5 new).
- `swift build` after every commit: no errors and no warnings.
- `swift build -c release --arch arm64 --arch x86_64` → `Build complete!`.
- No UI changed this round, so I took no new snapshots.

### Hardware checklist additions (R4)
- **(a) Release is immediate with a paused tap.** With an app's tap paused (quiet over 5 s), turn Sound off, reset
  the app to 100 %, or reroute it.
  - The log shows "releasing … from outside its waiting start" and "outside teardown … finished in X s" at once.
  - Quitting has no 2 s pause.
- **(b) The blocked start returns after its aggregate is destroyed.** Right after (a), the log should show "…'s
  re-armed start returned after its release (blocked X s)". If that line only appears at the app's next sound, the
  HAL kept the start blocked past the aggregate's destruction; the release itself still happened.
- **(c) A never-playing app doesn't keep coreaudiod busy.** Give a tapped app a remembered setting and never let it
  play. Watch `coreaudiod` CPU in Activity Monitor and `pmset -g assertions`: no steady CPU and no sleep assertion
  from it.
- **Stranding check for R1.** Chrome quiet at 50 % on the headset, then route it to the speakers, then reset it to
  100 % before it plays. At Chrome's next sound it must play at 100 % on its usual output, and the log shows every
  "released com.google.Chrome" line.

## Fix round 4 (fresh implementer; branch suite/sound-r4 on 76d5a46)

Commits (oldest first): afdf7e4 F1 · 052ee8f F4 · a82d70f F3 · da188ea F2. No taps created, no device/volume/mute changed.

- **F1 — a quick second ⌃⌥M after Orbit's unmute is no longer lost.** `MicMuteState.mute(_:confirming:now:)` builds the mute from the reviewed (projected) reading, not the raw one; `observe(_:confirming:now:)` holds refreshLiveState's review and the "unmuted outside Orbit" decision so the whole trace is testable in Core. An empty write no longer clears a pending confirmation or cancels its deferred check.
- **F4 — every Orbit mic write is confirmed, per device and control.** `MicWriteConfirmation` keeps one wait per device/control (a later write to the same control replaces it; expired waits are dropped). `noteWrite` is now also called from processPending, followInput's restore of the old mic, and muteInput's rollback. Deviation: recorded for every device (not only the current input) — per-device waits remove the cross-device displacement risk and fix an input flip-back variant of F1.
- **F3 — a failed retiring tap releases only itself** (a failed current tap still takes all older taps).
- **F2 — replaced taps that never started are released at install**; at most one replaced tap (the newest that started) is kept per app. Before installing, `noteStarts(of:)` reports taps whose start already returned but whose onStarted is still queued, so a tap that just began playing isn't taken for a never-started one. Three round-3 roster tests updated to give the kept predecessor its start.

Tests (RED then GREEN): `quickMuteAfterOwnUnmuteIsNotLost`, `writesToSeveralDevicesWaitApart`, `aFailedRetiringTapReleasesOnlyItself`, `rebuildsOfAQuietAppDoNotPileUp` (incl. a 500-step random mix). `swift test --filter Sound` 58 passed; `--filter MicMuteState` 14 passed; full suite 616 passed; `swift build -c release --arch arm64 --arch x86_64` complete, no warnings.

Hardware checklist additions: quick double press on the Arctis (ends muted, no "was unmuted outside Orbit"; also on a volume-fallback mic); reconnect the headset while muted (no "Muted outside Orbit" flash); input flip-back while muted (headset ends muted, later unmute works); output flapping AirPods ↔ speakers with quiet Slack at 50 % (one "released" per rebuild, coreaudiod thread count steady, Slack plays once at 50 % on the current output).

Known (pre-existing, rare): if Orbit's mute record sits on a mic that is no longer the input and the undo failed twice, setMuted(true) on the current mic writes nothing until the record clears.
