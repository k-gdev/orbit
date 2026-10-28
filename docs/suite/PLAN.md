# Orbit Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Orbit from a single drag-wheel utility into a suite: a tabbed menu bar panel, a side-rail Settings window with a Features page, and seven feature modules (Sound, System, Displays, Windows, Clipboard, Shelf, Wallpaper), with the wheel unchanged apart from a new Shelf action.

**Architecture:** A shell (feature protocol, registry, permissions, hot keys, shared pill/tile UI, menu bar panel, settings rail, snapshot renderer) lands first. Each feature is then a self-contained module behind `SuiteFeature`: pure logic in `Sources/OrbitCore/<Feature>/` with Swift Testing tests, OS glue in `Sources/OrbitApp/Features/<Feature>/`. Features touch only their own folders (Shelf also touches the wheel's Actions ring), so they are built in parallel worktrees and merged.

**Tech Stack:** Swift 6.3 toolchain, swift-tools 6.0, Swift 5 language mode, SwiftPM, SwiftUI + AppKit, Core Audio (process taps, HAL), IOKit (IOAVService DDC, IOHIDEventSystem, IOPowerSources), DisplayServices (private, `dlsym`), Accessibility (AX), ScreenCaptureKit, AVFoundation, Carbon hot keys, Swift Testing.

**Spec:** `docs/suite/SPEC.md` (mockup: `docs/suite/menu-bar-mockup.html`). Read both before any task.

## Global Constraints

- Minimum macOS stays **14.0**; newer APIs behind `#available`, shown as unavailable with the reason on older systems. Process taps need **macOS 14.2**.
- Swift 5 language mode, swift-tools 6.0, targets `OrbitCore` / `OrbitApp` / `OrbitCoreTests`; follow the existing idioms (see `SettingsStore`, `OrbitTheme`, `GlassBackground`, the `Debug/*Snapshot.swift` files).
- `swift build` and `swift test` stay green (547 existing tests); every new pure-logic unit gets Swift Testing tests in `Tests/OrbitCoreTests/`.
- `scripts/build-app.sh` builds a **universal** app (arm64 + x86_64): every new file must compile for x86_64 too.
- No change to the wheel's behaviour, catalog or processors except the Shelf action (§5.6 of the spec).
- Copy nothing from Vorssaint Utils (GPL-3.0): no code, assets, strings or look.
- Orbit's look: Liquid Glass on macOS 26 via `GlassBackground`, `.ultraThinMaterial` fallback, Control Center–style pill sliders, accent from `OrbitTheme.accent` (default `#80649C`), SF Symbols.
- No feature may cost CPU while turned off. No permission prompt for a feature the user has not turned on.
- Private APIs only through `PrivateSymbol` (`dlopen`/`dlsym`); a missing symbol degrades gracefully, never crashes.
- No kernel extensions, no root helpers, no writes to `/Library` or `/System`.
- **Hardware safety (build-time):** never change real brightness, resolution, default audio devices, mic mute or desktop pictures, and never leave a desktop window up. Read-only probes are fine. Tests use throwaway `UserDefaults(suiteName:)` suites and temp directories, never the real defaults or `~/Library/Application Support/Orbit`.
- Never overwrite or delete a file this task did not create. Never commit `.orbit-signing`, `Support/Brand/Concepts/` or `brag-output/`.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Persisted data lives under `~/Library/Application Support/Orbit/<Feature>/` (app runtime only) and `UserDefaults.standard` keys prefixed with the feature id (`sound.`, `displays.`, ...).

## Review Focus

1. **Quit, disable or crash while an app is tapped (Sound).** The app must never stay muted: taps and aggregate devices are private to Orbit's process (`kAudioAggregateDeviceIsPrivateKey`), destroyed on `stop()` and `applicationWillTerminate`, and an app at 100 %, unmuted, on the default output gets no tap at all. Test: `TapPlanTests.noTapAtUnityOnDefaultOutput` (Task 7).
2. **A display that doesn't answer DDC, is unplugged, or sleeps (Displays).** Its tile falls back to software dimming or hides; a bad or short DDC reply is rejected, never trusted. Test: `DDCTests.rejectsBadChecksum` / `rejectsShortReply` (Task 9).
3. **Password-manager copies and huge copies (Clipboard).** Concealed/transient items are never stored; a 200 MB image does not land in history unbounded. Test: `PasteboardFilterTests.skipsConcealedAndTransient`, `ClipboardHistoryTests.enforcesByteLimit` (Task 11).
4. **Turning a feature off stops all its work.** Timers, monitors, hot keys, status items, taps and windows are released; `start()`/`stop()` are idempotent. Test: `SuiteSettingsTests.enabledSetRoundTrips` (Task 1) plus each feature's start/stop review item.
5. **Wallpaper under a full-screen app, on a locked screen, on battery, or on a removed display.** Playback pauses, the window for a removed display closes. Test: `WallpaperPausePolicyTests` (Task 13).

---

## Phase 1 — Shell (one Opus agent, in the suite worktree, Tasks 1–6 in order)

### Task 1: Suite model in OrbitCore

**Files:**
- Create: `Sources/OrbitCore/Suite/FeatureID.swift`, `Sources/OrbitCore/Suite/SuitePermission.swift`, `Sources/OrbitCore/Suite/SuiteSettings.swift`, `Sources/OrbitCore/Suite/KeyCombo.swift`, `Sources/OrbitCore/Suite/PillScale.swift`, `Sources/OrbitCore/Suite/SettingsPage.swift`
- Test: `Tests/OrbitCoreTests/SuiteTests.swift`

**Interfaces — Produces:**
- `public enum FeatureID: String, CaseIterable, Codable, Sendable { case sound, system, displays, windows, clipboard, shelf, wallpaper }` with `title` ("Sound" … "Wallpaper"), `symbol` (SF Symbol: `speaker.wave.2`, `cpu`, `display`, `macwindow.on.rectangle`, `doc.on.clipboard`, `tray`, `photo.on.rectangle`), `summary` (one line), `permissions: [PermissionUse]`, `isOnByDefault: Bool`. Order of `allCases` is the tab order.
- `public enum SuitePermission: String, CaseIterable, Sendable { case systemAudioRecording, accessibility, screenRecording }` with `title` and `settingsURL: URL` (`x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture` / `Privacy_Accessibility` / `Privacy_ScreenCapture`).
- `public struct PermissionUse: Sendable, Equatable { permission: SuitePermission; purpose: String; requestOnEnable: Bool }`. Table: sound → audio recording ("Per-app volume, boost and output", request); windows → accessibility ("Window titles, bring forward, minimise; Dock preview", request) and screenRecording ("Dock preview thumbnails", request); clipboard → accessibility ("Paste into the frontmost app; without it Orbit only copies", **not** requested on enable).
- `public final class SuiteSettings: ObservableObject` (same idiom as `SettingsStore`, `init(defaults: UserDefaults = .standard)`): `@Published enabledFeatures: Set<FeatureID>` (key `suite.enabledFeatures`, default = features with `isOnByDefault`: system, displays, shelf, wallpaper), `@Published lastTab: FeatureID?` (key `suite.lastTab`), `func isEnabled(_:) -> Bool`, `var enabledInOrder: [FeatureID]`.
- `public struct KeyCombo: Codable, Hashable, Sendable { keyCode: UInt16; modifiers: ModifierSet }` with `display: String` (modifiers in Apple order ⌃⌥⇧⌘, then key name), `static func keyName(for: UInt16) -> String?` (ANSI letters, digits, F1–F12, space, return, arrows), `static let micMuteDefault` (⌃⌥M, keyCode 46), `static let clipboardDefault` (⇧⌘V, keyCode 9). Reuses the existing `ModifierSet`.
- `public struct PillScale: Sendable, Equatable { maximum: Double; boostStart: Double = 100 }` with `hasBoost`, `boostStartFraction`, `fraction(for:) -> Double` (clamped 0…1), `value(forFraction:step:) -> Double` (clamped to 0…maximum, rounded to step).
- `public enum SettingsPage: Hashable, Sendable { case general, wheel, features, feature(FeatureID), about }` with `title`, `symbol`, `static var railOrder: [SettingsPage]` (general, wheel, features, the seven features, about), and `init?(argument: String)` for the snapshot CLI ("general", "wheel", "features", "about", or a feature raw value).

- [ ] **Step 1: Write the failing tests** in `SuiteTests.swift`:
  - `featureOrderMatchesTabs`: `FeatureID.allCases.map(\.title) == ["Sound","System","Displays","Windows","Clipboard","Shelf","Wallpaper"]`
  - `permissionsTable`: `FeatureID.system.permissions.isEmpty`; `FeatureID.windows.permissions.map(\.permission) == [.accessibility, .screenRecording]`; `FeatureID.clipboard.permissions.first?.requestOnEnable == false`
  - `enabledSetRoundTrips`: new suite defaults → `enabledFeatures == [.system, .displays, .shelf, .wallpaper]`; insert `.sound`, re-init from same defaults → contains `.sound`; `enabledInOrder.first == .sound`
  - `lastTabPersists`
  - `keyComboDisplay`: `KeyCombo.micMuteDefault.display == "⌃⌥M"`, `KeyCombo.clipboardDefault.display == "⇧⌘V"`; KeyCombo JSON round-trip
  - `pillScale`: `PillScale(maximum: 150).boostStartFraction` ≈ 0.6667; `fraction(for: 75) == 0.5`; `value(forFraction: 1.2) == 150`; `value(forFraction: -0.1) == 0`; `PillScale(maximum: 100).hasBoost == false`, its `boostStartFraction == 1`
  - `settingsPageArguments`: `SettingsPage(argument: "sound") == .feature(.sound)`, `SettingsPage(argument: "features") == .features`, `SettingsPage(argument: "nope") == nil`, `railOrder.count == 11`
- [ ] **Step 2:** `swift test --filter SuiteTests` → FAIL (types missing).
- [ ] **Step 3:** Implement the six files.
- [ ] **Step 4:** `swift test --filter SuiteTests` → PASS; `swift test` → all green.
- [ ] **Step 5:** Commit `feat(suite): feature, permission and settings model`.

### Task 2: Feature protocol, registry, permissions, hot keys, private symbols

**Files:**
- Create: `Sources/OrbitApp/Suite/SuiteFeature.swift`, `Sources/OrbitApp/Suite/SuiteContext.swift`, `Sources/OrbitApp/Suite/FeatureRegistry.swift`, `Sources/OrbitApp/Suite/PermissionCenter.swift`, `Sources/OrbitApp/Suite/PrivateSymbol.swift`, `Sources/OrbitApp/Suite/HotKeyCenter.swift`, `Sources/OrbitApp/Suite/UI/KeyComboRecorder.swift`
- Create stubs: `Sources/OrbitApp/Features/<Name>/<Name>Feature.swift` for Sound, System, Displays, Windows, Clipboard, Shelf, Wallpaper (class names `SoundFeature`, `SystemFeature`, `DisplaysFeature`, `WindowsFeature`, `ClipboardFeature`, `ShelfFeature`, `WallpaperFeature`), each a working placeholder tile ("Coming in this build") so the app runs.
- Modify: `Sources/OrbitApp/AppDelegate.swift` (build context + registry, `startEnabled()` at launch, `applicationWillTerminate` → `registry.stopAll()`), `Support/Info.plist` (add `NSAudioCaptureUsageDescription` "Orbit adjusts each app's volume and output when you use the Sound mixer."; Screen Recording and Accessibility have no Info.plist keys on macOS).

**Interfaces — Produces:**
```swift
@MainActor protocol SuiteFeature: AnyObject {
    var id: FeatureID { get }
    func start()                 // turned on (launch or Features page); idempotent
    func stop()                  // stop ALL work; idempotent
    func panelDidAppear()        // panel opened on this feature's tab (default: no-op)
    func panelDidDisappear()     // panel closed or tab switched away (default: no-op)
    func makePanelView() -> AnyView
    func makeSettingsView() -> AnyView
    static func snapshotViews() -> FeatureSnapshotViews   // fixture data, no hardware, no permissions
}
struct FeatureSnapshotViews { var panel: AnyView; var settings: AnyView }

@MainActor final class SuiteContext {
    let settings: SettingsStore; let suite: SuiteSettings; let defaults: UserDefaults
    let hotKeys: HotKeyCenter; let permissions: PermissionCenter
    let supportDirectory: URL          // ~/Library/Application Support/Orbit (created lazily by features)
    var openSettings: (SettingsPage) -> Void = { _ in }
    var closePanel: () -> Void = {}
}

@MainActor final class FeatureRegistry: ObservableObject {
    init(context: SuiteContext, features: [any SuiteFeature])
    static func standard(context: SuiteContext) -> FeatureRegistry   // the seven feature classes, each `init(context:)`
    @Published private(set) var running: Set<FeatureID>
    func feature(_ id: FeatureID) -> any SuiteFeature
    func startEnabled()
    func setEnabled(_ id: FeatureID, _ on: Bool)   // on: request `requestOnEnable` permissions not yet granted, then start; off: stop
    func stopAll()
}

enum PermissionStatus { case granted, notGranted, unknown }
@MainActor final class PermissionCenter: ObservableObject {
    @Published private(set) var statuses: [SuitePermission: PermissionStatus]
    func refresh()                               // AXIsProcessTrusted, CGPreflightScreenCaptureAccess, TCC preflight for audio via PrivateSymbol (unknown if unavailable)
    func request(_ p: SuitePermission)           // AXIsProcessTrustedWithOptions(prompt), CGRequestScreenCaptureAccess, TCCAccessRequest via PrivateSymbol
    func openSettings(_ p: SuitePermission)
}

enum PrivateSymbol { static func load<T>(_ name: String, from path: String, as: T.Type) -> T? }  // dlopen(RTLD_LAZY)+dlsym, cached handles, Log on miss

@MainActor final class HotKeyCenter {           // Carbon RegisterEventHotKey: no permission needed
    @discardableResult func register(_ combo: KeyCombo, id: String, action: @escaping () -> Void) -> Bool  // false if taken
    func unregister(id: String)
}
struct KeyComboRecorder: View { init(combo: Binding<KeyCombo>, conflict: String?) }   // click, press keys, Esc cancels
```
- [ ] **Step 1:** Implement the files; refresh permission statuses when the app becomes active and when Settings becomes key.
- [ ] **Step 2:** `swift build` → succeeds; launch-time behaviour unchanged except features start.
- [ ] **Step 3:** Commit `feat(suite): feature registry, permissions, hot keys`.

### Task 3: Shared panel UI

**Files:** Create `Sources/OrbitApp/Suite/UI/PanelTile.swift`, `PillSlider.swift`, `PanelMenuButton.swift`, `LevelBars.swift`, `Stripes.swift`, `PanelRoundButton.swift`.

**Interfaces — Produces:**
- `PanelTile<Content: View>(@ViewBuilder content:)` — rounded 12 pt, translucent white (light) / white 8 % (dark), 10 pt padding.
- `PanelSectionHeader(_ title: String, trailing: AnyView? = nil)` — small caps, secondary.
- `PillSlider(value: Binding<Double>, scale: PillScale, step: Double = 1, leading: AnyView, valueText: (Double) -> String, onLeadingTap: (() -> Void)? = nil, onEditingEnded: (() -> Void)? = nil)` — 30 pt capsule; filled part white (light) / white 85 % (dark); past `scale.boostStart` the track shows `Stripes` in the accent colour; drag anywhere sets value, scroll wheel nudges; leading content (icon, or app icon + name) sits inside the pill; value text right-aligned inside.
- `PanelMenuButton<MenuContent: View>(title: String, systemImage: String?, @ViewBuilder content:)` — compact capsule label with up/down chevron, live `Menu` underneath.
- `LevelBars(active: Bool)` — three small bars animating while active, flat when not.
- `Stripes` — diagonal hatch `Shape`.
- `PanelRoundButton(systemImage: String, isOn: Bool = false, action:)` — 28 pt circle; accent fill when `isOn`.
- [ ] **Step 1:** Implement; values come only from `PillScale` (no duplicate math).
- [ ] **Step 2:** `swift build` → succeeds.
- [ ] **Step 3:** Commit `feat(suite): shared panel tiles and pill sliders`.

### Task 4: Menu bar panel

**Files:**
- Create: `Sources/OrbitApp/MenuBar/MenuBarPanel.swift` (borderless `NSPanel`, `.nonactivatingPanel`, can become key so search fields work, transparent background, `.popUpMenu`-ish level), `Sources/OrbitApp/MenuBar/MenuBarPanelController.swift`, `Sources/OrbitApp/MenuBar/PanelView.swift`
- Modify: `Sources/OrbitApp/MenuBar/StatusItemController.swift`

**Behaviour:**
- Left-click the Orbit status item toggles the panel, anchored centred under the icon, clamped to the screen's visible frame; right-click (or ⌃-click) shows the **existing NSMenu unchanged** (About, Open Files…, Settings…, Enabled, Recent results, ⌥ Debug, Quit). **[builder's call]**
- Panel: 390 pt wide, `GlassBackground` rounded 18 pt; tab row across the top (icon + small label, selected tab on a white pill), only enabled features, remembers `suite.lastTab`; content scrolls if taller than the screen allows; footer: **Settings…**, **Quit Orbit**, and a `…` menu holding Open Files…, Wheel enabled (toggle of `settings.isEnabled`), Recent results, About Orbit. **[builder's call]**
- No enabled features: content shows a tile "Turn on features in Settings → Features" with a button that opens that page.
- Closes on outside click (global mouse-down monitor, installed only while open), Escape, or opening Settings. Calls `panelDidAppear()` / `panelDidDisappear()` on the visible feature (tab switch counts).
- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `swift build`; run `.build/debug/Orbit` briefly and confirm left/right click behaviour is wired (no screenshots of the real menu bar needed).
- [ ] **Step 3:** Commit `feat(suite): tabbed menu bar panel`.

### Task 5: Settings window with side rail

**Files:**
- Modify: `Sources/OrbitApp/Settings/SettingsWindowController.swift` (`show(page: SettingsPage? = nil)`), `Sources/OrbitApp/Settings/SettingsView.swift` (split existing content into reusable sections; keep `SettingsContent` working for `--snapshot-settings`)
- Create: `Sources/OrbitApp/Settings/SettingsRootView.swift` (side rail `NavigationSplitView`, 760×560 default), `Sources/OrbitApp/Settings/FeaturesPage.swift`, `Sources/OrbitApp/Settings/FeatureSettingsPage.swift`, `Sources/OrbitApp/Settings/AboutPage.swift`

**Pages:** General (launch at login, haptics, accent, Full Disk Access + Show welcome again), Wheel (Enabled toggle, Triggers, Output, Copy & Move, Terminal, Helpers), **Features** (per feature: icon, title, summary, toggle bound to `registry.setEnabled`, each `PermissionUse` with its status badge and an **Open System Settings** button), one page per feature (header with the same toggle + permission rows, then `feature.makeSettingsView()`; when off, the settings stay editable but a note says the feature is off), About (version from bundle, MIT licence, log path, GitHub link). Nothing from the old single page may be lost.
- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `swift build`; `.build/debug/Orbit --snapshot-settings <scratch>.png` still works.
- [ ] **Step 3:** Commit `feat(suite): settings window with side rail and Features page`.

### Task 6: Snapshot renderer and suite snapshot CLI

**Files:** Create `Sources/OrbitApp/Debug/SnapshotRenderer.swift`, `Sources/OrbitApp/Debug/SuiteSnapshot.swift`; modify `Sources/OrbitApp/main.swift` (one line).

**Interfaces — Produces:**
- `SnapshotRenderer.png(of view: some View, size: CGSize?, dark: Bool) throws -> Data` — hosts the view in an `NSHostingView` inside an offscreen, never-ordered-front window and uses `cacheDisplay(in:to:)`, so AppKit controls (toggles, pop-ups, sliders, text fields) draw for real (unlike `ImageRenderer`, which draws yellow placeholders). Glass renders `.flat` via `\.glassRendering`.
- CLI (same conventions as the existing snapshot modes: refuse to overwrite without `--replace`, exit 64 on bad args):
  - `Orbit --snapshot-panel <feature|empty> <out.png> [--dark] [--replace]` — full panel (all seven tabs shown, the given one selected) on a soft gradient backdrop, using `FeatureType.snapshotViews().panel`.
  - `Orbit --snapshot-settings-page <page> <out.png> [--dark] [--replace]` — full Settings window (rail + page) at 760×560; feature pages use `snapshotViews().settings`.
  - `Orbit --snapshot-suite <dir> [--replace]` — writes `panel-<id>-{light,dark}.png` and `settings-<page>-{light,dark}.png` for everything.
- [ ] **Step 1:** Implement; snapshots use throwaway defaults suites and fixture models only.
- [ ] **Step 2:** `swift build && .build/debug/Orbit --snapshot-suite <scratchpad>/shots` → writes files; view a couple to confirm real controls render.
- [ ] **Step 3:** `swift test` → all green. Commit `feat(suite): headless panel and settings snapshots`.

---

## Phase 2 — Features (parallel, one agent per task, each in its own worktree reset to the post-shell SHA)

Every feature task follows the same shape:
- **Owns only** `Sources/OrbitCore/<Feature>/`, `Sources/OrbitApp/Features/<Feature>/`, `Tests/OrbitCoreTests/<Feature>*Tests.swift` (Shelf additionally the files listed in Task 12).
- Replaces its stub `<Name>Feature` with the real class (`init(context: SuiteContext)`), implements every `SuiteFeature` member, and keeps `stop()` releasing everything.
- A `<Feature>Settings: ObservableObject` in OrbitCore (`init(defaults: UserDefaults = .standard)`, keys prefixed with the feature id) holds its persisted settings, with round-trip tests.
- `snapshotViews()` builds the real panel and settings views over a fixture model (no hardware access), so `--snapshot-panel <id>` shows a realistic tab.
- TDD for every pure unit (write test, see it fail, implement, see it pass, commit). Commit after each unit; `swift build` + `swift test` green at every commit.
- Ends with a report at `docs/suite/reports/<feature>.md` in the **suite worktree** (`/Users/kevog/orbit/.claude/worktrees/suite-77e4bb`, written there directly, not committed by the agent): what was built, files, tests, every **[builder's call]**, what needs hardware verification, known gaps.

### Task 7: Sound (Opus)

**Core (`Sources/OrbitCore/Sound/`):**
- `SoundSettings`: `pinnedBundleIDs: [String]`, `appStates: [String: AppAudioPreference]` (bundle ID → `volume` 0…150, `muted`, `outputUID: String?` nil = Same as Output), `rememberAppStates: Bool` (default true), `preferredMicUID: String?`, `keepPreferredMic: Bool` (default false), `muteShortcut: KeyCombo` (default `.micMuteDefault`), `showAllApps: Bool`.
- `VolumeCurve`: `gain(forPercent:) -> Float` (0 → 0, 100 → 1, 150 → 1.5, perceptual curve below 100 is fine but monotonic) and `SoftClip.apply(_:)` for boost (tanh-style knee above ~0.9, never exceeds 1.0).
- `TapPlan`: given an app's preference and the current default output UID, decides `needsTap` (volume ≠ 100, or muted, or `outputUID` set and ≠ default) and the destination UID.
- `AudioAppGrouping`: maps helper process bundle IDs to their app (`com.google.Chrome.helper.*` → `com.google.Chrome`, `com.apple.WebKit.*` → responsible app via PID when given), so one pill per app.
- `PreferredMicPolicy.shouldSwitchBack(currentUID:preferredUID:availableUIDs:keep:) -> Bool`.
- Tests `Tests/OrbitCoreTests/SoundTests.swift`: `noTapAtUnityOnDefaultOutput`, `tapWhenBoosted`, `tapWhenRoutedElsewhere`, `noTapWhenRoutedToCurrentDefault`, `gainEndpoints` (0, 100, 150), `gainMonotonic`, `softClipBounded`, `helperGroupsUnderApp`, `preferredMicSwitchBackOnlyWhenAvailable`, `settingsRoundTrip`.

**App (`Sources/OrbitApp/Features/Sound/`):**
- `AudioHardware` (HAL wrapper): devices (UID, name, input/output channel counts, transport type, icon hint), default output / system output / input get+set, output volume (virtual main volume, `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`), input volume + mute, property listeners (devices, defaults, volume) registered in `start()`, removed in `stop()`.
- `AudioProcessMonitor` (macOS 14.2+): `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyPID` / `BundleID` / `IsRunningOutput`, grouped through `AudioAppGrouping`, resolved to `NSRunningApplication` for name and icon; listeners only while the panel is open or a tap exists.
- `AppAudioTap` (macOS 14.2+): `CATapDescription(stereoMixdownOfProcesses:)`, `muteBehavior = .mutedWhenTapped`, `AudioHardwareCreateProcessTap`, a **private** aggregate device (tap + destination output as sub-device, `kAudioAggregateDeviceIsPrivateKey: true`, `kAudioAggregateDeviceTapAutoStartKey`), an IOProc that copies tap input to output applying `VolumeCurve` gain (+ `SoftClip` past 100) with a smoothed ramp; `invalidate()` stops the IOProc, destroys the aggregate, then the tap. Retarget when the default output changes.
- `SoundEngine`: owns taps keyed by bundle ID, applies `TapPlan` on every preference/default change, tears everything down in `stop()`; `applicationWillTerminate` reaches it through `registry.stopAll()`.
- `MicMuteController`: mute via the input device's mute property, falling back to input volume 0 (remember and restore the previous volume on unmute, on `stop()` and on quit); global shortcut via `HotKeyCenter` (id `sound.micMute`); while muted, an extra `NSStatusItem` shows `mic.slash.fill`.
- `PreferredMicWatcher`: when `keepPreferredMic` is on and the default input changes away from the preferred device while it is still connected, switch back (this is user-configured behaviour, off by default).
- `SoundPanelView` per the mockup: "Output & Input" header; Output tile (device `PanelMenuButton` + master volume `PillSlider` 0–100), "Alerts & system sounds" row with its own device menu; Microphone tile (device menu, input level pill, mute `PanelRoundButton`, "Muted · ⌃⌥M to unmute" caption); "Apps" header with **Show all apps** toggle; one `PillSlider` per app (icon + name + `LevelBars` inside, 0–150 with boost stripes, tap icon = mute) and a `PanelRoundButton` that opens a menu "Play <App> on": Same as Output / each output device. Without System Audio Recording permission (or on macOS < 14.2) the Apps list shows why and a button to grant it; the device tiles still work.
- `SoundSettingsView`: preferred microphone + keep toggle, remember per-app settings, mute shortcut (`KeyComboRecorder`), pinned apps list (add from running apps, remove).
- Read-only probes allowed: list devices, list audio processes. **Do not** change default devices, volumes or mute, and do not create taps on Kevo's real apps during development; prove the tap path compiles and is gated.

### Task 8: System (Opus)

**Core (`Sources/OrbitCore/System/`):**
- `CPULoad`: from two `host_processor_info` tick snapshots (`[CPUTicks]` with user/system/idle/nice) compute total and per-core load; `ClusterLayout(performanceCores:efficiencyCores:)` groups per-core loads into P / E clusters (from `hw.perflevel0.logicalcpu` / `hw.perflevel1.logicalcpu`).
- `SampleHistory<T>`: fixed-capacity ring buffer (default 60) for sparklines.
- `MemoryStats`: from page counts (free, active, inactive, wired, compressed, page size) → used bytes (active + wired + compressed), total, `MemoryPressure` (.normal/.warning/.critical from the kernel level 1/2/4).
- `SensorGroups`: classify IOHID temperature sensor names into CPU (`PMU tdie*`, `pACC*`, `eACC*`), GPU (`GPU*`, `PMU tdev*`? — classify by the names actually present on the M5 Max, probe read-only), SoC/other; report average and max per group, ignoring readings ≤ 0 or ≥ 150 °C.
- `BatteryReading` + `BatteryParser`: parse an IOPowerSources description dictionary (capacity, max, charging, time remaining, source) and Bluetooth/HID battery entries from IORegistry property dictionaries (`BatteryPercent`, `Product`, `DeviceAddress`) into `[BatteryReading]`, de-duplicated by address.
- `UptimeFormatter.string(seconds:) -> String` ("3 d 4 h", "5 h 12 m", "12 m").
- `SystemSettings`: `menuBarReadout: MenuBarReadout` (.off default, .cpu, .temperature, .cpuAndTemperature) **[builder's call]**, `sampleInterval` (1 s panel), `showPerCluster: Bool` (true).
- Tests `SystemTests.swift`: `cpuLoadFromTicks`, `cpuLoadZeroDeltaIsZero`, `clustersSplitPAndE`, `historyCapsAndOrders`, `memoryUsedAndPressure`, `sensorClassification`, `sensorIgnoresImplausible`, `batteryParsesInternal`, `batteryParsesBluetoothAndDedupes`, `uptimeStrings`, `settingsRoundTrip`.

**App (`Sources/OrbitApp/Features/System/`):** `CPUSampler` (host_processor_info), `GPUSampler` (IOAccelerator `PerformanceStatistics` → "Device Utilization %"), `MemorySampler` (host_statistics64 + `kern.memorystatus_vm_pressure_level`), `ThermalSampler` (IOHIDEventSystemClient via `PrivateSymbol`: `IOHIDEventSystemClientCreate`, `IOHIDEventSystemClientSetMatching` with PrimaryUsagePage 0xff00 / Usage 5, `IOHIDServiceClientCopyEvent` type 15 → temperature; nil-safe when symbols are missing), `BatterySampler` (IOPowerSources + IORegistry `AppleDeviceManagementHIDEventService` / Bluetooth devices with `BatteryPercent`). A `SystemMonitor` runs samplers **only while the panel shows the System tab** (1 s) or while the menu bar readout is on (2 s), never otherwise. `SystemPanelView`: tiles for CPU (total %, P/E bars, sparkline), GPU (% + sparkline), Memory (used / total, pressure colour), Temperatures (CPU / GPU / SoC), Uptime, Batteries (Mac + each device with icon by kind). `SystemSettingsView`: menu bar readout picker, per-cluster toggle. Optional readout is its own `NSStatusItem`.

### Task 9: Displays (Opus)

**Core (`Sources/OrbitCore/Displays/`):**
- `DDC`: `getVCPRequest(code:) -> [UInt8]`, `setVCPRequest(code:value:) -> [UInt8]` (DDC/CI framing with 0x51 source address and XOR checksum incl. destination 0x6E), `parseVCPReply(_ bytes: [UInt8], code: UInt8) -> VCPValue?` (`current`, `maximum`), rejecting short replies, wrong opcode, wrong VCP code, bad checksum and result-code ≠ 0.
- `BrightnessLink.values(changing id:, to newFraction:, current: [ID: Double]) -> [ID: Double]` — proportional: other displays move by the same ratio of change, clamped 0…1.
- `DisplayModeList`: from raw mode tuples (width, height, pixelWidth, pixelHeight, refresh, isUsable, ioFlags) produce sorted, de-duplicated menu entries with labels ("2560 × 1440", "HiDPI" when pixel size is 2× the point size, refresh shown only when a size has several rates), current mode marked.
- `BrightnessRange`: effective max = per-display override ?? DDC-reported max ?? 100; `PillScale(maximum:)` past 100 = boost.
- `DisplaySettings`: `linkBrightness: Bool`, `maxOverrides: [String: Int]` (key = display identity: vendor-model-serial), `useGammaFallback: Bool` (true), `lastSoftwareDim: [String: Double]`.
- Tests `DisplaysTests.swift`: `getRequestFraming`, `setRequestFraming`, `parsesValidReply`, `rejectsBadChecksum`, `rejectsShortReply`, `rejectsWrongCode`, `linkProportional`, `linkClamps`, `modeListDedupesAndLabelsHiDPI`, `rangeUsesOverrideThenDDC`, `settingsRoundTrip`.

**App (`Sources/OrbitApp/Features/Displays/`):** `DisplayCatalog` (NSScreen + CGDirectDisplayID, names from `NSScreen.localizedName`, vendor/model/serial from CGDisplay*, refresh on `didChangeScreenParameters`), `BuiltInBrightness` (DisplayServices `DisplayServicesGetBrightness`/`SetBrightness` via `PrivateSymbol` from `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`), `DDCService` (Apple Silicon: walk IORegistry for `DCPAVServiceProxy` with `Location = External`, match to CGDirectDisplayID by EDID vendor/product/serial (`EDID UUID` or `DisplayAttributes`), `IOAVServiceCreateWithService` / `IOAVServiceReadI2C` / `IOAVServiceWriteI2C` via `PrivateSymbol` from IOKit; serial queue, write-then-delay-then-read with retries; Intel Macs: unavailable, gamma only), `GammaDimmer` (`CGSetDisplayTransferByTable`, restored on `stop()` and quit), `DisplayModeService` (`CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes`, apply via `CGBeginDisplayConfiguration` / `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration(.permanently)`). Brightness writes are debounced (~80 ms) while dragging. `DisplaysPanelView` per the mockup (header with **Link brightness** toggle; per display: name, kind caption "Built-in" / "DDC · up to 150" / "Software dimming", resolution `PanelMenuButton`, brightness `PillSlider` with boost past 100). `DisplaysSettingsView`: link toggle, gamma fallback toggle, per-display maximum brightness override (Stepper 100…255, "Auto" = reported). Read-only probes allowed: list displays and modes, DDC **reads** of VCP 0x10 current/max. **No DDC writes, no mode changes, no gamma changes** during development.
- The report must say what Orbit can and cannot replace from BetterDisplay (it lists only modes macOS offers; BetterDisplay-made HiDPI/virtual modes need `/Library/Displays` overrides, which Orbit does not write). Kevo's displays right now: 2 × ThinkVision P27u-20, AOC Q27G4ZD, Acer K272HUL, lid closed.

### Task 10: Windows — Dock preview + app control (Opus)

**Core (`Sources/OrbitCore/Windows/`):**
- `WindowMatcher.match(axWindows: [WindowDescriptor], captureWindows: [WindowDescriptor]) -> [(ax: Int, capture: Int)]` — by exact window number when known, else title + frame (tolerance 2 pt).
- `DockPreviewLayout`: given thumbnail aspect ratios, the Dock icon frame, Dock edge (bottom/left/right) and the screen's visible frame → strip frame and thumbnail frames (max thumb height 140, spacing 10, clamped on-screen).
- `RunningAppList.sort(_:)` — regular apps, frontmost first then by name; `WindowsSettings`: `dockPreviewEnabled: Bool` (true), `previewDelay: Double` (0.35 s), `showMinimised: Bool` (true).
- Tests `WindowsTests.swift`: `matchesByNumber`, `matchesByTitleAndFrame`, `noMatchBeyondTolerance`, `layoutCentresOverIcon`, `layoutClampsToScreen`, `layoutLeftAndRightDock`, `appListOrder`, `settingsRoundTrip`.

**App (`Sources/OrbitApp/Features/Windows/`):** `AXWindowService` (per app: windows with title, frame, minimised; raise via `kAXRaiseAction` + activate; minimise via `kAXMinimizedAttribute`; close via close button press; window number via `_AXUIElementGetWindow` through `PrivateSymbol`), `DockWatcher` (AXObserver on the Dock process `com.apple.dock`, `kAXSelectedChildrenChangedNotification` on its `AXList`; hovered item → `AXURL`/title → running app; only while enabled + AX granted), `WindowThumbnailer` (ScreenCaptureKit `SCShareableContent` + `SCScreenshotManager.captureImage` on macOS 14+, small size; cached per window for a few seconds), `DockPreviewPanel` (non-activating glass strip above the hovered icon; hover shows title; click raises that window; hides when hover leaves both Dock item and strip), `AppControlService` (NSWorkspace running apps; focus, hide, quit `terminate()`, force quit `forceTerminate()` with a confirmation). `WindowsPanelView`: list of running apps (icon, name, window count), expand to windows (title; bring forward, minimise, close) **[builder's call on the set]**; if Accessibility is missing, window rows show a grant button while app actions still work. `WindowsSettingsView`: Dock preview toggle + delay, show minimised windows, permission rows.

### Task 11: Clipboard history (Sonnet)

**Core (`Sources/OrbitCore/Clipboard/`):**
- `ClipboardItem: Codable, Identifiable` — `id`, `kind` (.text, .richText, .image, .files), `preview` (first 200 chars or file names), `sourceBundleID`, `sourceName`, `date`, `pinned`, `contentHash`, `byteSize`, `payloadFile: String?` (blob filename).
- `PasteboardFilter.shouldRecord(types: [String]) -> Bool` — false when any of `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`, `com.agilebits.onepassword`, `de.petermaurer.TransientPasteboardType` is present.
- `ClipboardHistory` (value type): `add(_:)` (same hash → move to top, keep pinned flag), `togglePin`, `remove`, `clear(keepPinned: true)`, `search(_ query:) -> [ClipboardItem]` (case/diacritic-insensitive on preview + source name), `enforce(limits: ClipboardLimits, now:) -> [ClipboardItem]` returning evicted items (pinned never evicted; by max count, max age, max total bytes, oldest first).
- `ClipboardStore`: JSON index + blob files in a directory given at init (`<support>/Clipboard/`), atomic writes, loads tolerating a corrupt index (start empty, keep the corrupt file renamed `index.corrupt-<date>.json`).
- `ClipboardSettings`: `maxItems` (200), `maxAgeDays` (30), `maxMegabytes` (200), `maxItemMegabytes` (20), `popupShortcut: KeyCombo` (`.clipboardDefault`), `ignoredBundleIDs: [String]`, `pasteDirectly: Bool` (true).
- Tests `ClipboardTests.swift`: `skipsConcealedAndTransient`, `recordsPlainText`, `duplicateMovesToTop`, `pinSurvivesClear`, `searchIsCaseAndDiacriticInsensitive`, `enforcesCountLimit`, `enforcesAgeLimit`, `enforcesByteLimit`, `pinnedNeverEvicted`, `storeRoundTrip` (temp dir), `storeSurvivesCorruptIndex`, `settingsRoundTrip`.

**App (`Sources/OrbitApp/Features/Clipboard/`):** `PasteboardWatcher` (polls `NSPasteboard.general.changeCount` every 0.5 s only while enabled; reads text / RTF / image (TIFF/PNG, stored as PNG) / file URLs; skips via `PasteboardFilter`, ignored apps, and items over `maxItemMegabytes`; source app = frontmost app), `ClipboardPopupPanel` (non-activating key panel at the mouse, search field, ↑/↓, Return, Esc; restores focus to the previous app, writes the item to the pasteboard and, if `pasteDirectly` and Accessibility is granted, posts ⌘V via `CGEvent`; otherwise just copies and shows a small "Copied" hint), hot key via `HotKeyCenter` (id `clipboard.popup`). `ClipboardPanelView`: search field, list (kind icon, preview, source + relative time), click to copy, pin, delete, **Clear** (keeps pinned). `ClipboardSettingsView`: limits, shortcut, paste directly (with Accessibility status + grant button), ignored apps.

### Task 12: Shelf (Sonnet)

**Files beyond the feature folders:** `Sources/OrbitCore/Model/Slice.swift` (`ActionID.shelf`), `Sources/OrbitCore/Catalog/SliceCatalog.swift` (Shelf slice `act(.shelf, "SHELF", "tray")` appended after FLOAT only when `CatalogSettings.showShelfAction` is true), `Sources/OrbitCore/Catalog/CatalogSettings.swift` (`showShelfAction: Bool = false`; `SettingsStore.catalogSettings` cannot see suite state, so the wheel's caller sets it — wire through a `var shelfActionEnabled: () -> Bool` on `WheelController` or the place that builds `CatalogSettings`), `Sources/OrbitCore/Jobs/ActionText.swift`, `Sources/OrbitCore/Processors/Actions/ActionProcessor.swift` (exhaustive switches), `Sources/OrbitApp/Jobs/JobCoordinator.swift` (`.shelf` is a system action → `openShelf?(urls, point)`), `Sources/OrbitApp/AppDelegate.swift` (wire `coordinator.openShelf` to the Shelf feature). Existing catalog tests must pass unchanged.

**Core (`Sources/OrbitCore/Shelf/`):**
- `ShakeDetector`: feed `(point, time)` samples; reports a shake after ≥ 3 horizontal direction reversals, each leg ≥ 40 pt, within 0.6 s; `reset()`.
- `ShelfItems` (value type): ordered unique file URLs with `add(_:)`, `remove(_:)`, `removeMissing(fileExists:)`.
- `ShelfStore`: persists items as security-scope-free path + bookmark data JSON in a given directory.
- `ShelfSettings`: `shakeToOpen: Bool` (true) **[builder's call]**, `keepOnTop: Bool` (true), `lastFrame` per screen.
- Tests `ShelfTests.swift`: `shakeDetectedAfterThreeReversals`, `slowWiggleIsNotShake`, `smallJitterIsNotShake`, `itemsUniqueAndOrdered`, `removeMissing`, `storeRoundTrip`, `catalogShowsShelfOnlyWhenEnabled`, `settingsRoundTrip`.

**App (`Sources/OrbitApp/Features/Shelf/`):** `ShelfPanel` (floating glass `NSPanel`, all Spaces, non-activating, resizable strip, drop target for file URLs, each item draggable out as an `NSDraggingSource` allowing `.copy`, `.move`, `.generic` so Finder applies its usual move-on-same-volume / copy-across-volumes / ⌥-to-copy; an item dragged out with a `.move` result is removed from the shelf; ✕ removes; "Clear"), `ShakeWatcher` (global `leftMouseDragged` monitor installed only while enabled and `shakeToOpen`; only counts while the drag pasteboard holds file URLs; opens the shelf near the cursor), `ShelfPanelView` (menu bar tab: open/close shelf, list of items with icons, drag out from the list too, clear), `ShelfSettingsView`.

### Task 13: Live wallpapers (Opus)

**Core (`Sources/OrbitCore/Wallpaper/`):**
- `AerialCatalog.parse(entriesJSON: Data, localizedStrings: [String: String]) -> [Aerial]` (`id`, `name` from `localizedNameKey` or `accessibilityLabel`, `category`) and `AerialCatalog.locations` = `[~/Library/Application Support/com.apple.wallpaper/aerials/` (macOS 26: `manifest/entries.json`, `videos/<id>.mov`, `thumbnails/`), `/Library/Application Support/com.apple.idleassetsd/Customer/` (macOS 14/15)]`; an aerial is offered only if its video file exists (never download).
- `WallpaperSource: Codable` — `.video(path: String, bookmark: Data?)` / `.aerial(id: String)`; `WallpaperAssignments` keyed by display identity (vendor-model-serial, fallback to localized name).
- `WallpaperPausePolicy.state(for: DisplayConditions) -> PlaybackState` — `DisplayConditions { screenCovered, screenLocked, displayAsleep, onBattery, lowPowerMode, pauseOnBattery, pauseInLowPower }` → `.playing` / `.paused(reason)`.
- `WallpaperSettings`: `assignments`, `pauseOnBattery` (false), `pauseInLowPower` (true), `setStillFrame` (true), `previousDesktopPictures: [String: String]` (to restore when a wallpaper is removed) **[builder's call]**.
- Tests `WallpaperTests.swift`: `parsesEntriesJSON` (fixture modelled on the real file: `assets[].id/accessibilityLabel/localizedNameKey/categories`), `localizedNameWins`, `onlyDownloadedAerialsOffered`, `pauseWhenCovered`, `pauseWhenLocked`, `pauseOnBatteryOnlyIfEnabled`, `pauseInLowPower`, `playsOtherwise`, `assignmentsRoundTrip`, `settingsRoundTrip`.

**App (`Sources/OrbitApp/Features/Wallpaper/`):** `WallpaperWindow` (borderless, `level = CGWindowLevelForKey(.desktopWindow)`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`, `ignoresMouseEvents = true`, frame = screen frame), `WallpaperPlayer` (`AVQueuePlayer` + `AVPlayerLooper`, muted, `AVPlayerLayer` `.resizeAspectFill`, `preventsDisplaySleepDuringVideoPlayback = false`), `WallpaperConditionsMonitor` (window `occlusionState` for covered, `com.apple.screenIsLocked`/`Unlocked` distributed notifications, `NSWorkspace.screensDidSleep/Wake`, IOPowerSources run-loop source, `NSProcessInfoPowerStateDidChange`), `StillFrameWriter` (`AVAssetImageGenerator` at 1 s → PNG in `<support>/Wallpaper/stills/`, then `NSWorkspace.setDesktopImageURL(_:for:options:)` after saving the previous URL), `WallpaperManager` (one window per assigned screen; rebuild on `didChangeScreenParameters`; `stop()` closes all windows and restores nothing else). `WallpaperPanelView`: one card per display (thumbnail, display name, current source, Choose… menu: Video file…, each downloaded aerial, None). `WallpaperSettingsView`: pause toggles, still frame toggle, per-display list. During development **never open a wallpaper window and never set a desktop picture**; verify via snapshots and tests only.

---

## Phase 3 — Integration and review (orchestrator)

### Task 14: Merge and review each feature
- [ ] Merge each feature branch into the suite branch as it finishes (`git merge --no-ff`), resolve conflicts, `swift build && swift test`.
- [ ] Dispatch a fresh reviewer (Sonnet for UI/logic features, Opus for Sound/Displays/Windows/Wallpaper/System) on the feature's diff: spec compliance (spec section + this plan's task), Review Focus items, hardware-safety, code quality. Fix Critical/Important findings (fix agent or inline), re-run build + tests, commit, push.

### Task 15: Finish
- [ ] `Orbit --snapshot-suite docs/suite/screenshots --replace`; inspect each PNG; fix layout problems.
- [ ] Whole-branch review (fresh Opus reviewer) against the spec; fix what it finds.
- [ ] `swift build`, `swift test`, `ORBIT_SIGN_IDENTITY=7AE2AC16D622170662EDB78454372455073E8B0E scripts/build-app.sh`.
- [ ] `docs/suite/QUESTIONS.md` (open questions with the default chosen) and `docs/suite/REPORT.md` (per-section summary, try-it checklist with permissions, hardware verification list, builder's calls, known gaps, install steps).
- [ ] Push; open a draft PR "Orbit Suite" against `main`.
