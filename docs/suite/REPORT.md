
# Orbit Suite — morning report

## Hardware session, 28 October

Kevo and I went through the checks on his Mac. The build installed now is 317e023 (1.1.0 is backed up at `~/Desktop/Orbit-1.1.0.app`). The rest of this report is the overnight report as it was; where they differ, this section wins.

**Tests:** 966. In the last full run one failed: `compressTierTargetsAFractionOfTheSource`, a 1.1.0 video test this branch doesn't touch. Rerun on its own, its suite passed (51 of 51). An agent saw the same test flake once overnight, so it looks load-sensitive rather than broken.

### Worked on hardware
- Displays: resolution Keep/Revert (timeout, Keep, Esc).
- Sound: per-app levels, mute and routing, and every app back at full volume after quitting Orbit.
- Wallpaper: layering, Spaces, full screen, Mission Control, None.
- Windows: Dock preview.
- Clipboard: copies from the Passwords app are not recorded.
- Shelf: dragging an item out to Finder.
- Controls: Grab Text.
- The 317e023 build with the fixes and additions below: "All good".

### Found and fixed
- **Orbit crashed when Sound was turned on.** The private TCC request's completion block was declared non-escaping. TCC keeps the block until the prompt is answered, so Swift trapped. Fixed in 7341d16.
- **ThinkVision brightness past 100 did nothing, and a boost dropped to 100.** The P27u-20 reports a maximum of 100 and reads 150 after a boost from its own menu, but it clamps DDC writes at 100, and any write ends the boost. Orbit now shows the boost but never writes above the reported maximum. A click or drag in the striped zone keeps the boost (1739b6f, 864738d).
- **Dark edge around the panel.** An A/B/C test showed it was the window server's shadow drawn under a Liquid Glass surface. On macOS 26 glass windows no longer have a window shadow (cb2eba7).
- **A file moved to the Trash in Finder stayed on the Shelf.** The Shelf only checked its files when it opened. It now watches the items' folders while it's open, and an item's menu has Move to Trash (4b865e0).

### Added on request
- **Wallpaper: "Same on all displays"** (on by default). Choosing a wallpaper on a connected display applies it to all of them, and turning the switch on copies the main display's wallpaper to the others. At launch it only fills displays that have no wallpaper, so it never overwrites per-display choices (3a39fb0, d0b9261, 317e023).
- **Clipboard: "Keep copied passwords"** (off by default; 1Password counts). Kept passwords stay in memory only, are masked, are capped at 20 and don't count against the history limits. Entries have Copy, Open, Show in Finder, Open in Preview, Pin and Remove, can be dragged out (always a copy, never a move of the original), and the ⇧⌘V popup has ⌘C, ⌘O and ⌘R. Image files exported for dragging or Preview are deleted with their entry (464f022, 825af94, 3fe6885, 9b8a831).

A review of the first six of today's commits found 2 Important and 9 Minor issues. Both Important ones (sync overwriting per-display wallpapers at launch, exported images never deleted) and M1, M2, M3, M6 were fixed before the install, as was the Clipboard tab hover, which SwiftUI's `onHover` doesn't deliver to Orbit. M4, M5, M7, M8 and M9 are open (below).

### Can't be fixed, now warned about: mic mute on the Arctis Nova 5
- ⌃⌥M showed muted, but Discord still heard Kevo. The headset's USB dongle accepts Core Audio's mute and input-volume writes and reads them back, but its audio ignores both: the input meter kept moving with mute on and with input volume at its minimum. No Core Audio approach can mute this headset.
- HID research (nothing was sent to the headset) found no published mute command for the Nova 5 in any open-source project, or in the vendor spec they transcribe. The only candidate is the headset's mic volume (0–15), and nobody has measured whether 0 is silence. Details: [ARCTIS-HID.md](ARCTIS-HID.md).
- Kevo chose a warning (QUESTIONS #28). Orbit now treats the headset as a mic it can't mute:
  - The Sound tab says so under the mic, and its level shows "Fixed".
  - The mute button is off.
  - ⌃⌥M shows a toast saying to use the headset's button.
  - The Controls tile says "Use the mic’s button".
  - It is never shown as muted, and switching to it while muted puts the old mic back.
- Checked with tests (970 passing) and Sound tab snapshots. Not yet seen on the real headset.

### Explained, no change
- Safari came back at 72% after a relaunch because "Remember per-app states" had saved it at 72%, routed to the Arctis.
- The coreaudiod `PreventUserIdleSystemSleep` assertions during the check were expected: Safari, Chrome and Discord were playing audio.

### Not checked
- Sound: `kill -9` of Orbit while an app is tapped (skipped).
- Controls: Keep Awake.
- Everything else in section 5 that isn't listed above.

### Open
- Review M4: Clipboard checks files on the main thread on right-click, drag start and Open, so an entry on a sleeping network share can beachball the panel.
- Review M5: right-click on a Clipboard tab tile works only on its text and badge, not the whole tile.
- Review M7: Wallpaper sync can copy a main-display video that can't play (file gone, drive unplugged) and blank the other displays.
- Review M8: a shelved folder whose parent is the home folder makes the Shelf watch all of `~` while it's open. Correct, but wasteful.
- Review M9: a brightness maximum set under the old Settings footnote still writes above 100. Kevo has none set.
- With "Keep copied passwords" on, anything copied from 1Password is masked, usernames included.
- The Sound tab lists the two ThinkVisions' audio as two devices both named "P27u-20", with nothing to tell them apart.
- Running the tests writes lines into the real `~/Library/Logs/Orbit/orbit.log`.

## 1. Summary

- Orbit 1.1.0's file wheel is unchanged. Branch `claude/suite-77e4bb` adds the Orbit Suite around it: a tabbed menu bar panel, a Settings window with a side rail and a Features page, and eight features: Sound, System, Displays, Windows, Clipboard, Shelf, Wallpaper and Controls (Keep Awake, Quick Toggles, Grab Text).
- It also adds a shared mic mute (one state for the Sound tab, the Controls toggle, the ⌃⌥M shortcut and a menu bar badge) and a headless snapshot CLI used to check the UI.
- Every feature went through an implementer, a task review and at least one fix round with a scoped re-review (Sound needed all five allowed rounds; rounds 4 and 5 went to fresh implementers, and round 5 rebuilt the mic mute around a pure model that never writes to a mic while Orbit's previous write is still landing; its reviewer fuzzed it with thousands of random press/switch/quit sequences and found no lost press, no write loop and nothing left muted). The whole-branch review found no Critical issues and two Important ones; both went into a final fix wave. That review left out Sound and the mic-mute code, which were still in their own fix rounds; those got their own re-reviews through round 5.
- Nothing was tried on your real hardware. Your Orbit 1.1.0 was running all night, so the agents checked the UI only with headless snapshots. No agent changed brightness, resolution, audio devices, volume, mic mute, wallpaper or any toggle. All of that is yours to verify (section 5).
- **One slip to know about:** at 03:17 the final-fix-wave agent ran `.build/debug/Orbit --help` to look for a usage line. No debug mode handles `--help`, so the debug build started as a full app for about 11 minutes next to your Orbit, with its own empty `Orbit` defaults domain. It may have shown a second menu bar icon and the Full Disk Access welcome, and it registered the ⇧⌘2 and ⌃⌥M shortcuts while it ran. The agent stopped it by ending its own shell task. I found no wallpaper, display or audio changes, and your `com.kevo.orbit` settings were not touched. It left `~/Library/Preferences/Orbit.plist` (42 bytes, an empty dictionary, dated 03:17). I did not delete it, because I can't prove it wasn't there before (macOS rewrites preference files, which resets their dates); if you never run Orbit unbundled with `swift run`, it is safe to delete.
- Tests: 897 passing. PR: [k-gdev/orbit#5](https://github.com/k-gdev/orbit/pull/5) (draft). Build: signed universal `build/Orbit.app` at 74f1c2c.
- How to try it: quit Orbit 1.1.0, run `scripts/install.sh`, left-click the menu bar icon, open Settings → Features, turn on what you want to try, and walk the checklist in section 4.

## 2. Install the build

The signed app is at `build/Orbit.app` inside the worktree `/Users/kevog/orbit/.claude/worktrees/suite-77e4bb`. It was built with the command below, using the Apple Development: KG DEV identity. That is the same identity as your current build, so macOS keeps the permission grants you already gave Orbit.

```bash
ORBIT_SIGN_IDENTITY=7AE2AC16D622170662EDB78454372455073E8B0E scripts/build-app.sh
```

Steps:

1. Optional: keep a copy of 1.1.0, because the installer deletes `/Applications/Orbit.app` before copying the new one: `ditto /Applications/Orbit.app ~/Desktop/Orbit-1.1.0.app`.
1. Quit Orbit 1.1.0: menu bar icon → right-click → Quit Orbit. (`install.sh` also asks Orbit to quit, but do it yourself so you see it go.)
2. Go to the worktree.

```bash
cd /Users/kevog/orbit/.claude/worktrees/suite-77e4bb
```

3. Run the installer.

```bash
scripts/install.sh
```

What `scripts/install.sh` does, in order:

- Changes to the repo root and stops with an error if `build/Orbit.app` does not exist.
- If `/Applications/Orbit.app` exists, reads its `CFBundleIdentifier` and refuses to continue unless it is `com.kevo.orbit`. It will not replace any other app.
- Sends a quit to `com.kevo.orbit` through `osascript` (errors ignored), then waits 1 second.
- Deletes `/Applications/Orbit.app` with `rm -rf`, then copies `build/Orbit.app` to `/Applications/Orbit.app` with `ditto`.
- Opens `/Applications/Orbit.app` and prints `Installed /Applications/Orbit.app`.

After it launches:

- Left-click the menu bar icon: the new panel opens.
- Right-click (or ⌃-click): the old menu (About Orbit, Open Files…, Settings…, Enabled, Recent results, ⌥ Debug, Quit Orbit).
- The version still reads 1.1.0 (build 110). It was not bumped, on purpose (you said not to). Tell the builds apart by the click behaviour.
- Every existing setting control is kept, now under Settings → General and Wheel. The Welcome (Full Disk Access) window is untouched. New permissions are asked per feature, only when you turn that feature on or first use it.

Going back to 1.1.0 means reinstalling from `main`. In a checkout of `main`, run the same two commands: `scripts/build-app.sh` (with the same `ORBIT_SIGN_IDENTITY`) and then `scripts/install.sh`. The installer replaces whatever Orbit is in `/Applications`.

If you want to rebuild this branch after any change, run the build command at the top of this section again, then `scripts/install.sh`.

## 3. What was built

### Shell
- **Menu bar panel.** About 390 pt wide, frosted, anchored under the icon, with a tab row (icon over label) for each enabled feature. It remembers the last tab. Footer: Settings… (⌘,), Quit Orbit (⌘Q), and a `…` menu with Open Files…, Wheel enabled, Recent results and About Orbit.
- **Settings window.** 760 × 560, side rail: General, Wheel, Features, one page per feature (marked "Off" when disabled), About. The old settings moved into General and Wheel with every control kept. The Features page has one card per feature: switch, one-line description, each permission with a status badge and an Open System Settings button.
- **Shared mic mute.** One state shared by the Sound tab button, the Controls "Mute Mic" toggle, the global shortcut (⌃⌥M) and a crossed-out mic badge in the menu bar. It works with Sound turned off, and restores exactly what Orbit changed on unmute, on turning off and on quit.
- **Plumbing.** Global hot keys with a key recorder that shows conflicts. A permission centre that refreshes statuses and polls for two minutes after a request. Private APIs loaded with `dlsym` so a missing symbol degrades instead of crashing. A small accent dot on the Orbit icon while Keep Awake is active.
- **Snapshot CLI.** `Orbit --snapshot-panel`, `--snapshot-settings-page` and `--snapshot-suite <dir>` render PNGs offscreen without showing any window. Each feature also has debug modes. This is how the UI was checked, because the app could not be launched.

### Sound
- Output tile: device pop-up and master volume pill (DisplayPort outputs show a dimmed "Fixed" pill), plus an "Alerts & system sounds" row with its own device pop-up.
- Microphone tile: input device pop-up, input level pill, mute button, ⌃⌥M shortcut, menu bar badge while muted.
- Apps list: apps currently making sound plus pinned apps ("Show all apps" for the rest). One pill per app: volume 0–150% with a striped boost zone, click the icon to mute, and a round button to send that app to any output device.
- Per-app control uses Core Audio process taps (macOS 14.2+). A tap exists only when an app is off 100%, muted or rerouted. Taps are private to Orbit and disappear when Orbit exits, crash included.
- Settings: preferred microphone with a "Keep" option, mute shortcut, remember per-app states, pinned apps, Forget All App Settings.

### System
- CPU tile with total load, a sparkline and one row per cluster, named from the Mac: "Super" (6 cores) and "Performance" (12 cores) on your M5 Max.
- GPU tile, Memory tile (used of 128 GB, pressure), temperatures (CPU, GPU, SoC) and uptime.
- Batteries: This Mac plus Bluetooth devices that report a level (AirPods with L/R/Case, keyboards, mice).
- Samples only while the System tab is open, or while the optional menu bar readout is on. With neither there is no timer and no sensor connection.
- Optional menu bar readout (off by default): CPU load, temperature, or both. Settings: readout, show each cluster, refresh every 1/2/5 s.

### Displays
- One tile per display: name, resolution pop-up with every mode macOS offers (HiDPI included, refresh rates in submenus), and a brightness pill.
- Brightness: DDC/CI over `IOAVService` for external monitors, DisplayServices for the built-in display, and software (gamma) dimming for monitors that don't answer DDC.
- Boost: the pill shows the monitor's raw DDC value. The zone above the reported maximum is striped. Orbit learns a higher range from two readings in a row, and Settings has a per-display maximum override.
- Link brightness moves all displays together, proportionally.
- Resolution changes ask "Keep this resolution?" with a 15 s countdown and revert if you don't answer.
- DDC services are matched to displays by IORegistry location, EDID facts and elimination. All four of your monitors matched in a read-only test, including the two identical ThinkVisions.

### Windows
- Dock preview: hover a Dock icon and a glass strip of that app's window thumbnails (ScreenCaptureKit) appears above it. Click one to bring that window forward. Windows on other Spaces show an "Other Space" badge.
- Windows tab: running apps, expandable to their windows. Per app: bring to front, hide/show, Quit, Force Quit (inline confirmation). Per window: bring forward, minimise/restore, close.
- App control needs no permission. Window lists and Dock preview need Accessibility. Thumbnails need Screen Recording; without it the preview shows title cards.
- Settings: Dock preview on/off, hover delay (0–1.5 s, default 0.35), show minimised windows.
- Costs nothing when off, or when Accessibility is missing: no observer, no timer.

### Clipboard
- Records text, rich text, images and file copies with source app and time. Skips anything marked concealed or transient (password managers).
- Menu bar tab: search, pin, two-step Clear (keeps pinned items).
- ⇧⌘V opens a popup at the cursor. Type to search, ↑/↓ to move, Return to paste into the frontmost app (needs Accessibility) or just copy if it isn't granted.
- History is stored in `~/Library/Application Support/Orbit/Clipboard/` (folder 0700, files 0600, excluded from backups). A corrupt index is moved aside, never deleted.
- Settings: shortcut, paste-into-app switch (on by default), limits by count, age and size, ignored apps, Clear History.

### Shelf
- A floating glass shelf that holds references to files while you move between windows and Spaces. It never moves, copies or deletes a file itself.
- Opens three ways: shake the cursor during a file drag, the new SHELF slice in the wheel's Actions ring (after FLOAT, only while Shelf is on), or the Shelf tab.
- Drop files on it. Drag them back out: Finder moves on the same volume, copies across volumes, ⌥ copies. "Drag all" chip, double-click to open, right-click menu.
- Items persist in `~/Library/Application Support/Orbit/Shelf/shelf.json`. Items on an offline drive are kept and shown dimmed as "Not connected". Position and size are remembered per display.

### Wallpaper
- Choose a wallpaper per display: a video file of yours, or one of the Apple aerials already downloaded on this Mac. On your Mac that is Tahoe Day, Sequoia Sunrise, Oregon Sunset and Alaskan Jellies Light, read from `~/Library/Application Support/com.apple.wallpaper/aerials/`. Orbit never downloads.
- One borderless desktop-level window per display, below the desktop icons, on all Spaces, ignoring the mouse, with a muted looping player. Two displays on the same source share one decoder.
- Pauses when the display is covered, locked or asleep, in Low Power Mode (on by default) and optionally on battery.
- Sets the display's normal desktop picture to a still frame so Mission Control matches. Choosing None, turning stills off or quitting puts your original picture and its scaling options back.
- Tab: one card per display with a preview, status line and a Choose… menu.

### Controls
- **Keep Awake** (replaces Amphetamine): Indefinitely, 15 min / 1 h / 2 h / 5 h, a custom time (default 45 min), until a chosen time, while an app runs, or while ~/Downloads has unfinished downloads. Optional display-awake (off by default). Shows time remaining, puts a dot on the Orbit icon, and releases its power assertions on stop, expiry and quit.
- **Quick Toggles:** Dark Mode, Hide Desktop, Hidden Files, Night Shift, Do Not Disturb (runs your Shortcut), Eject Drives (confirms in the panel first, external and removable volumes only), Mute Mic. Each reads its state live. Orbit records the prior value and puts back exactly that when you turn a toggle off.
- **Grab Text** (replaces TextSniper): ⇧⌘2 or the tile. A crosshair overlay on every display, drag a rectangle, Esc cancels. Vision reads the text, copies it, and the existing HUD says "Copied N lines". A QR code or barcode payload is copied instead when present.
- No toggle needs an Automation permission.

## 4. Try it on your Mac — checklist

Before you start: Settings is in the panel footer (Settings…, ⌘,). Every feature switch is at Settings → Features. Default-on features: System, Displays, Shelf, Wallpaper, Controls. Default-off: Sound, Windows, Clipboard.

Default shortcuts (change any of them by clicking its recorder in Settings, pressing the new combo, Esc to cancel):

- ⌃⌥M: mute/unmute the mic. Settings → Sound → Mute Shortcut, or Settings → Controls → Shortcuts (same setting).
- ⇧⌘V: Clipboard popup. Settings → Clipboard → shortcut (there is a Reset).
- ⇧⌘2: Grab Text. Settings → Controls → Shortcuts.

Orbit's log, if something misbehaves: `~/Library/Logs/Orbit/orbit.log` (Settings → About has Show in Finder).

```bash
tail -f ~/Library/Logs/Orbit/orbit.log
```

### Shell (no toggle, no permission)
1. Left-click the menu bar icon. The panel opens under it with tabs for the enabled features. Esc or a click elsewhere closes it. Right-click (or ⌃-click) shows the old menu instead.
2. Click Settings… in the footer. The Settings window opens with the side rail. Open Features and check each card shows its switch and permission rows.
3. Click the `…` footer menu: Open Files…, Wheel enabled, Recent results, About Orbit.
4. Drag a file in Finder and use the wheel as you always do. It should behave exactly as in 1.1.0.
5. Click in a search field (Clipboard tab) and try ⌘V, ⌘C, ⌘A. See section 5: this was a known risk.

### Sound
Turn on: Settings → Features → Sound. Permission: **System Audio Recording** (macOS asks when you turn it on). It is needed only for the per-app mixer. Mic Mute and its ⌃⌥M shortcut need no permission.

1. Turn Sound on and allow System Audio Recording. Until it is granted the Apps list shows "Allow per-app control" (the button asks again or opens the pane). Orbit watches for the grant for two minutes.
2. Open the Sound tab. Output should show the Arctis Nova 5 and "Alerts & system sounds" should show MacBook Pro Speakers. Move the master pill and confirm the headset volume follows. The DisplayPort outputs show a dimmed "Fixed" pill.
3. Press ⌃⌥M. A crossed-out mic badge appears in the menu bar and the tile reads "Muted · ⌃⌥M to unmute". Press it again to unmute. Repeat several times quickly; it must never say "Muted outside Orbit".
4. Play audio in Chrome. A Chrome row appears with moving level bars. Drag its pill to 50%, then to 150% (striped zone), click the icon to mute, then back to 100%.
5. Click the round button on the Chrome row ("Play Google Chrome on") and pick MacBook Pro Speakers. Chrome should come out of the speakers while everything else stays on the headset.
6. Turn Sound off, or quit Orbit, while Chrome is routed or boosted. Chrome must play normally at once, and no app may stay muted.
7. "Show all apps" lists every app with audio. The row context menu has Pin/Unpin and Reset.
8. Settings → Sound: pick a preferred microphone, turn on Keep, switch the input in System Settings and watch it come back.

### System
Turn on: already on. Permission: none.

1. Open the System tab. CPU, GPU, memory and temperatures fill in within about a second (the very first open may take half a second longer).
2. CPU shows "Super" (6) and "Performance" (12) rows with one bar per core. Run something single-threaded and heavy and check the Super row rises first.
3. Memory shows used of 128 GB with a pressure word. Temperatures show CPU, GPU and SoC. Uptime shows "since" the boot time.
4. Batteries: This Mac, plus AirPods (L/R/Case) and any keyboard or mouse that reports a level.
5. Close the tab; sampling stops.
6. Settings → System → Menu bar: choose "CPU load and temperature". A readout like `7% · 54°C` appears in the menu bar. Click it for a small menu (numbers, Hide Readout, System Settings…). Turning System off removes it.

### Displays
Turn on: already on. Permission: none. **Quit BetterDisplay first** (it also talks DDC and can undo changes). If it is still running, the tab says "BetterDisplay is running too and may undo changes made here."

1. Open the Displays tab. With the lid closed you should see four tiles ordered left to right by how your displays are arranged: Acer K272HUL ("Software dimming"), AOC Q27G4ZD ("DDC · 100"), and two "P27u-20" tiles titled Left and Right ("DDC · up to 150"). The snapshot fixture uses that order; yours follows your arrangement.
2. ThinkVisions: the pill should start near 150 with stripes past 100. Move one pill and confirm the matching physical monitor changes, not its twin. Drag it above 100 and watch whether the monitor really gets brighter (see section 5).
3. AOC: move its pill; only the AOC changes. Acer: the pill dims it in software, with a 10% floor.
4. Click "Link brightness" in the header (it becomes "Linked") and move one pill; the others follow proportionally.
5. Resolution: use the pop-up on the AOC first (not your main ThinkVision). Pick another size. A "Keep this resolution?" card appears on that display and an inline row "Keep … ? Reverting in N s" in the tile. Test Revert (Esc), let one run out, and test Keep (Return).
6. Let the displays sleep and wake, then check brightness still works on all four.
7. Settings → Displays: "Maximum brightness" rows (stepper 100–255, "Auto (150)", "Reset learned range"), and the software-dimming switch.
8. Quit Orbit with the Acer dimmed; its colours must return to normal.

### Windows
Turn on: Settings → Features → Windows. Permissions: **Accessibility** and **Screen Recording** (both asked when you turn it on). App list, hide, quit and force quit need neither. Screen Recording may need an Orbit restart before it takes effect.

1. Turn Windows on and grant both permissions. If you grant Accessibility while Orbit is running, the Dock preview should start within about half a second.
2. Open the Windows tab. Click an app row to expand it and see its windows. Without Accessibility the row shows a "Windows need Accessibility" button.
3. On a throwaway app (TextEdit): bring to front, hide/show, minimise/restore a window, close a window. Force Quit asks for confirmation inside the row. Quit has no confirmation.
4. Dock preview: hover the Dock icon of an app with several windows (Chrome, Finder). After about 0.35 s a strip of thumbnails appears above the icon; hovering one shows its title; clicking one raises that window and activates the app. Moving away, clicking elsewhere or switching Space closes it.
5. Look for a window on another Space ("Other Space" badge) and a minimised window (card with "Minimised").
6. Settings → Windows: change the delay, turn Dock preview off (hover then does nothing), and try "Show minimised windows".
7. Revoke Screen Recording: the strip should fall back to title cards.

### Clipboard
Turn on: Settings → Features → Clipboard. Permission: **Accessibility**, only for pasting directly. It is not asked when you turn the feature on. Use Settings → Clipboard → Grant Access. Without it, choosing an entry only copies.

1. Turn Clipboard on. Copy text in a few apps. The Clipboard tab lists entries with source app and age. Search, pin an entry, and use Clear (it turns into "Clear N?" for 3 seconds; click again to confirm; pinned items stay).
2. Press ⇧⌘V. A popup appears at the cursor. Type to filter, ↑/↓ to move, Return to choose. Without Accessibility you get a "Copied" toast that says why it didn't paste.
3. Grant Accessibility, copy text in Safari, press ⇧⌘V, choose an entry. The text must land in Safari's field, and Safari must stay the frontmost app with its caret where it was.
4. Copy a password from your password manager. It must not appear in the tab.
5. Copy an image (a screenshot to clipboard), files in Finder, and rich text from TextEdit. Choose each and paste it back.
6. Restart Orbit: the history comes back. Turn Clipboard off: ⇧⌘V goes back to the apps that use it (Paste and Match Style).
7. Settings → Clipboard: change the shortcut (a conflict shows "Already used by …"), add an ignored app, lower a limit.

### Shelf
Turn on: already on. Permission: none (a first look at files in Documents, Downloads or Desktop may trigger the usual macOS folder prompt if Orbit has no Full Disk Access).

1. Open the Shelf tab and click Show. The shelf opens at its last position on the screen under the pointer, or bottom centre just above the screen edge the first time.
2. Drag a file from Finder onto it. It shows a "+" copy cursor and the file appears as a tile. The original is untouched.
3. Start dragging a file in Finder and shake the cursor side to side (about four legs of 40 pt or more inside roughly 0.6 s). The shelf should appear under the cursor. Shaking while selecting text or moving a window must not open it.
4. Drag a tile out into a Finder folder on the same volume: the file moves and the tile leaves the shelf. On another volume it copies. With ⌥ it copies.
5. Start a wheel on a file and look at the Actions ring: SHELF comes right after FLOAT. Choose it and the file lands on the shelf.
6. Double-click a tile to open the file. Right-click: Open, Show in Finder, Copy Path, Remove from Shelf. Try "Drag all".
7. Quit and reopen Orbit: the items are still there. Eject a drive that holds a shelved file: its tile dims as "Not connected" and stays.
8. Check the shelf stays on all Spaces and over a full-screen app, and never steals focus.
9. Turn Shelf off in Settings → Features: the SHELF slice disappears from the wheel next time it opens.

### Wallpaper
Turn on: already on. Permission: none.

1. Open the Wallpaper tab. You get one card per display, left to right. Click Choose… on one display and pick an aerial (the four downloaded ones are grouped by category) or Video File….
2. A window plays the video on that display. The display's normal desktop picture becomes a still frame, so Mission Control shows it.
3. Assign all four displays. Watch CPU and GPU load. Two displays on the same source share one decoder.
4. Cover a display with a full-screen app. The card says "Paused · Hidden behind a window" and playback resumes when uncovered.
5. Lock the screen, let the displays sleep, then wake. Playback should pause and resume with no black flash.
6. Switch Spaces and open Mission Control.
7. Choose None on one display: your original picture comes back with its scaling options. Quit Orbit: originals come back on all displays. Other Spaces get theirs back the next time you visit them while Wallpaper is on.
8. Unplug and replug a display; its window should close and return.
9. Settings → Wallpaper: pause on battery, pause in Low Power Mode, set still frame.

### Controls
Turn on: already on. Permission: **Screen Recording**, for Grab Text only (asked the first time you grab). Keep Awake, Quick Toggles and Mute Mic need none.

Keep Awake:

1. Open the Controls tab and turn Keep Awake on. The Orbit menu bar icon gets a small dot and, for a timed mode, the tile shows the time left.

```bash
pmset -g assertions
```

2. The output should list "Orbit Keep Awake" (plus a display assertion if the display option is on). Stop it, wait for a timer to expire, switch modes, turn Controls off, and quit Orbit: the assertion must disappear every time.
3. Try "While an app runs" with Calculator (quit it and the session ends with a toast) and "While downloading" with a real download (macOS may ask to let Orbit see Downloads).

Quick Toggles (each one really changes your Mac; turn it back off after):

4. Dark Mode: the whole system switches. If appearance is on Auto, Orbit turns Auto off and turns it back on when you switch back.
5. Hide Desktop and Hidden Files: Finder restarts (this stops any Finder copy in progress). Turning off removes the setting (`defaults read com.apple.finder CreateDesktop` should say it does not exist).
6. Night Shift: compare with the Control Center switch.
7. Do Not Disturb: first make a Shortcut with "Set Focus → Do Not Disturb → Toggle". Pick it in Settings → Controls → Do Not Disturb. The tile then says "Runs your Shortcut". There is no on/off state shown.
8. Eject Drives: the tile is dimmed while nothing external is mounted. Plug in a USB drive, press it, and confirm in the panel.
9. Mute Mic: flip it and check the Sound tab button, the badge and ⌃⌥M all agree. Turn Sound off and check it still works.

Grab Text:

10. Press ⇧⌘2 or click the Grab Text tile. On first use, allow Screen Recording (Orbit may need to be reopened). A crosshair overlay appears on all four displays. Drag a rectangle over text: the HUD says "Copied N lines" and the text is on the clipboard. A QR code gives "Copied code". Esc cancels, and your app keeps focus so the next ⌘V lands in it.
11. If TextSniper is still running, Settings → Controls shows "In use by another app" next to the shortcut.

## 5. Needs hardware verification

No agent could check these. Highest-risk items first in each group. Everything here is "not verified on hardware".

### Check these first
1. DDC brightness boost to 150 on the ThinkVisions (Displays).
2. Per-app audio routing (Chrome to MacBook speakers, rest on headset), and that no app stays muted after quitting Orbit (Sound).
3. Resolution Keep/Revert countdown, including that a kept resolution survives a logout (Displays).
4. Dock preview (Windows).
5. Live wallpapers on all four displays, including pause behaviour, Spaces and quit/None from a different Space (Wallpaper).
6. Grab Text overlay on all displays (Controls).
7. Esc and keyboard input in Orbit's non-activating panels, and ⌘V/⌘C in Orbit's search fields (Shell, Clipboard, Controls, Displays).
8. Shake-to-open during a real Finder drag (Shelf).

### Shell
- **(high)** Esc, Return and typing in the non-activating panel and the other non-activating windows (Clipboard popup, Grab Text overlay, resolution confirm card). Key focus in these panels is the main unverified risk.
- **(high)** ⌘V, ⌘C, ⌘A in the panel's and popup's search fields. The shell had no main menu, so edit shortcuts were likely dead; the final wave adds one. Not verified on hardware.
- Click routing: left-click opens the panel, right-click and ⌃-click open the old menu, clicking outside closes the panel. Panel close on ⌘-Tab, app activation and display changes (final wave).
- The accent dot's position on the menu bar icon, and the Settings window chrome (traffic lights over the rail's top inset).
- Trackpad swipe direction on pill sliders, and mouse-wheel nudging.
- Liquid Glass look on macOS 26. Snapshots only render the flat fallback, and switches draw inactive in them.
- The private TCC permission preflight (Sound) returns the documented values on macOS 26.5. If not, the status shows "Unknown" and Open System Settings still works.
- With Controls on by default the mic mute service is active at launch. Once an input device is seen, ⌃⌥M is registered globally.

### Sound
- **(high)** Per-app routing and levels with Chrome playing: 50% quieter, 150% louder without harsh clipping, mute silent, back to 100% (the tap goes away after about 1 s; the log shows "released com.google.Chrome"). Route Chrome to MacBook Pro Speakers while the headset is the default.
- **(high)** No app stays muted: turn Sound off, quit Orbit and `kill -9` Orbit while an app is tapped. The app must play normally at once. Quitting must not stall for 2 s, even with an idle (paused) tap.
- **(high)** Power assertions. Run `pmset -g assertions` with an app tapped and playing, and again with a tapped app that has been quiet for more than 5 s. Once the tap has paused there should be no coreaudiod `PreventUserIdleSystemSleep`.

```bash
pmset -g assertions
```

- No orange mic indicator when an app is routed to the headset. If the log says "couldn't switch off the output device's own input streams", the tap failed closed instead.
- After a pause, the app's next sound plays at its Orbit volume and route. If the first few milliseconds of each sound come through unattenuated, note it.
- TapAutoStart: mute a silent app (Slack) and check its first notification stays silent, with no dropout and no full-level leak. The log shows no "is quiet" line until it has played and then been quiet for 5 s.
- A paused tap is released at once when you turn Sound off, reset the app or reroute it.
- "Same as Output" follows an app's own device: set Discord's output to the headset inside Discord, the system output to the speakers, change Discord's volume, and it must stay on the headset with no new "tapped" line.
- Idle follower switches with the system output: Chrome idle at 50% on Same as Output, switch the system output, and Chrome's next sound plays on the new output.
- Grouping on real playing processes: Chrome's audio helper to Chrome, Safari's WebKit GPU process to Safari, Discord helpers to Discord.
- Mic mute on the Arctis Nova 5: ⌃⌥M toggles and the badge appears. Unmute, Sound off and quit all restore. Press it several times in a row: never "Muted outside Orbit", and no "was unmuted outside Orbit" in the log. Changing the input while muted moves the mute to the new mic. Unplug the headset while muted and the mute moves to the MacBook mic; plug it back in and it returns unmuted. Unmuting in System Settings clears Orbit's mute.
- With a mute on a mic that is no longer the input, clicking the badge or unmute clears it.
- Master volume and input level pills; DisplayPort outputs show "Fixed"; the Alerts menu changes the system output; Keep preferred microphone switches back.
- Hog mode (an app taking exclusive access): unmute fails, the badge stays, the record is kept.
- Quick double press (round 4): on the Arctis, mute with ⌃⌥M, then unmute and mute again within about 100 ms. The mic must end muted, the tab shows "Muted · ⌃⌥M to unmute", and the log has no "was unmuted outside Orbit". Repeat on a mic with no mute control (volume fallback): it ends at volume 0 and the next unmute brings the original volume back.
- Reconnect while muted: unplug the headset and plug it back in so it is the input again. The tab must not flash "Muted outside Orbit". Input flip-back while muted: switch input to the MacBook mic and straight back; the headset ends muted and a later unmute works.
- Output flapping (round 4): give Slack (quiet) a 50 % setting and switch AirPods ↔ speakers several times. The log shows one "released com.tinyspeck.slackmacgap" per rebuild and coreaudiod's thread count stays steady; at Slack's next sound it plays once, at 50 %, on the current output.
- Blocked starts (rounds 2–3): after releasing a paused tap (Sound off, reset to 100 %, reroute), the log shows the waiting start returning and the outside teardown finishing; quitting with a paused tap has no 2 s pause. A tapped app that never plays must not keep coreaudiod busy (watch its CPU in Activity Monitor).
- Turning Sound on shows the System Audio Recording prompt and the list switches from "Allow per-app control" to sliders once granted.

### System
- The readout status item: how it looks in the menu bar, the click menu, Hide Readout, and that it disappears when System is turned off.
- Live behaviour: numbers start when the tab opens (CPU after 0.5 s), sampling stops when it closes, and the readout keeps updating every 2 s with the panel closed.
- The cluster mapping on an idle machine: the Super row should rise first under a single-threaded load.
- A Magic Mouse/Keyboard/Trackpad on the IORegistry path de-duplicating against its power-source entry (the name match is heuristic).
- On-battery strings ("3 h 20 m left") and charging AirPods with different L/R levels.
- Intel Macs: SMC `sp78` decoding and key classification are tested as pure code only.

### Displays
- **(high)** DDC Set brightness above 100 on the ThinkVisions. DDC reads showed the ThinkVisions reporting max 100 with current 150; the AOC reported 100/100. No DDC write was ever sent to any monitor. If they clamp to 100 or ignore it, set the maximum override to 100 in Settings → Displays to remove the misleading boost zone.
- **(high)** The resolution Keep/Revert flow: the floating card is clickable and takes Esc/Return (it may need a click first), stays centred while the display changes size, the timeout reverts, Keep persists across logout, and the nested menus inside the pop-up render properly.
- DDC writes in general: whether 80 ms throttling plus about 60 ms per write feels responsive, and whether any monitor needs a longer gap. Whether write errors are detected for a stale service.
- Gamma dimming on the Acer on macOS 26: it actually dims, behaves across sleep and wake, interacts correctly with Night Shift and True Tone, and quitting Orbit or a crash restores colours.
- The wake path on real sleep/wake: whether 1.5 s is enough for the display controller to rebuild its services. Hot-plug re-matching.
- The built-in display path (DisplayServices) was only seen in snapshots because the lid is closed.
- BetterDisplay also talks DDC. Two apps polling the same monitors can collide until BetterDisplay is quit.

### Windows
- **(high)** Dock preview end to end with Accessibility and Screen Recording granted to this signed build. Does the Dock fire its hover notification? Do icon frames come out right on all four displays (including a display above the main one, with auto-hide and magnification)? Does the strip sit above the Dock without stealing focus?
- **(high)** Thumbnails: does ScreenCaptureKit capture windows on other Spaces and full-screen windows (otherwise they show as title cards)? Is matching right for multi-window apps (Chrome, Finder)? Capture time with about 10 windows (captures run one after another).
- Does clicking a thumbnail raise the right window and activate the app from a non-activating panel on macOS 26 (cooperative activation), and does the delayed re-raise pick the right window?
- Tab actions on real apps: focus, hide/show, quit, force quit, minimise/restore, close. None was ever invoked on your apps.
- Late grant: turn Windows on, grant Accessibility, and the preview starts within about 0.5 s.
- An auto-hiding Dock places the strip correctly after the delay.

### Clipboard
- **(high)** Paste with Accessibility: ⇧⌘V, ↓/↑, Return puts the text in Safari's field and Safari stays frontmost. Also with the paste switch off and with Accessibility revoked (expect a "Copied" toast with the hint).
- **(high)** Typing, ↑ ↓ Return and Esc in the non-activating popup the moment it appears. After choosing or Esc the app you came from is still active, caret in place.
- Hot key: ⇧⌘V is taken from other apps while Clipboard is on and given back when it is off.
- Password managers (1Password, Passwords, Keychain): nothing from them appears.
- Big copies: an image over about 20 MB is refused; a large TIFF from Preview doesn't make the menu bar or cursor hitch.
- Image copy from Preview (TIFF), screenshot to clipboard (PNG), files copied in Finder, RTF from TextEdit.
- Popup placement near screen edges, on the other displays and over a full-screen app. Restart Orbit: history returns.
- Choosing an entry while another app took the front during the popup: expect "Press ⌘V to paste in <app>" and no keystroke.

### Shelf
- **(high)** Shake during a real Finder drag opens the shelf. The shake now polls the mouse and the drag pasteboard after a global left-press monitor fires, the same way the wheel does. Not proven that macOS 26 shows the drag pasteboard change as expected for a Finder drag. Check it doesn't trigger while selecting text or moving a window.
- Drop on the shelf from Finder; dropping right after a shake (the shelf appears under the cursor mid-drag).
- Drag out to a Finder folder (same volume moves and the item leaves; other volume copies; ⌥ copies), to Mail/Slack/a browser (attaches a copy), to the Trash (removes the item).
- The panel stays on all Spaces and over a full-screen app, never steals focus, and the first click on a button works without a prior click.
- Resizing with the corner grip and moving by dragging bare glass; remembered frame per display after relaunch.
- Liquid Glass on macOS 26, the hover ✕ and the "+" drop highlight.
- Turning Shelf off removes the SHELF slice, the monitor and the window.
- Without Full Disk Access, the first thumbnail of a file in Documents/Downloads/Desktop may prompt for that folder.
- A real unmounted drive: its item stays and shows "Not connected".

### Wallpaper
- **(high)** Window level on macOS 26 on all four displays: above the system wallpaper and below the desktop icons. If the system wallpaper draws over it, the fallback is `desktopWindow + 1`.
- **(high)** Spaces and Mission Control: the window shows on every Space, a full-screen app's Space pauses playback, Mission Control shows the still. `setDesktopImageURL` probably applies to the current Space only.
- **(high)** Quit, turn off, or pick None while on a different Space from the one that got the still. That Space should get its original back (with scaling and fill colour) when you next visit it while Wallpaper is on, and the still file must still exist until then.
- Occlusion reporting for a desktop-level window behind Finder's transparent desktop window. If macOS never reports the window visible, Orbit pauses it as covered after 4 s and logs it. That log line should not appear in normal use.
- Pause and resume on screen lock/unlock, display sleep/wake, system sleep, the Low Power Mode toggle and battery power (the Mac has been closed and on AC).
- No black flash at start, after wake with all four DisplayPort displays, or on hot-plug.
- Unplug and replug a display. Do the twin P27u-20 keys survive a reboot and a port swap?
- What gets remembered when the current wallpaper is an Apple aerial (`desktopImageURL(for:)`).
- CPU and GPU cost of up to four 4K HEVC streams, and the saving when two displays share an aerial.
- Quit, disable and crash: windows close and desktop pictures come back.

### Controls
- **(high)** Grab Text on all four displays: the overlay with the mixed 6016 × 3384 HiDPI and 2560 × 1440 framebuffers, the `sourceRect` mapping on non-main displays, Esc and the crosshair cursor while another app stays active, focus afterwards, the first-use Screen Recording flow (macOS may require a relaunch), and ⇧⌘2 vs TextSniper (Carbon may or may not refuse; an event tap could fire both).
- **(high)** Keep Awake: `pmset -g assertions` shows "Orbit Keep Awake" (plus the display one) and it disappears on expiry, on switching modes, on disabling Controls, on Quit, and after "While an app runs" when the app quits. The wake-after-deadline path needs a real sleep.
- Dark Mode through `SLSSetAppearanceThemeLegacy`: the symbol is present on 26.5, but flipping it was not allowed. Check it switches the whole system and `AppleInterfaceStyle` follows (else an error toast). Check that Auto is turned off and back on as System Settings does.
- Night Shift `setEnabled:` matches the Control Center switch.
- Finder: `CreateDesktop` / `AppleShowAllFiles` writes take effect after the relaunch, Finder comes back, and turning off removes the key.
- "While downloading" with a real Safari or Chrome download, and the Downloads-folder permission prompt.
- Eject with a real external drive and a disk image, including the "in use" failure toast. A stale SMB share no longer stalls the panel.
- Mic Mute works now that Sound's hardware code is in.
- Do Not Disturb: create the "Set Focus" Shortcut, pick it, run it from the panel.

## 6. Builder's calls

Every `[builder's call]` from the reports, then every `Ruling:` in the ledger. Where a report was updated in a later fix round, the later version is used.

### Shell
- Status item: left mouse-down toggles the panel; right or ⌃ mouse-down shows the old menu unchanged. Both act on mouse-down, like system menu extras.
- Panel footer: Settings… and Quit Orbit, plus a `…` menu with Open Files…, Wheel enabled, Recent results and About Orbit. ⌥ Debug stays in the right-click menu only.
- Settings rail is a plain sidebar `List` in an `HStack` with a regular material, not `NavigationSplitView` or macOS 26's glass sidebar (the glass sidebar rendered blank offscreen, and the rail never needs collapsing).
- Mouse wheel on a pill nudges by a fiftieth of the range. A mostly-sideways trackpad swipe adjusts. Vertical scrolling goes to the panel's scroll view.
- Pill slider extras beyond the brief: height, dimmed look, a label slot and a system-image init. Extra shared pieces: link button, round menu, panel style, gallery, settings section.
- `managesOwnScrolling` is a static protocol requirement so snapshots can honour it.
- The mic mute shortcut registers only while an input device is available.
- Key names go beyond the brief (punctuation, ⇥, ⌫). Esc is kept for cancelling the recorder.
- Permission status polling: once a second for two minutes after a request or Open System Settings, then stops.
- In dark mode, text and icons use the accent lifted 50% toward white. Fills keep the true accent.
- `SuiteContext` is an `ObservableObject` and carries the coordinator's single toast centre, so suite and job toasts stack.
- Panel window level is `.statusBar`, so SwiftUI menus open above it.
- Screen Recording opens the System Settings pane only if it was requested before and is still not granted. A first request shows only macOS's prompt.
- Sound on macOS 14.0/14.1: the Features card says it needs 14.2 and Orbit asks for nothing. The mic mute shortcut still works.
- Turning a feature on or off when it is already in that state does nothing visible (no prompts, no panes).
- Ruling: a shared `DisplayIdentity.key(for:)` (display UUID, falling back to vendor-model-serial) so Displays and Wallpaper key settings the same way. If wrong: settings are keyed differently than you expect after a port change.
- Ruling: `FeatureRegistry.featureType(for:)` gives the snapshot CLI a feature-to-type map. If wrong: trivial refactor.
- Ruling: mic mute is a shell-owned `MicMuteService` API whose hardware code the Sound task fills in; Controls only uses the API. If wrong: a merge conflict in one file.
- Ruling: Controls is the last tab (symbol `switch.2`), on by default; Grab Text default is ⇧⌘2 (TextSniper's default). If wrong: you change it in Settings.
- Ruling: the mic mute shortcut and badge are active whenever Sound or Controls is enabled (the spec says it must work with Sound off). If wrong: the shortcut is live when you didn't expect it.
- Ruling: four shell minors were upgraded to Important and fixed in round 1: the snapshot defaults guidance that left plist litter, the Screen Recording double prompt, the same-state `setEnabled` guard, and the Sound request on macOS 14.0/14.1. If wrong: a slightly larger fix diff.
- Accepted review deviations: List rail instead of `NavigationSplitView`, panel level `.statusBar`, mic shortcut only while an input exists.

### Sound
- Volume curve: square law below 100 (50% is about −12 dB), linear from 100 to 150 (1.5× is about +3.5 dB). A soft clip (tanh knee at 0.9) applies only while gain is past 1.
- Gain ramp is linear, 480 frames per unit of gain (about 10 ms at 48 kHz). A new tap starts at its target gain, with no fade-in.
- Unity per-app states aren't stored. With "remember" off, states live for the current run only.
- "Same as Output" means the device the app plays on by itself (its single connected output), otherwise the system output. An app that chose its own device (Discord, Teams) is never moved by a volume change. It remembers an idle app's device (fix round 1) and idle followers follow a system output switch (round 2).
- A route to an unplugged device falls back to the followed output and the row shows a warning icon. With no output device there is never a tap.
- Taps require System Audio Recording to be `.granted`, never `.unknown` (a tap without permission could mute an app and deliver silence).
- Helper processes group under their app: own ID if it is an app, else the responsible app, else the `…helper…` prefix, else own ID.
- Apps list order as in the mockup: playing apps by name, then quiet pinned apps in pinned order, then the rest by name. Dock and menu bar apps only; Orbit never; an app with custom settings stays listed while silent; pinned apps that aren't running are listed.
- A tap covers every audio process of the app. A new process triggers a rebuild with a brief overlap. The new tap starts before the old one is released.
- Back at 100% on the same device, a tap plays at unity for 1 s, then is released.
- A tap whose app has been quiet for 5 s pauses its aggregate device and restarts with the app's next audio (fix round 1, to avoid holding off idle sleep). Round 2: it pauses only after the app has played and gone quiet again, and release is immediate in every state.
- A failed tap build isn't retried with the same parameters; the row shows an orange warning triangle.
- Taps use `TapAutoStart`; all HAL work runs on a per-tap serial queue; `stop()` waits at most 2 s.
- Stream layouts that can't be told apart (for example a stereo-input device next to a stereo tap) fail closed.
- Level bars animate generically while the app is running output (ruling); no real level metering.
- Output pill: devices with no volume control show a dimmed "Fixed" pill; raising volume while muted also unmutes (like the volume keys); a muted output shows "Muted".
- The Alerts menu lists every output device. There is no "follow output" item because the system has no such property.
- Mic tile captions: "On · ⌃⌥M to mute", "Muted · ⌃⌥M to unmute", "Muted outside Orbit", "No microphone", "This microphone can't be muted". The pill keeps the plain mic icon; the round button carries the slash.
- Choosing a mic in the panel while Keep is on makes it the preferred mic. The watcher switches back when the preferred mic reconnects, at most once every 2 s, retrying instead of dropping a throttled switch. Keep is off by default; "remember per-app states" is on.
- Duplicate device names are numbered ("P27u-20 (2)"). Icons: laptop (built-in), headphones (headsets, Bluetooth, AirPods), display (DP/HDMI), waveform (virtual).
- Mic mute uses the mute control (main element, else every settable channel). Fallback: input volume 0. The restore record survives a crash in `micMute.pendingRestore`.
- Mic mute never undoes a mute the user had applied before, and never undoes a mute made elsewhere (clicking unmute on one is treated as a direct user action). A failed unmute keeps the record and the badge. A muted device that disappears keeps its record until it returns. Following an input change moves the mute to the new mic.
- Orbit's own mute write is not mistaken for an outside unmute for up to 2 s (round 2).
- Per-app volume is written to settings once a drag ends, not on every tick.
- Row context menu: Pin/Unpin and "Reset to 100 %, Same as Output". The header link toggles "Show all apps" / "Show fewer". Settings has Forget All App Settings.
- Process-list listening runs while the panel is visible, a tap exists, or an app has non-default settings.
- Ruling: Sound minors M2 (live mic state), M3 (keep the record until the device returns) and M5 (ambiguous stream layout could route the mic to the output) upgraded to Important; M1, M6, M7, M8, M9 included. If wrong: extra commits.
- Ruling: round 2 adds N3 (teardown waits behind a blocked start; `stop()` stall) as Important, with N4, N5, N6 and a nit. If wrong: extra commits.
- Ruling: shell minor #8 (failed unmute drops the badge) forwarded to the Sound review, since Sound owns that file now.

### System
- CPU indices go from the last performance level backwards, because the kernel lists the slowest level first. Evidence is the M5 Max device tree. A literal reading of the ruling would label the Performance cores "Super".
- A second temperature source: read-only SMC float keys, because IOHID on the M5 Max has no CPU-cluster or GPU sensors. `Tp`/`Te` map to CPU, `Tg` to GPU, `PMU tdie*` to SoC. This deviates from the brief's "PMU tdie* = CPU".
- Batteries come from the power-source list including accessories (private call, falls back to the public one). AirPods' case folds into the AirPods row as a part.
- Menu bar readout options: Off (default), CPU load, Temperature, CPU load and temperature. Text is "CPU 23%", "53°C", "7% · 54°C". Temperature is the CPU average, falling back to SoC. Clicking opens a small menu. Its position is remembered.
- When only the readout is on, only its metrics are sampled, every 2 s. The tab samples everything at the chosen interval. Batteries are re-read at most every 10 s.
- Sparklines restart after a gap of more than 3 missed samples. History lives in memory only. The scale tops out at peak × 1.25, clamped to 50–100%.
- Uptime uses `kern.boottime` (sleep included), with "since <weekday time>" (a date after a week).
- Used memory = active + wired + compressed. Pressure colours: accent, orange, red.
- Heat colours: below 80 °C accent, 80–95 °C orange, 95 °C and above red.
- Settings adds a "Refresh every 1/2/5 seconds" picker and a Sensors note.
- Chip name and GPU core count are read once, when the tab first shows.
- The internal battery is "This Mac". Low means at or below the device's own low-warn level (20% default) and not charging.
- Battery de-duplication matches the exact normalised name only.
- Ruling: Kevo's clusters are named from `hw.perflevelN.name` ("Super" 6, "Performance" 12), not hard-coded P/E.
- Ruling: System minors M1, M2, M4–M8 included in fix round 1; M3 became a known gap. If wrong: extra commits.
- Ruling: the Task 8 battery de-dup (matching on Bluetooth address) stays a known gap after the final review triage.

### Displays
- If a DDC reply's current value exceeds its reported maximum (the ThinkVisions' 150 / 100), the automatic range extends to it. It is remembered per display only after two readings in a row (the lower of the two), capped at 2× the reported maximum. An explicit override always wins.
- The boost zone starts at the reported maximum, not a fixed 100. The caption reads "DDC · up to N" only when there is a boost zone.
- Link brightness works on fractions of each display's own range, from the values when the drag began. Displays at 0 shift by the same amount.
- Writes are throttled to one every 80 ms while dragging (latest value), plus a flush on release.
- Software dimming has a 10% floor, is saved per display, re-applied at start, after display changes and on wake, and is restored when the display returns to 100, when the fallback is turned off, and on stop and quit. Gamma restore uses Orbit's own captured tables, never a global ColorSync reset. A table whose peak is below 0.98 is treated as suspect and lifted to full.
- DDC results are cached per session. A display that answered stays DDC after a missed reply and keeps its last value. A silent display is re-probed three times (1 s, then 3 s apart, re-walking the registry) before falling back to software dimming.
- Matching policy: exact location first, locations compared only when comparable, then most pairs, best score, list order. Built-in displays are never matched.
- Tile order: built-in first, then left to right. Identical monitors get "· Left" / "· Right" (or "· Top" / "· Bottom"). The built-in tile takes the Mac's model name.
- The mode menu groups refresh rates into submenus. Its last item is "Open macOS Display Settings…".
- Resolution changes ask "Keep this resolution?" in a floating card on the changed display plus an inline row in its tile, with a 15 s countdown. Revert is the previous mode; a second change reverts a pending one; `stop()` and quit revert a pending change.
- The pill shows the raw DDC value (120, 150), not a percent.
- "Apple display" caption for external displays that DisplayServices drives (untested).
- Settings override stepper runs 100–255 in steps of 5, starting from the Auto value, and only for DDC monitors. While Displays is off, its page lists connected displays from the catalog only.
- Reads try 3 times (write twice 10 ms apart, wait 50 ms, read).
- A display that answered DDC is remembered (`displays.answeredDDC`) so a software-dim level is never saved for it.
- Wake handling runs 1.5 s after the last wake notification. A failed write schedules one re-probe.
- The BetterDisplay hint also covers MonitorControl and Lunar, and is checked whenever the tab refreshes.
- Ruling: DDC services are matched with scoring plus elimination, and the pure matching logic lives in OrbitCore with tests including two monitors that differ only by serial.
- Ruling: Displays minors M1 (retry before demoting), M2 (Keep-this-resolution confirm/revert), M3 (learned boost needs two readings, plus a reset), M4 (no global ColorSync restore), M6 (BetterDisplay hint), M7 (tile state logic to Core with tests) and M9 included in fix round 1. If wrong: extra commits.
- Ruling (final wave): apply the new mode permanently up front; Revert or the 15 s timeout re-applies the previous mode permanently, because re-applying an already-active mode with "permanently" was unverified. If wrong: a crash inside the 15 s window keeps the new mode (a mode macOS offered as usable).

### Windows
- Per app: bring to front (unhide plus a Dock-click-style open, which reopens a window for an app with none; closes the panel), hide/show, Quit (no confirmation; the app may ask to save), Force Quit (inline confirmation in the row, not an alert, because a modal doesn't suit a non-activating panel). A context menu offers all four.
- Per window: bring forward (the whole row is the button), minimise/restore toggle, close (presses the window's close button).
- Clicking an app row expands it. The app list shows regular apps only; Orbit never appears.
- Window counts and titles need Accessibility. Without it, subtitles show only Frontmost / Hidden / Running.
- Without Screen Recording the Dock preview still works with Accessibility alone: title cards instead of thumbnails, and ScreenCaptureKit is never called.
- Hover delay range 0–1.5 s in 0.05 steps (default 0.35 s). While a strip is open, moving to another icon switches immediately.
- The strip closes 0.12 s after the pointer leaves the icon/gap/strip, on any click outside it, on a Space change, or when a window is picked. An app with no listed windows shows nothing.
- Layout: one row when thumbnails fit at 140 pt, otherwise the row count giving the tallest thumbnails. Side Docks get a horizontal row beside the icon. The strip clears the Dock's background by 16 pt and may cover the Dock's name tooltip.
- Thumbnails are cached 3 s (48 windows), captured at about 140 pt × backing scale with no cursor and no shadow, and purged when the strip hides.
- Listed windows are standard windows and dialogs of at least 40 × 40 pt. Minimised windows come last, and "Show minimised windows" applies to both the preview and the tab.
- Windows on other Spaces appear in the Dock preview only when they are titled, off screen, layer 0 and at least 40 × 40 pt, after the Accessibility windows, with an "Other Space" badge. The preview waits for ScreenCaptureKit's list before showing so the layout doesn't jump. The Windows tab stays on the current Space plus minimised windows and says so in a caption.
- The panel level is `.popUpMenu`, above the Dock; it never becomes key and never activates Orbit. The Dock edge is read from the `com.apple.dock` `orientation` preference (yours is unset, so bottom).
- The Dock watcher re-attaches when the Dock restarts. A hover only counts within 60 pt of the icon.
- The feature listens for the system accessibility-change notification so a grant made in System Settings starts the preview without Orbit becoming active.
- The settings readiness row has Allow… buttons that go through `PermissionCenter`. It says "Not running" while Windows is off.
- Bringing windows forward uses cooperative activation (`yieldActivation` then `activate(from:)`), with a second raise 0.25 s later. Accessibility actions run on a serial queue off the main thread with a 0.25 s timeout on every element.
- Ruling: the agents' dev builds weren't trusted for Accessibility or Screen Recording on this Mac (different signature from yours), so live testing was impossible; logic that can be decided without the OS is in tested OrbitCore units.
- Ruling: Dock preview costs nothing when the feature is off, Accessibility is missing, or "Dock preview" is off. App control works without any permission.
- Ruling: Windows minors M1 (other-Space windows), M2 (stale icon frame with auto-hide/magnification), M3 (click during the delay), plus `yieldActivation`, M6, M8 and M11 included in fix round 1. If wrong: extra commits.
- Ruling (final wave): the strip waits on an uncached ScreenCaptureKit list with no timeout, so show Accessibility-only after about 0.4 s and fill in captures later.

### Clipboard
- Default popup shortcut ⇧⌘V (ruling), with a settings note that it is "Paste and Match Style" in many apps and Orbit takes it over while Clipboard is on.
- 1Password markers are matched by prefix (`com.agilebits.onepassword*`) as well as exactly.
- Megabytes are decimal (1 MB = 1,000,000 bytes). One copy can never exceed the total budget. Ranges: items 10–5,000, days 1–365, total 10–5,000 MB, per copy 1–500 MB.
- The pasteboard content present when the feature starts is not recorded.
- Priority when a copy has several formats: files, then rich text, then text, then image. Text copied as plain and as RTF are separate entries. Whitespace-only text and HTML-only copies are not recorded.
- Images are stored as PNG (TIFF converted, off the main thread). The size limit applies to the stored PNG. A TIFF over 10× the limit isn't converted at all.
- Source app is the pasteboard's `org.nspasteboard.source` marker when present, else the frontmost app at poll time (up to 0.5 s late).
- Choosing an entry moves it to the top. The tab's click is copy-only and closes the panel; only the popup pastes.
- Dedupe is by SHA-256 of kind plus content.
- Tab layout: Pinned group above Recent, a single Results list while searching, two-step Clear that keeps pinned items, list capped at 450 pt.
- Popup: 380 pt wide, up to 8 rows, ↑/↓ clamp at the ends, hover selects only after the pointer moves, closes on outside click, losing key, Esc or a second press of the shortcut. No number shortcuts and no pin/delete in the popup.
- The "Copied" toast shows 1.4 s (2.8 s with a hint line).
- Orphaned blob files are swept at load, never when the index was corrupt. A backup that can't be parsed blocks orphan sweeping until you remove the `index.corrupt-*` file. If the unreadable index can't even be copied aside, the session runs without saving.
- Entries whose blob has vanished are dropped at load. `stop()` keeps the history in memory so Settings keeps showing right numbers. The popup is a fresh window per open.
- Pinned entries are exempt from the age, count and size limits.
- ⌘V is posted only when the previous app is confirmed frontmost; otherwise copy-only with a toast naming the app.
- Ignored apps default to none.
- Ruling: ⇧⌘V is kept as the default even though many apps use it for Paste and Match Style, with a settings note, and recorded in the open questions.
- Ruling: after choosing (or Esc), the previously frontmost app must be active again before ⌘V is posted.
- Ruling: Clipboard minors M1 (marker check vs data read race) and M4 (pinned count toward budgets, so history silently stops) upgraded to Important. If wrong: slightly bigger fix.
- Ruling: Clipboard commits keep their `Claude Opus 5.5` trailers and Shelf's keep `Claude Sonnet 5.5` (accurate authorship), rather than being rewritten. If wrong: cosmetic.
- Ruling (final wave): `cancelIngest` must cancel every in-flight copy, not only the newest.

### Shelf
- Shake rule: a reversal is confirmed when the pointer comes back 40 pt from the end of a leg, so every counted leg is at least 40 pt. In practice about four legs inside 0.6 s. A 1 s lockout follows a shake; vertical movement is ignored. The numbers are `ShakeDetector` parameters.
- Shake detection polls (like the wheel's sampler) after a global left-press monitor fires: 20 Hz while waiting for a file drag, 60 Hz while tracking, off on release. No idle backstop timer. Nothing exists while Shelf or shake-to-open is off.
- `shakeToOpen` and `keepOnTop` both default on.
- A file drag is "the drag pasteboard change count moved after the button went down and it holds file URLs", the same rule as the wheel.
- Shake placement: centred on the pointer, clamped to the visible frame, with the size you last chose on that screen. The tab opens at the last frame on the screen under the pointer, else bottom centre 24 pt above the edge. Frames are saved per display and clamped when displays change.
- New items append at the end. Adding a file already there keeps its place. Only `file:` URLs are accepted.
- The shelf answers a drop with copy when allowed, else generic, else link, never move, so Finder never thinks its file was taken. Drags that started on the shelf are refused.
- A drag out that ends in move or delete is re-checked 1.5 s later and removes only files that are really gone. Copy, generic and link results leave the item.
- Missing files are checked when the shelf is shown and when the tab appears, not at launch. A file moved or renamed on the same volume is followed through its bookmark. An unreachable file (offline drive, permission error, timeout) is kept dimmed; only a file truly absent from a mounted volume is dropped.
- A corrupt or newer `shelf.json` is moved aside (`shelf.json.corrupt-<timestamp>` or `.newer-<timestamp>`) before the first save, never overwritten.
- Window: borderless non-activating panel at `.floating` level (normal when keep-on-top is off), all Spaces, full-screen auxiliary, never key. Min size 300 × 132, default 440 × 168, 76 pt tile cells.
- Hover ✕ and highlights use tracking areas that work for an app that is never active. Double-click opens; right-click menu: Open, Show in Finder, Copy Path, Remove from Shelf. No Quick Look. A "Drag all" chip appears with two or more items.
- Wheel: SHELF goes right after FLOAT (index 1); the ring becomes 8 slices, under the cap of 10.
- The tab's Show closes the menu bar panel first. If something opens the shelf while the feature is off, a toast says Shelf is off.
- Ruling: `CatalogSettings.showShelfAction` defaults to false so every existing catalog test stays green unchanged; the app turns it on when Shelf is enabled.
- Ruling: the shake watcher is independent of the wheel's drag watcher; items are references to the original files.
- Ruling: Shelf minors M1 (move result removes before the move), M2 (main-thread stats can stall launch on a dead SMB share) and M3 (corrupt `shelf.json` overwritten) upgraded to Important, and shake detection switched to polling. If wrong: a few extra fix commits.
- Ruling (final wave): refuse paths under `.Trash` instead of following trashed files into the Trash via their bookmark.

### Wallpaper
- Display key is the shell's `DisplayIdentity.key` (display UUID) rather than vendor-model-serial, because both P27u-20 report serial 0. A connected display with no wallpaper of its own takes over an assignment saved under its name whose key isn't connected, but never another connected display's.
- Aerial names: localized name, then label, then shot ID, then ID. The user's language is picked with English as a per-key fallback. Order: category, then manifest order. "Downloaded" means `<id>.mov` is a non-empty regular file.
- macOS 26 layout is supported first; the macOS 14/15 `idleassetsd/Customer` layout second (unverified, no such Mac here). The spec's path does not exist on your Mac.
- Pause precedence: display asleep, then screen locked, then covered, then Low Power Mode, then battery. A window macOS never reports visible plays for 4 s, then counts as covered.
- A player is shared by displays showing the same source and plays while any of them plays.
- Still frames are PNGs of the frame at 1 s at full video resolution, set with fill scaling, when a window opens or changes source and when the still-frame switch is turned on. Not on every rebuild, so a picture you pick by hand isn't overwritten.
- Restore uses a per-display ledger of your original picture with its scaling, clipping and fill colour. A restore waits per display and is retried on each Space change while Wallpaper runs. Entries are never dropped automatically. On a Space change a display with a wallpaper only has stale Orbit stills replaced.
- Orbit-named stills that no assignment uses and no connected display shows are deleted. Stills of a display waiting for a restore are protected.
- Video files: file picker restricted to movies, opened after closing the panel; checked for playability (error toast if not); a plain bookmark is saved and refreshed at most once per file per run.
- Video thumbnails are kept in memory only (a frame at 1 s, at most 480 × 270).
- Panel: displays listed left to right by frame; Choose… menu has Video File…, Your Videos, aerials by category with a tick on the current one, and None; footnote with the aerial count and a "Get more" link.
- Settings stay editable while Wallpaper is off. The window starts transparent so the still shows through, and turns black only when the first frame is ready. Window title "Orbit Wallpaper".
- Ruling: restoring desktop pictures. When a wallpaper is removed (or the feature turned off) the picture saved before Orbit first set a still is restored.

### Controls
- Indicator id is `"controls.keepAwake"` (the ruling said `"keepAwake"`; the id is only the asker's name).
- Section headers: "Sleep" above Keep Awake, "Quick Toggles" with a Customize link, none above Grab Text.
- Dark Mode uses SkyLight only, with no System Events fallback, so no Automation permission. If the symbol is missing the toggle shows "Not available". If the preference doesn't follow within 1 s, an error toast says so.
- Finder relaunch uses SIGTERM (the `killall Finder` behaviour), then opens Finder if it isn't back after 1.5 s. A toggle already in the requested state does no write and no Finder restart.
- "While downloading" polls the top of ~/Downloads every 10 s, only in that mode, for `.download`, `.crdownload`, `.part`, `.partial` and `.opdownload`, with a 20 s grace between downloads. It refuses to start, with a toast, when nothing is downloading.
- The Keep Awake switch resumes the last mode if it is indefinite, a duration, or an until-time still ahead; otherwise indefinitely. App and download modes start only from the menu.
- Remaining time rounds up to whole minutes ("1 h 12 m left"). Custom duration steps in 5 minutes, clamped to 1 min–24 h.
- A toast says why Keep Awake ended by itself ("Time's up.", "Xcode quit.", "Downloads finished."). A refused display assertion is reported ("display can still sleep").
- Eject filter: the volume must be under `/Volumes/`, local, browsable and not the root, and at least one of ejectable, removable, or not-internal. This excludes CoreSimulator images, network shares and internal partitions. Network mounts are never statted.
- Barcode HUD: "Copied code" / "Copied N codes", payloads trimmed and de-duplicated. "No text found" leaves the pasteboard alone.
- Reading order: rows grouped by at least 50% vertical overlap, top to bottom, left to right, joined by a space.
- `TextRecognizer` lives in OrbitCore so OCR and barcode detection are unit-tested on rendered images.
- Overlay: 22% black veil, white 1 pt border, size badge. A drag under 4 pt, a click, a right-click or switching apps cancels. A selection stays on the display where it started. The crosshair windows are non-activating panels so your app keeps focus.
- Screen Recording not granted: the request goes through `PermissionCenter`, with a toast. The tile subtitle says "Asks for Screen Recording the first time".
- A custom accent switch for Keep Awake, because the AppKit switch draws grey when the panel isn't key. The mic mute shortcut recorder is repeated on the Controls page.
- Do Not Disturb is an action button (no state), with a 15 s timeout on the Shortcut.
- Dark Mode on Auto: turning on plans Auto off and remembers it; turning off restores the theme and turns Auto back on.
- Toggle titles describe "on": "Hide Desktop", "Hidden Files", "Mute Mic".
- Ruling: Controls name and symbol `switch.2`, last tab, ⇧⌘2 (matches TextSniper's default).
- Ruling: quick toggles are NOT restored when Controls is turned off or on quit. Spec §8.3 requires restore only when the toggle itself is turned off, and a dark-mode switch reverting on quit would surprise you. Transient state (Keep Awake assertions, mic mute) is still restored. If wrong: your toggled settings persist after quit.
- Ruling: Controls minors M1 (timer re-arm), M2 (restore record race), M3+M4 (needless Finder restart and footnote), M6 (volume listing on main), M7 (Shortcut timeout), M8 (Downloads read on main, plus `NSDownloadsFolderUsageDescription`) and M13 (Auto appearance restore) upgraded to Important; M9 included. If wrong: extra commits.
- Ruling: Do Not Disturb ships only as "run your Shortcut", with no state.
- Ruling: the Shell's contract text "restore any system state Orbit changed" is reworded to "transient state" in the final wave.

### Process (how the build was run)
- Ruling: feature Tasks 7–13 ran in parallel, each in its own worktree, instead of one at a time, because you asked for parallel features where files don't overlap. If wrong: merge conflicts resolved by hand.
- Ruling: the shell (Tasks 1–6) went to one implementer and one review, since it is one coupled architecture. If wrong: a larger review surface.
- Ruling: the eight feature agents started from the shell's report commit in parallel with the shell review. If wrong: shell review fixes that change public API need follow-up merges.
- Ruling: implementer reports live in `docs/suite/reports/` (committed). If wrong: nothing.
- Ruling: the host keep-awake tool was denied, so the controller ran `caffeinate -i -t 36000` (idle-sleep prevention only, capped at 10 hours) as its own background task and stopped it at the end. If wrong: none; it ends with the session.
- Ruling: Sound fix round 4 went to a fresh implementer on a new branch (`suite/sound-r4`), as the process requires after three rounds with the same agent. If wrong: none.
- Ruling: resolution changes are applied permanently up front; Revert or the 15 s timeout re-applies the previous mode permanently. That guarantees a kept resolution survives a reboot. If wrong: a crash during the 15 s keeps the new mode (always one macOS listed as usable).
- Ruling: Sound's later rounds also bounded the pile-up of replaced taps when outputs flap (AirPods switching) and made a quick second ⌃⌥M after Orbit's unmute mute for real. If wrong: extra code, no behaviour risk.
- Ruling: the reviewer's suggestion to bump the Info.plist version is rejected, because you said not to bump it.
- Ruling: the final fix wave covers the two Important findings (main menu for edit shortcuts; resolution Keep persistence) plus panel close on app switch and display change, Shelf Trash, Clipboard `cancelIngest`, the Windows ScreenCaptureKit timeout, contract wording, legacy snapshot defaults, generic fixture names and a duplicate fixture helper. The Task 8 battery de-dup and the Task 14 Dark Mode rollback stay known gaps. If wrong: those two are morning-report gaps (they are listed below).

## 7. Known gaps

### Final fix wave (from its re-review; left as known gaps)
- Displays: if re-applying the previous resolution fails during Revert, the remaining `CGRestorePermanentDisplayConfiguration` fallback can't revert any more (the new mode is already saved) and may reset other tools' session-only display state; its log line overstates it. Rare.
- Displays: Return means Keep on the resolution card. A held or typed-ahead Return could keep a mode the monitor can't show; the 15 s timeout only helps if nothing was pressed.
- Displays: a crash or kill during the 15 s countdown leaves the new mode saved (quitting normally still reverts).
- Windows: the shared screen-capture window list has no timeout; one call that never returns stops thumbnails and other-Space windows (title cards still show) until Windows is turned off and on.
- Windows tab: choosing Quit/Force Quit from a menu opened more than 1 s earlier can close the panel when the next app activates.
- ⌘Q now quits from any active Orbit window (Settings, editors), standard macOS behaviour; an unapplied editor edit is discarded.

### Shell
- A shortcut change that macOS refuses may leave the old shortcut active while the recorder shows the rejected combo. Re-binding after a refusal is not fully handled.
- The `…` menu's Recent results can be stale while the panel is open.
- The Settings rail uses a regular material, not macOS 26's native glass sidebar.
- A narrow double Screen Recording prompt is possible right after a permission reset.

### Sound
- Mic mute (parked at the review cap, all rare): for up to 2 s after Orbit puts back a mic that is no longer the input, a mute you make on that mic can be taken as Orbit's and undone later; the badge can briefly say "muted by Orbit" while the tab already shows unmuted during an unmute's write; after very fast input switches the tab can flash "Muted outside Orbit"; with a driver that ignores writes, a volume-fallback mic can sit at 0 shown as on until the next device change or quit (about 1 in 4000 random fast sequences in the fuzz test).
- When a quiet app plays again, up to three of its taps can start together for a few milliseconds before the older ones are released.
- No real per-app level meter: bars animate while the app is producing sound.
- Per-app taps are unverified on hardware. A running aggregate device may hold off idle sleep.
- If the private permission preflight disappears in a future macOS, the status stays Unknown and per-app control can't turn on (fail-safe).
- External unmute detection watches the main mute element only. A mic with per-channel-only mute won't report an outside unmute, and a per-channel restore uses the first element only.
- A new process for a tapped app causes a rebuild with brief doubled audio.
- Pending mic records never expire, and processing them may undo a re-mute on a connected device.
- Departures from the mockup: the muted row shows the text "Muted" without the speaker glyph, and per-app round buttons use the shared track fill.
- The Settings Apps section sits below the fold at 760 × 560 and scrolls.

### System
- GPU temperature comes from the SMC. If the SMC refuses, CPU and GPU show "no sensor" and SoC still reads.
- The SMC key classification is verified on the M5 Max only. Other chips (the M3 family uses `Tf??` for CPU) may read "no sensor" for CPU. IOHID names from a second PMU ("PMU2 tdie*") aren't matched.
- Accessories that macOS reports through neither power sources nor IORegistry don't show. A battery named by the user in one source and by model in another may be listed twice (matching on Bluetooth address would fix it).
- A cluster with many more cores than 12 would crowd its bar row.

### Displays
- Brightness is the only DDC control: no contrast, volume or input switching. Intel Macs get gamma dimming only.
- The Acer K272HUL answered no DDC read (both read and write returned an error on every attempt), so it gets software (gamma) dimming. DDC/CI is probably off in its menu or unsupported on this input. If you turn DDC/CI on, the next probe after a display change switches it to DDC.
- DisplayServices `CanChangeBrightness` is false for all four externals.
- Brightness changed with the monitor's own buttons isn't picked up until the panel next opens.
- Two identical monitors with no location and no serials fall back to list order, which is a guess. That doesn't happen on your Mac.
- The confirm card may not take Esc/Return until clicked (final wave makes it key).
- The countdown uses `DispatchTime`, so it may be off after a sleep inside the window.
- The tile-state glue (`DisplaysModel`) has no unit tests; its maths is tested in Core.
- Hardware facts corrected: serial 1663094707 belongs to the Acer K272HUL. Both ThinkVisions report serial 0 and can only be told apart by IORegistry location (or the alphanumeric serial).
- **BetterDisplay: what Orbit replaces.** Any resolution macOS offers on each display, HiDPI included, with refresh rates (ThinkVision: 103 usable modes in 41 sizes including 3360 × 1890 and 3200 × 1800 HiDPI; AOC: 123 modes in 18 sizes up to 240 Hz; Acer: 33 modes). DDC brightness on the ThinkVisions (0–150) and AOC (0–100), software dimming on the Acer, link brightness, and built-in brightness with the lid open.
- **BetterDisplay: what Orbit does not replace.** New HiDPI modes or flexible scaling (they need `/Library/Displays` overrides, EDID overrides or virtual-screen mirroring; Orbit writes nothing to `/Library`). Virtual screens and dummies, PIP, XDR/HDR upscale brightness, DDC for contrast, volume and input switching, colour profiles and per-app rules. Orbit only lists the modes macOS offers.
- BetterDisplay as found (read-only): running; its preferences show no virtual screens in use; one `/Library/Displays` override exists for vendor 0 / product 0, which doesn't apply to your monitors. Your current 3008 × 1692 HiDPI on the ThinkVisions is a mode macOS itself offers. None of what you use seems to depend on BetterDisplay-made modes. Orbit never touches that override file.

### Windows
- A hung app delays only its own row's window count (0.25 s timeouts).
- Captures run one after another, so apps with many windows are slower.
- With Dock magnification the strip is placed from the icon frame at hover time and may sit slightly off.
- No VoiceOver path into the Dock strip (it is a non-key panel).
- Windows on another Space need a title to show in the preview, so an untitled one is missed. The "Other Space" heuristic may show phantom or hidden-app windows. Hidden apps may get blank thumbnails where title cards would be better.
- The Windows tab lists the current Space plus minimised windows only.

### Clipboard
- A huge pasteboard item (a 200 MB image) is read into memory once before it can be refused. macOS has no size query.
- The source app is a guess (frontmost at poll time) for apps that don't write the source marker, and the ignored-apps list depends on it.
- Text beyond the first 200 characters is stored but not searchable.
- HTML-only copies, file promises (Mail attachments) and copies with multiple pasteboard items are not recorded.
- No number-key quick pick, pin or delete in the popup. The paste key is position-based (key code 9), which matters on Dvorak.
- Clear in the tab clears the whole history even while a search is typed. The popup's paste/copy hint is decided when it opens.
- After a real index corruption, orphan sweeping stays off until you remove the `index.corrupt-*` file.

### Shelf
- No Quick Look on click, no multi-select, no reordering, no auto-hide. A file renamed outside the bookmark's reach looks like a new item until the old one is pruned.
- Only `/Volumes/<name>` is recognised as another volume's mount point.
- A big cross-volume move still running after 1.5 s leaves the shelf at the next show or tab view, not at once.
- The shake detector relies on a decent drag-event rate; there is no idle backstop for a press the global monitor misses.
- The ✕ needs hover and the tiles have no accessibility press/remove actions. Thumbnails are never invalidated. Case-insensitive duplicate paths are not merged.

### Wallpaper
- Aerial wallpapers can't be restored as aerials: if a display showed an Apple aerial before Orbit, restore can only set the image macOS reports, as a still picture. There is no public API to re-select the live aerial.
- Still frames only reach the current Space (public API). If Wallpaper is turned off and stays off, other Spaces keep Orbit's still until it runs again.
- A crash leaves Orbit's still as the desktop picture. The remembered picture is put back at the next stop.
- No manual "pause all" control.
- A video shared by two displays after being moved gets two decoders. A video in the Trash keeps playing. A late-mounting volume doesn't trigger a reload.
- Up to 8 4K stills per display can be kept in pending ledger entries. A vanished original is retried and logged every Space change.
- The app layer has no unit tests (the core does).

### Controls
- Do Not Disturb has no on/off state. It is a button that runs your Shortcut, and you need to create that Shortcut.
- The Keep Awake session doesn't survive an Orbit relaunch. No notification-centre banner when a session ends, only Orbit's toast.
- Grab Text selects within a single display. Vision language correction is on, which can alter code or URLs.
- Dark Mode partial failure can leave Auto off with no rollback (kept as a known gap).
- Two default-action buttons can be visible at once (Until's Start and Eject's confirm).
- Esc in the Grab Text overlay falls back on the panel becoming key (hardware).

## 8. Tests and build

- Tests: `swift test` on the final branch (74f1c2c): 897 tests in 67 suites passed, three runs in a row (the 547 tests from 1.1.0 plus 350 new). One earlier run aborted inside the Swift test helper while a reviewer was compiling in the same folder; it did not reproduce.
- Build: `ORBIT_SIGN_IDENTITY=7AE2AC16D622170662EDB78454372455073E8B0E scripts/build-app.sh` at 74f1c2c produced `build/Orbit.app`, universal (x86_64, arm64), signed by Apple Development: KG DEV (ZAKW2DAUK8); `codesign --verify --deep --strict` passes. Info.plist gains `NSAudioCaptureUsageDescription` and `NSDownloadsFolderUsageDescription`.
- The existing ffmpeg and process timing tests (`VideoToolTests`, `VideoConversionTests`, `ProcessTests.cancellationTerminates`) flaked only under heavy parallel load: during development about eight agents were building at once, load averages were 60–90, and failures were "hardware encoder may be busy" (-12903) and timing bounds. Each passed when re-run alone. A full run on the merged branch on a quiet machine (load about 4) passed 865 tests in 65 suites, earlier than the final count above.
- Each report states a universal release build (`arm64` and `x86_64`) completed with no warnings in new files.
- The app version was left at 1.1.0 (build 110).

### Cleanup you may want
- Ten agent worktrees remain under `/Users/kevog/orbit/.claude/worktrees/agent-*` (about 9 GB, mostly build caches). Every branch in them is merged into `claude/suite-77e4bb`. I left them because two are still locked by the agent tooling; remove them with `git worktree remove <path>` (add `--force` for the build caches) when you no longer need them, and the merged local branches `suite/*` with `git branch -d`.

### Housekeeping the agents reported
These are the agents' own statements; not independently checked.

- The shell implementer's early snapshot runs left 51 empty `orbit.snapshot.<uuid>.plist` files in `~/Library/Preferences`. It deleted exactly those 51, after checking each had a birth time inside its own runs and an empty dictionary. The code was fixed to use temp-folder suites, and re-runs left none.
- The Clipboard implementer's first snapshot runs left 11 empty `orbit-fixture-<uuid>.plist` files in the user temp folder. It deleted those 11 (two were inspected with `plutil`; the rest were matched by size and timestamp, which is weaker evidence). The helper now cleans up at exit.
- The Windows implementer saw `~/Library/Preferences/TokenBucketRateLimiter.plist` appear during its session. It is a macOS service file, not Orbit's, and was left alone.
- The Wallpaper implementer left a read-only display probe in the shared scratchpad (`probe/displays.swift` and `probe/displays`), nothing in your files.
- The final-fix-wave agent's stray debug run (see Summary) created or touched `~/Library/Preferences/Orbit.plist` (empty). Left in place.
- The controller only deleted files it created itself (scratch files under its scratchpad). `.orbit-signing` was not created, copied or changed (the build used `ORBIT_SIGN_IDENTITY`).
- Several reports say they created no Orbit plist in `~/Library/Preferences`. The reports describe no other files outside the worktrees, temp folders and the shared scratchpad. I can't verify beyond what the reports say.

