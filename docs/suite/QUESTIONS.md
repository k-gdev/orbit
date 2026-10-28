
# Orbit Suite — open questions

Each item has the question, the default the build uses now, and where to change it. "Settings →" paths are in the running app. File paths are relative to the worktree root.

## Decisions I need from you

### 1. Should ⇧⌘V stay the Clipboard shortcut?
- Default now: ⇧⌘V (the spec's proposal). Many apps use it for Paste and Match Style. While Clipboard is on, Orbit takes it from them. Clipboard is off by default. Settings shows a note next to the shortcut.
- Change it: Settings → Clipboard → shortcut recorder (Reset restores ⇧⌘V). Or leave Clipboard off.

### 2. Should ⇧⌘2 stay the Grab Text shortcut?
- Default now: ⇧⌘2, which is TextSniper's default. If TextSniper is still running, registration may fail and Settings → Controls shows "In use by another app"; if it uses an event tap, both could fire. It can also collide with Xcode shortcuts. Not verified on hardware.
- Change it: Settings → Controls → Shortcuts → Grab Text.

### 3. Which features are on by default?
- Default now: on are System, Displays, Shelf, Wallpaper, Controls. Off are Sound, Windows, Clipboard (they ask for permissions or take over shortcuts). Side effects of the default-on set: Controls registers ⌃⌥M globally once an input device exists, and Shelf installs a global left-press monitor for shake-to-open.
- Change it: Settings → Features for your install. The default set itself is `FeatureID.isOnByDefault` in `Sources/OrbitCore/Suite/FeatureID.swift`.

### 4. Should quick toggles be restored when Controls is turned off or Orbit quits?
- Default now: no. They stay as set. Orbit restores a toggle exactly (the recorded prior value) only when you turn that toggle off. Keep Awake assertions and the mic mute are released and restored on stop and quit. If wrong, your toggled settings persist after quit.
- Change it: code only, in `Sources/OrbitApp/Features/Controls/ControlsFeature.swift` (`stop`). There is no setting.

### 5. Is "run my Shortcut" enough for Do Not Disturb?
- Default now: a button that runs a Shortcut you pick. There is no on/off state, because macOS has no public Focus API and the only state source is an undocumented, TCC-protected file. You have to create a Shortcut with "Set Focus → Do Not Disturb → Toggle" first (you have only "Send Message" today).
- Change it: Settings → Controls → Do Not Disturb. Alternative: remove the tile.

### 6. Panel and menu layout
- Default now: left-click on the icon opens the panel; right-click or ⌃-click opens the old menu. The panel's `…` footer menu holds Open Files…, Wheel enabled, Recent results and About Orbit, so those exist in both places. ⌥ Debug is only in the right-click menu.
- Change it: code, `Sources/OrbitApp/MenuBar/StatusItemController.swift` and `Sources/OrbitApp/MenuBar/PanelView.swift`. Tell me if you want the old menu on left-click instead.

### 7. Settings rail: material or macOS 26 glass?
- Default now: a plain sidebar list with a regular material, not the native glass sidebar of `NavigationSplitView`. The glass sidebar rendered blank offscreen, so it couldn't be checked, and the rail never collapses. Look at it live first.
- Change it: `Sources/OrbitApp/Settings/SettingsRootView.swift`.

### 8. System menu bar readout
- Default now: Off. Options are CPU load, Temperature, or both. Sampling every 2 s only runs when it is on.
- Change it: Settings → System → Menu bar.

### 9. Shake-to-open for the Shelf
- Default now: on whenever Shelf is on (Shelf is on by default). Cost: one global left-press monitor, and a poll only while a mouse button is held. The shake needs about four legs of 40 pt or more inside 0.6 s.
- Change it: Settings → Shelf → Shake to open. Sensitivity is in `Sources/OrbitCore/Shelf/ShakeDetector.swift`.

### 10. Wallpaper restore behaviour
- Default now: Orbit sets a still frame as each display's desktop picture (switch on by default) so Mission Control matches. Your original picture and its scaling options are restored when you pick None, turn stills off, or quit. Apple aerials can only come back as the still picture macOS reports, not as live aerials. Other Spaces get their picture back only when you visit them while Wallpaper is on.
- Change it: Settings → Wallpaper → Desktop picture (the still-frame switch). Do you want stills at all, given those limits?

### 11. Resolution changes apply permanently with a 15 s Keep/Revert
- Default now: the new mode is applied permanently up front. A "Keep this resolution?" card counts down 15 s; Revert or timeout re-applies the previous mode permanently. If wrong: a crash inside the 15 s window keeps the new mode (one macOS offered as usable).
- Change it: code only, `Sources/OrbitCore/Displays/ResolutionConfirmation.swift` and the Displays mode service.

### 11b. Should Return mean Keep or Revert on the resolution card?
- Default now: Return = Keep, Esc = Revert, and the card takes keyboard focus. A held or typed-ahead Return could keep a mode your monitor can't show; with Revert as the default button, only an explicit click would keep it.
- Change it: `Sources/OrbitApp/Features/Displays/ResolutionConfirm.swift` (which button is `.defaultAction`).

## Other defaults that may need your call

### 12. Mic mute shortcut is live by default
- Default now: ⌃⌥M is registered whenever Sound or Controls is on (Controls is on by default), once an input device exists. Mic mute works with Sound off. A mic with no mute control is muted by setting its input volume to 0.
- Change it: Settings → Sound → Mute Shortcut, or Settings → Controls → Shortcuts. Turning off both Sound and Controls releases it.
- Found on hardware (28 Oct): neither mute nor input volume 0 silences the Arctis Nova 5. See #28.

### 13. Sound mixer defaults
- Default now: per-app volume 0–150%, square-law curve below 100, linear above with a soft clip past unity. "Remember per-app states" on. "Keep preferred microphone" off, so Orbit doesn't fight macOS input switching.
- Change it: Settings → Sound. The curve is in `Sources/OrbitCore/Sound/VolumeCurve.swift`.

### 14. Keep Awake defaults
- Default now: custom duration 45 min, display stays awake off. The dot on the menu bar icon shows while a session runs.
- Change it: Settings → Controls.

### 15. Windows: Quit has no confirmation, and Dock preview works without Screen Recording
- Default now: Quit (`terminate`) runs at once; Force Quit asks inline. With Accessibility alone the Dock preview shows title cards instead of thumbnails. Hover delay 0.35 s.
- Change it: Settings → Windows for the delay. The Quit confirmation is a code change in `Sources/OrbitApp/Features/Windows/`.

### 16. Wallpaper pause rules
- Default now: pause in Low Power Mode on, pause on battery off, and pause when covered, locked or asleep always.
- Change it: Settings → Wallpaper → Playback.

### 17. Clipboard click behaviour
- Default now: clicking an entry in the menu bar tab only copies it. Only the ⇧⌘V popup pastes. "Paste straight into the app" is on (needs Accessibility). The pasteboard content present when the feature starts is not recorded.
- Change it: Settings → Clipboard for the paste switch. Making the tab paste is a code change in `Sources/OrbitApp/Features/Clipboard/`.

### 18. Grab Text: should a QR code win over text?
- Default now: yes. If the area has a QR code or barcode, its payload is copied instead of the text. Grab Text works on one display at a time. Vision language correction is on, which can alter code or URLs.
- Change it: code, in `Sources/OrbitCore/Controls/GrabText.swift` and `TextRecognizer.swift`.

### 19. Controls tab name and icon
- Default now: "Controls", symbol `switch.2`, last tab.
- Change it: `Sources/OrbitCore/Suite/FeatureID.swift`.

### 20. SHELF position in the wheel
- Default now: SHELF is the second slice of the Actions ring, right after FLOAT, only while Shelf is on. The ring becomes 8 slices.
- Change it: `Sources/OrbitCore/Catalog/SliceCatalog.swift`.

## Things to confirm before you rely on them

### 21. Can you drop BetterDisplay?
- Default now: nothing was changed. BetterDisplay's preferences show no virtual screens in use, and its one `/Library/Displays` override is for vendor 0 / product 0, which doesn't apply to your monitors. Orbit only lists the modes macOS offers and cannot create HiDPI modes. Your 3008 × 1692 HiDPI on the ThinkVisions is a macOS-offered mode.
- Confirm by testing Displays with BetterDisplay quit before you uninstall it.

### 22. Do you want DDC on the Acer K272HUL?
- Default now: software (gamma) dimming, because it answered no DDC reads.
- Change it: turn DDC/CI on in the monitor's own menu. Orbit then switches to DDC after the next display change. Or turn off "Dim displays that don't answer DDC in software" in Settings → Displays.

### 23. ThinkVision boost range (answered 28 Oct)
- Tested on hardware: the P27u-20s clamp DDC writes at 100, and any write ends a boost set from their own menu. The pill now shows a boost up to 150 but never writes above the monitor's reported maximum (100). A click in the striped zone keeps the boost. The caption says to boost from the monitor's menu.
- Change it: Settings → Displays → Maximum brightness. An override still writes up to its value (review M9; you have none set).

## Housekeeping questions

### 24. Version number
- Default now: not bumped, still 1.1.0 (build 110), because you said not to.
- Change it: `Support/Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`) before you release.

### 25. Commit trailers
- Default now: Clipboard commits end with `Claude Opus 5.5`; Shelf commits end with `Claude Sonnet 5.5`. They were left as written. If wrong: a cosmetic difference.
- Change it: `git rebase --exec` can rewrite them.

### 26. Debug modes in the release binary
- Default now: the snapshot and check modes (`--snapshot-*`, `--check-shelf`, `--check-clipboard`, and others) ship in the release app. Shelf alone is about 700 lines. This follows the existing `EditorCheck` idiom.
- Change it: the hooks in `Sources/OrbitApp/main.swift`. Keep, put behind a flag, or strip.

### 27. Two gaps left open on purpose
- Default now: the final review triage left two known gaps. Task 8 battery de-dup can list a device twice when a user-named power source and a model-named registry entry both exist. Task 14 Dark Mode partial failure can leave Auto appearance off with no rollback.
- Change it: tell me if either should be fixed before you merge.

## New from the hardware session (28 Oct)

### 28. How should Orbit handle the Arctis Nova 5 mic?
- Default now: ⌃⌥M shows muted, but the headset keeps sending audio. The dongle accepts Core Audio mute and input-volume writes and reads them back, but its audio ignores both. Research found no published HID mute command for the Nova 5. The only candidate is the headset's mic volume (0–15); nobody has measured whether 0 is silence. Research: `docs/suite/ARCTIS-HID.md`.
- Options: (a) with you watching, listen for the mute button over HID (nothing sent), then try mic volume 0 once and restore it; (b) a virtual microphone Orbit can silence (an audio driver, a large job); (c) a warning in the Sound tab that this mic can't be muted from the Mac, so you use the headset button.

### 29. "Same on all displays" is on by default
- Default now: on. Choosing a wallpaper on a connected display applies it to every connected display. Turning it on copies the main display's wallpaper to the others. At launch it only fills displays that have no wallpaper, so it never overwrites your per-display choices.
- Change it: Settings → Wallpaper, or the switch in the Wallpaper tab.

### 30. "Keep copied passwords" is off by default
- Default now: off. Copies marked as passwords (the Passwords app, 1Password, and any app using the concealed pasteboard type) are not recorded. When on, they are kept in memory only, masked, at most 20, and they don't count toward the history limits. With it on, anything copied from 1Password is masked, usernames included, because Orbit treats 1Password's pasteboard marker as a password.
- Change it: Settings → Clipboard → Keep copied passwords.

### 31. Five review minors left open
- Default now: not fixed. M4: Clipboard checks files on the main thread on right-click, drag start and Open, so an entry on a sleeping network share can beachball the panel. M5: right-click on a Clipboard tab tile works only on its text and badge. M7: Wallpaper sync can copy a main-display video that can't play (file gone, drive unplugged) and blank the other displays. M8: a shelved folder in your home folder makes the Shelf watch the whole home folder while it's open. M9: a brightness override set under the old footnote still writes above 100.
- Change it: tell me which to fix before you merge.

