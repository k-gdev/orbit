# Orbit Suite — design spec

Status: the owner (Kevo) approved building everything below on 2026-10-27 and asked not to
review mockups one by one. Items marked **[builder's call]** were not decided by Kevo; make a
sensible choice, record it in the morning report, and keep going.

## 1. Intent

Orbit today (v1.1.0, `k-gdev/orbit`) is a native Swift menu bar app (LSUIElement) with a radial
"file wheel": while you drag files in Finder you press a modifier and a glass wheel appears to
convert / run tools / take actions on the dragged files. That stays exactly as it is.

Kevo wants Orbit to become **one suite for everything** on his Mac, so he can uninstall a pile of
single-purpose utilities (BetterDisplay, a volume mixer, clipboard manager, shelf app, system
monitor, wallpaper app). Inspiration is Vorssaint Utils (`github.com/vorssaint/vorssaint-utils`),
but Orbit must **not** be a copy:

- Vorssaint is GPL-3.0 with a trademarked name, logo and look. Read its README for feature ideas
  only. **Copy no code, assets, strings, or visual design.**
- Orbit's own look: frosted glass panels (Liquid Glass on macOS 26 via the existing `OrbitTheme`
  helpers, `.ultraThinMaterial` fallback on 14/15), Control Center–style pill sliders, the
  user-changeable accent (default `#80649C`), SF Symbols.

Success = Kevo wakes up, installs one build, and can use every section below on his real Mac:
Apple M5 Max, macOS 26.5, four displays (built-in MacBook Pro + two Lenovo ThinkVision + one
more external), SteelSeries Arctis Nova headset, MacBook Pro speakers.

## 2. Non-goals / anti-goals

- No change to the existing wheel's behaviour, catalog or processors (except adding a Shelf
  action, §5.7). All existing tests must keep passing.
- No copying from Vorssaint (see above).
- No feature may cost CPU while it's turned off. No permission prompt for a feature the user has
  not turned on.
- Minimum macOS stays **14.0**. Features needing newer APIs are gated with `#available` and shown
  as unavailable (with the reason) on older systems.
- No kernel extensions, no root helpers, no writes to `/Library` or `/System`.

## 3. App shell

### 3.1 Menu bar panel (layout "A": tabs across the top)
- Clicking Orbit's menu bar icon opens a ~390 pt wide frosted panel anchored under the icon.
- A row of tabs across the top, icon + small label: **Sound, System, Displays, Windows,
  Clipboard, Shelf, Wallpaper**. Only enabled features get a tab. Remember the last tab.
- Section content below the tabs as tiles (rounded, translucent white), section headers in small
  caps, footer with **Settings…** and **Quit Orbit**.
- The existing menu (recent jobs, wheel settings, etc.) moves into this panel / Settings
  **[builder's call]** on exactly where; nothing existing may be lost.
- Reference mockup: `docs/suite/menu-bar-mockup.html` (Sound and Displays tabs). Match its
  structure and feel, not pixel-for-pixel.

### 3.2 Settings window (layout "B": side rail)
- One Settings window with a left side rail: General (accent colour, launch at login, existing
  general settings), Wheel (all existing wheel/catalog settings), **Features**, then one page per
  section (Sound, System, Displays, Windows, Clipboard, Shelf, Wallpaper), About.
- **Features page**: a toggle per section, what it does in one line, which permissions it needs
  and their current status, with a button that opens the right System Settings pane. Turning a
  feature on asks for its permissions then; turning it off stops all its work.
- Existing settings UI migrates into this window; the Full Disk Access welcome stays.

### 3.3 Architecture
- Each section is a self-contained feature module behind a common protocol (enable / disable /
  required permissions / menu bar tab view / settings view). Pure logic (parsers, state machines,
  models, formatting, persistence) lives in `OrbitCore` with Swift Testing tests; OS glue
  (Core Audio, IOKit, AX, ScreenCaptureKit, AVFoundation windows) in `OrbitApp`.
- Private APIs (DisplayServices, IOAVService DDC, IOHIDEventSystem sensors) are loaded with
  `dlsym` behind a small wrapper so a missing symbol degrades gracefully instead of crashing.
- Add the needed Info.plist usage strings (e.g. `NSAudioCaptureUsageDescription`).

## 4. Permissions per feature

| Feature | Needs |
|---|---|
| Sound (per-app volume/routing) | System Audio Recording (Core Audio process taps, macOS 14.2+) |
| Sound (mic mute shortcut) | none beyond a global hotkey |
| System | none |
| Displays | none (DDC via IOKit) |
| Windows: app list, quit/hide | none; window titles/raise need Accessibility |
| Windows: Dock preview | Accessibility + Screen Recording |
| Clipboard | none to record; Accessibility to auto-paste |
| Shelf | none |
| Wallpaper | none |

## 5. Sections

### 5.1 Sound (mockup: Sound tab)
Top tiles:
- **Output**: current output device pop-up + master volume pill.
- **Alerts & system sounds**: its own output device pop-up (the system output device).
- **Microphone**: input device pop-up, input level pill, mute button. A global shortcut
  (default ⌃⌥M **[builder's call]**, configurable) mutes/unmutes the mic; while muted, a
  crossed-out mic badge shows in the menu bar.

Apps list:
- Shows only apps **currently making sound** (small animated level bars) plus apps the user
  **pins**; "Show all apps" lists every running app with audio.
- Each app is one pill: app icon + name inside, volume **0–150%** (striped boost zone past 100,
  same visual language as display boost). Clicking the icon mutes/unmutes the app.
- A round button at the right of each row picks that app's output device (Same as Output /
  any device). Example from Kevo's setup: Chrome to MacBook speakers, everything else on the
  headset.

Settings: preferred microphone (if macOS switches input to something else, switch back), remember
per-app volume/mute/output across launches, the mute shortcut, which apps are pinned.

Implementation notes: Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`,
`muteBehavior = .mutedWhenTapped`, an aggregate device per destination output, IOProc applying
gain), process discovery via `kAudioHardwarePropertyProcessObjectList` /
`kAudioProcessPropertyIsRunningOutput` / bundle ID. Default devices via
`kAudioHardwarePropertyDefaultOutputDevice`, `...DefaultSystemOutputDevice`,
`...DefaultInputDevice`. Mic mute via the input device's mute/volume property (restore on unmute
and on quit). Tear down every tap and aggregate device cleanly on disable/quit/crash-restart; a
leaked tap that keeps an app muted is the worst failure here.

### 5.2 System
Tiles for: CPU load (per-cluster or total, with a small history sparkline), GPU load, memory
(used / pressure), temperatures (CPU/GPU/SoC sensors on Apple Silicon), uptime, and **batteries**:
the Mac's own battery plus connected Bluetooth devices that report a level (AirPods, mice,
keyboards, headsets). Sample only while the panel is open, except an optional menu bar readout
**[builder's call]**.

### 5.3 Displays (mockup: Displays tab) — replaces BetterDisplay
Kevo uses BetterDisplay only for resolution and brightness across his 4 monitors.
- One tile per display: name, resolution pop-up (all modes incl. the HiDPI modes macOS offers),
  brightness pill.
- Built-in display brightness via DisplayServices; external displays via **DDC/CI** (VCP 0x10)
  over `IOAVService` on Apple Silicon.
- **Brightness boost**: Kevo's ThinkVisions accept brightness up to **150**, but only from the
  monitor's own button menu. Read each monitor's max from the DDC reply and allow the full range;
  past 100 shows as the striped boost zone. Settings has a per-display "maximum brightness"
  override for monitors that report 100 but accept more.
- "Link brightness" moves all displays together (proportionally).
- Software dimming (gamma) fallback for displays that don't answer DDC.
- If Kevo currently relies on BetterDisplay-made HiDPI modes, note in the morning report what
  Orbit can and can't replace (no writes to `/Library/Displays`).

### 5.4 Windows — Dock preview + app control
- **Dock preview**: hovering a Dock icon shows a glass strip of that app's window thumbnails
  above the Dock (ScreenCaptureKit); click one to bring it forward, hover shows the title.
- **App control** tab: running apps with their windows; per app: focus, hide, quit, force quit;
  per window: bring forward, minimise **[builder's call]** on the exact set.

### 5.5 Clipboard history
- Records text, rich text, images and file copies with source app and time; skips anything marked
  concealed/transient (password managers: `org.nspasteboard.ConcealedType`,
  `org.nspasteboard.TransientType`).
- Menu bar tab: searchable recent list, pin items, clear.
- Global shortcut (default ⌘⇧V **[builder's call]**) opens a popup at the cursor; arrow keys +
  Return pastes into the frontmost app (Accessibility) or just copies if not granted.
- Persisted in Application Support with a size/age limit in Settings.

### 5.6 Shelf
- A floating glass shelf that holds files temporarily while you move between windows/spaces.
- Opens by shaking the cursor during a file drag **[builder's call]**, from a new **Shelf** action
  in the wheel's Actions ring, and from the menu bar tab.
- Drop files on it; drag them back out (move or copy) later; items persist until removed.

### 5.7 Live wallpapers (per display)
Problem Kevo wants solved: Apple's live wallpapers freeze while you use the desktop. Orbit's keep
moving.
- Choose a wallpaper **per display**: a video file of the user's, or one of Apple's aerials
  already downloaded on the Mac (`/Library/Application Support/com.apple.idleassetsd/`; read its
  manifest for names; never download).
- A borderless desktop-level window per screen (below desktop icons, all Spaces, ignores mouse)
  with a muted looping `AVPlayerLayer`.
- Pause when the screen is covered by a full-screen app, locked or asleep, and optionally on
  battery / Low Power Mode. Also set that screen's normal desktop picture to a still frame so
  Mission Control and Space switches match.
- Wallpaper tab: one card per display with a thumbnail and a picker.

## 6. Constraints for the build itself

- Swift 6.3 toolchain, swift-tools 6.0, Swift 5 language mode, SwiftPM targets
  `OrbitCore` / `OrbitApp` / `OrbitCoreTests` — follow the existing structure and idioms.
- `swift build` and `swift test` stay green; every new pure-logic unit gets tests.
- The app bundle builds with `scripts/build-app.sh`.
- Hardware and the user's real settings are **not** to be changed unattended: no changing real
  brightness/resolution, default audio devices, mic mute, or desktop pictures, and no leaving
  desktop windows up. Read-only probes (listing displays, DDC capability/max reads, listing audio
  devices/processes, reading sensors) are fine and useful.
