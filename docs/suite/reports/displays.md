# Task 9 — Displays: implementer report

**Status: DONE_WITH_CONCERNS.** The concerns are hardware ones I wasn't allowed to test: DDC writes (including the 150 boost), gamma dimming and mode switching were never run on the Mac. All read paths were checked on Kevo's real displays.

Branch `suite/displays`, 13 commits. Not pushed, as instructed.

**Base:** I started at `1a84988` as told. When the controller's note named `SnapshotFixtures`, I rebased onto `claude/suite-77e4bb` at `39ca1ca` ("docs(suite): shell fix round 1 report"). My commits only touch Displays files, and the rebase applied cleanly.

| SHA | Subject |
|---|---|
| 1a3880e | feat(displays): DDC/CI get/set VCP framing and validated reply parsing |
| 7ffacc8 | feat(displays): proportional link-brightness math |
| 7bd7542 | feat(displays): resolution menu model with HiDPI labels, dedupe and refresh rates |
| d8a0fa3 | feat(displays): brightness range with override, DDC max and learned boost; tile captions |
| 7123204 | feat(displays): DisplaySettings (link, max overrides, gamma fallback, software dim, learned max) |
| 4ffe7bf | feat(displays): match IOAVServices to displays by location, EDID facts and elimination |
| 9fe468b | feat(displays): software dimming gamma math with a 10 % floor |
| 664f15e | feat(displays): tile order and titles that tell identical monitors apart |
| 03dba72 | feat(displays): link brightness across displays with different ranges |
| cdd54f7 | feat(displays): name the built-in tile after the Mac model |
| c6219b7 | feat(displays): Displays tab and settings with DDC, DisplayServices, gamma and modes |
| 0d24db5 | fix(displays): refresh the settings model on appear, not while building the view |
| ce52493 | test(displays): order never pairs a service against its unit name |

## What I built

### Core (`Sources/OrbitCore/Displays/`, pure, tested)
- **`DDC`**: `getVCPRequest(code:)` → `51 82 01 <code> <chk>`. `setVCPRequest(code:value:)` → `51 84 03 <code> <hi> <lo> <chk>`, with the value clamped to 0...0xFFFF and never wrapped. Both checksums are XORs that include the destination 0x6E.
  - The I2C layer adds the 0x6E itself. So `request[0]` (0x51) is the I2C data address and `request[1...]` is the payload.
  - `parseVCPReply(_:code:) -> VCPValue?` (`current`, `maximum`) rejects:
    - short replies, including the 3-byte "null message"
    - a source byte other than 0x6E
    - a length byte other than 0x88
    - an opcode other than 0x02
    - a result code other than 0
    - a different VCP code
    - a bad checksum (seeded with 0x50)
  - Bytes past the frame are ignored.
- **`BrightnessLink`**: `values(changing:to:current:)` works on fractions. Other displays change by the same ratio. When either side is at 0 there is no ratio, so they shift by the same amount instead. Everything is clamped to 0...1.
  - An overload, `values(changing:to:members:)`, takes each display's `BrightnessRange` and its value when the drag started. It returns values in each display's own units, rounded to whole steps.
- **`DisplayModeList`** (from `RawDisplayMode` = width, height, pixelWidth, pixelHeight, refresh, isUsable, ioFlags, plus ioDisplayModeID):
  - Drops unusable modes, but keeps the current mode even if it is unusable, and adds it if it is missing.
  - Merges duplicates. The current mode wins, then the one flagged native, then 1:1 for standard sizes.
  - Sorts by width, then height, with HiDPI before standard, and the fastest refresh first.
  - Labels sizes "2560 × 1440" or "… HiDPI" (HiDPI = backing exactly twice the point size). Adds " · 60 Hz" only when a size has several rates. 59.94 Hz keeps its decimals; 0 Hz gets no label.
  - Provides `groups` (one per size, rates inside), `current`, and `title` (the current size, or "Resolution").
- **`BrightnessRange`**:
  - `maximum` = override ?? reported DDC max ?? 100. Without an override, a reading whose current value is above the reported max (now, or remembered) raises the automatic maximum, capped at 2× the reported max.
  - `nominalMaximum` (where the boost stripes start) = reported max ?? 100.
  - `scale` → `PillScale(maximum:boostStart:)`; also `fraction(for:)` and `value(forFraction:)`.
- **`BrightnessControl`** (`native(builtIn:)`, `ddc`, `software`, `probing`, `unavailable`) with the tile captions: "Built-in", "Apple display", "DDC", "DDC · up to 150", "Software dimming", "Checking DDC…", "Brightness not adjustable".
- **`DisplaySettings`** stores these keys:
  - `displays.linkBrightness` (false)
  - `displays.maxOverrides` ([key: Int], 1...65535)
  - `displays.useGammaFallback` (true)
  - `displays.lastSoftwareDim` ([key: Double])
  - `displays.learnedMaximums` ([key: Int], an extra field; see builder's call 1)

  It also has `maxOverride(for:)`, `setMaxOverride(_:for:)` and `learn(maximum:reported:for:)`. Values of the wrong type fall back to the defaults.
- **`DDCServiceMatcher`, `AVServiceDescriptor`, `DisplayDescriptor`, `EDIDUUID`, `AVServicePairing`**: the matching ruling (scoring plus elimination). See "Matching" below.
- **`SoftwareDim`**: gamma factor = 0.1 + 0.9 × brightness/100 (10 % floor), `dims(_:)`, and `scaled(_:by:)` for one table channel.
- **`DisplayArrangement`**:
  - Tile order: built-in first, then left to right by centre, then top to bottom.
  - Titles drop macOS's " (1)" suffix. Two identical names become "· Left"/"· Right" (or "· Top"/"· Bottom"); three or more get "· 1", "· 2", ….
  - The built-in tile is named after the Mac. `macModelName(fromProductName:)` turns "MacBook Pro (16-inch, M5 Max)" into "MacBook Pro".

### App (`Sources/OrbitApp/Features/Displays/`)
- **`DisplaysFeature`**:
  - `init` only loads settings.
  - `start()` creates the model and driver, re-applies any saved software dimming, and observes `didChangeScreenParameters` and `screensDidWake`.
  - `stop()` removes the observers, drops queued writes, hands gamma back to ColorSync (`CGDisplayRestoreColorSyncSettings`, only if Orbit dimmed something) and releases the DDC services. Both are idempotent.
  - `panelDidAppear` refreshes; `panelDidDisappear` flushes.
  - `snapshotViews()` uses `DisplaysFixtures` on `SnapshotFixtures.defaults()`.
- **`DisplayCatalog`**:
  - Lists `NSScreen.screens` (ids via `DisplayIdentity`, names from `localizedName`).
  - Reads vendor, model and serial from `CGDisplay*`, and `IODisplayLocation`, name and date from `CoreDisplay_DisplayCreateInfoDictionary` (via `PrivateSymbol`).
  - Gets modes from `DisplayModeService` and the Mac's model name from the IODeviceTree `product-name`.
  - Per-display settings use `DisplayIdentity.key(for:)`.
- **`BuiltInBrightness`**: DisplayServices `CanChangeBrightness` / `GetBrightness` / `SetBrightness` via `PrivateSymbol`.
- **`DDCService`** (one serial queue):
  - Walks the IORegistry for framebuffers (`IOMobileFramebufferShim` / `AppleCLCD2`) and external `DCPAVServiceProxy` entries, pairs them, and matches them to displays.
  - Creates an `IOAVService` per matched display (`IOAVServiceCreateWithService` via `PrivateSymbol`).
  - Reads: write the Get VCP request twice, 10 ms apart, wait 50 ms, read 11 bytes, and accept the reply only if `parseVCPReply` does. Up to 3 attempts.
  - Writes: only the latest value per display is kept; it is sent twice, then the queue waits 50 ms.
  - `invalidate()` after a display change drops the endpoints, so nothing is sent to a stale pairing.
  - `isSupported` is false on x86_64 (`#if arch(arm64)`) or when the symbols are missing.
- **`GammaDimmer`**: captures the original tables before the first change and scales them with `CGSetDisplayTransferByTable`. Setting a display back to 100 restores its tables. `reapply()` after display changes and wake starts again from ColorSync. `restoreAll()` runs on stop and quit.
- **`DisplayModeService`**: `CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes`. `apply` uses `CGBeginDisplayConfiguration` / `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration(.permanently)` and matches the mode on every field.
- **`DisplaysModel`**:
  - Tiles start as probing; the DDC result then makes them `.ddc`, or `.software` (or `.unavailable` with the gamma fallback off).
  - Learns the maximum from readings.
  - Link brightness works from the values when the drag began.
  - Writes are throttled to one every 80 ms during a drag (latest value), with a flush when it ends; software levels are persisted then.
  - A DDC reading that was already in flight never overwrites a value the user just set.
  - Turning the gamma fallback on or off live dims or restores at once.
  - `refreshForSettings()` runs when the Settings page appears.
- **`DisplaysPanelView`** (per the mockup):
  - Header: "DISPLAYS" with a **Link brightness** / **Linked** link button.
  - Each display tile: name, caption, resolution `PanelMenuButton`, and a `PillSlider` with stripes past the nominal maximum.
  - Mode menu: HiDPI sizes, a divider, then standard sizes. A size with several rates opens a submenu. The current mode is ticked, and "Displays Settings…" is at the end.
  - A tile without control shows a hint instead of a pill.
- **`DisplaysSettingsView`**:
  - **Brightness**: Link brightness, plus "Dim displays that don't answer DDC in software".
  - **Maximum brightness**: one row per external monitor. It shows "DDC reports 150 of 100" and a Stepper (100…255, step 5) starting from "Auto (150)", with an "Auto" link to reset.
  - **Resolutions**: a note on what Orbit can't add.

## Matching (the hard part)
- **Pairing service to framebuffer:** match the `dispextN` unit in both IORegistry paths (".../dispext0@B0000000/IOMobileFramebufferShim" and ".../dispext0:dcpav-service-epic:0/DCPAVServiceProxy"). Otherwise use the framebuffer just before the service in walk order, but only when that can't contradict a unit name.
- **Scoring a service against a display:**
  - Exact `IODisplayLocation` match: +1000.
  - Vendor and product: +10 each; a difference rules the pair out.
  - Numeric serial (non-zero) or alphanumeric serial: +100; a difference rules the pair out.
  - Name: +5. Manufacture week and year: +2.
  - A built-in display is never matched.
- **Locations count only if comparable:** locations are compared only when at least one pair matches exactly. If a future macOS changes the path format, everything falls back to the EDID facts instead of being ruled out.
- **Assignment:**
  - Exact location matches are taken first.
  - For the rest, the assignment wins that pairs the most services, then has the highest total score, then stays closest to list order. Impossible pairs are already eliminated by the scoring.
  - This search is exhaustive up to 8 undecided services, best-pair-first above that.
- **On Kevo's Mac:**
  - All four matched by location. This uses Orbit's own `DisplayCatalog` + `DDCService` code, run read-only by a scratch harness.
  - Mapping: dispext0 ThinkVision V90GFKY1 → CG display 4 ("P27u-20 · Right"); dispext1 Acer → 5; dispext2 ThinkVision V90GFKXY → 2 (main, "P27u-20 · Left"); dispext3 AOC → 3.
  - Each read took about 100 ms; the Acer gave up after about 280 ms. A second pass reused the endpoints with the same results.
- **Correction to hardware.md:**
  - The numeric `SerialNumber` 1663094707 belongs to the **Acer K272HUL**. Both ThinkVisions report `SerialNumber = 0`.
  - The two ThinkVisions really can only be told apart by `IODisplayLocation` or `AlphanumericSerialNumber`. CoreGraphics/CoreDisplay give no alphanumeric serial and no EDID bytes.

## DDC read replies from Kevo's four monitors (Get VCP 0x10, 2026-10-28)
These are reads only. The request was `51 82 01 10 AC` at I2C 0x37 (plus the 0x6E the driver adds).

| Monitor | IORegistry | Reply bytes | Meaning |
|---|---|---|---|
| ThinkVision P27u-20 (V90GFKY1) | dispext0 | `6E 88 02 00 10 00 00 64 00 96 56` | result 0, max **100**, current **150** |
| ThinkVision P27u-20 (V90GFKXY) | dispext2 | `6E 88 02 00 10 00 00 64 00 96 56` | result 0, max **100**, current **150** |
| AOC Q27G4ZD | dispext3 | `6E 88 02 00 10 00 00 64 00 64 A4` | result 0, max 100, current 100 |
| Acer K272HUL | dispext1 | no reply | `IOAVServiceWriteI2C` and `ReadI2C` both returned `0xE0114000` on every attempt (4 in the probe, 3 in the harness); the buffer stayed all zeros |

- The ThinkVisions report max 100 while sitting at 150, boosted from their own menu. That is why Orbit's automatic range uses an observed value above the max: they get "DDC · up to 150" with no override needed.
- The Acer most likely has DDC/CI turned off in its menu, or doesn't support it on this input. It gets software dimming. If Kevo turns DDC/CI on, the next probe after a display change switches it to DDC and removes the gamma dimming.
- DisplayServices `CanChangeBrightness` is false for all four externals, and `GetBrightness` returned error 1000 for each.

## What Orbit can and can't replace from BetterDisplay
What I found (read-only):
- BetterDisplay is running (pid 2889).
- Its preferences show no virtual screens in use (`systemVirtual` / `thirdPartyVirtual` = 0 for every display).
- There is one `/Library/Displays` override: `Overrides/DisplayVendorID-0/DisplayProductID-0`, dated May 22. It applies to displays reporting vendor 0 / product 0 (generic / no-EDID): default 2560×1440 plus about 34 scale-resolutions. It does not apply to any of Kevo's monitors (vendors 0x30AE, 0x05E3, 0x0472).
- The ThinkVisions' current **3008 × 1692 HiDPI** (6016×3384 backing) is a mode macOS itself offers. Mode counts in Orbit's list:
  - ThinkVision: 103 usable modes in 41 sizes, including 3360×1890 HiDPI and 3200×1800 HiDPI.
  - AOC: 123 modes in 18 sizes, with rates up to 240 Hz.
  - Acer: 33 modes.

**Orbit replaces:**
- Choosing any resolution macOS offers on each display, HiDPI included, with refresh rates.
- Brightness over DDC on the ThinkVisions (0–150) and the AOC (0–100).
- Software (gamma) dimming on the Acer.
- Link brightness.
- Built-in brightness when the lid is open.

**Orbit doesn't replace:**
- **New HiDPI modes or "flexible scaling".** BetterDisplay-made modes need `/Library/Displays` overrides, EDID overrides or virtual-screen mirroring. Orbit writes nothing to `/Library`.
- Virtual screens / dummies, PIP, and XDR/HDR "upscale" brightness.
- DDC for anything other than brightness: contrast, volume, input switching.
- Colour profiles and per-app rules.

For Kevo's current setup none of this seems to be in use. The vendor-0 override file stays where it is; Orbit never touches it.

## Tests (TDD evidence)
Every pure unit was written test-first against a stub, failed, was implemented, then passed. The commands were `swift test --filter <Suite>`; trimmed output follows.

| Suite (file) | RED | GREEN |
|---|---|---|
| `DDCTests` (DisplaysTests.swift) | 4 tests failed, e.g. `(DDC.getVCPRequest(code: 0x10) → []) == [0x51, 0x82, 0x01, 0x10, 0xAC]` and `(DDC.parseVCPReply(thinkVision, code: 0x10) → nil) == VCPValue(current: 150, maximum: 100)`, then "Fatal error: Array index is out of range" (signal 5) from indexing the stub's empty array | `✔ Test run with 7 tests in 1 suite passed` |
| `BrightnessLinkTests` | `linkProportional`, `linkClamps` failed (`→ [:]`); later `linkWorksInEachDisplaysOwnRange` failed with 5 issues | 2, then 3 tests passed |
| `DisplayModeListTests` | both failed (`list.entries.map(\.label) → []`) | 2 passed |
| `BrightnessRangeTests` | 4 failed (e.g. `overridden.maximum → 100) == 150`, `caption → "") == "DDC · up to 150"`) | 4 passed |
| `DisplaySettingsTests` | 2 failed (`reloaded.linkBrightness → false) == true`, keys missing) | 2 passed |
| `DDCServiceMatcherTests` (DisplaysMatchingTests.swift) | 7 failed, plus "Unexpectedly found nil while unwrapping" (signal 5) | 8 passed (on the first implementation) |
| `SoftwareDimTests` | 2 failed | 2 passed |
| `DisplayArrangementTests` | 2 failed (7 issues); later the built-in prefix (1) and `builtInName` / `macModelName` (2) | 2, then 3 passed |

**Brief test names, all present:**
- In `DDCTests`: `getRequestFraming`, `setRequestFraming`, `parsesValidReply`, `rejectsBadChecksum`, `rejectsShortReply`, `rejectsWrongCode`.
- In `BrightnessLinkTests`: `linkProportional`, `linkClamps`.
- In `DisplayModeListTests`: `modeListDedupesAndLabelsHiDPI`.
- In `BrightnessRangeTests`: `rangeUsesOverrideThenDDC`.
- In `DisplaySettingsTests`: `settingsRoundTrip`.

**Extra tests:**
- `rejectsWrongOpcodeSourceLengthAndErrorResult`, `linkWorksInEachDisplaysOwnRange`, `modeListPrefersCurrentAndNativeDuplicatesAndKeepsAnUnusableCurrent`, `rangeLearnsFromObservedValues`, `rangeMapsFractions`, `captions`, `settingsLearnKeepsTheHighestAndIgnoresJunk`, the `SoftwareDim` tests, and the `DisplayArrangement` tests.
- The matcher tests use Kevo's real registry and CoreDisplay data:
  - `matchesKevosFourMonitorsByLocation`
  - `twoIdenticalMonitorsDifferOnlyBySerial` (numeric and alphanumeric serials, with the display list in reverse order)
  - `eliminationAssignsTheRemainingIdenticalMonitor`
  - `locationsDecideOnlyWhenComparable`
  - `neverMatchesTheWrongKindOfDisplay`
  - `decodesEDIDUUIDs`
  - `buildsDescriptorsFromRegistryAndCoreDisplay`
  - `pairsServicesWithTheirFramebuffers`

Settings tests use `Fixtures.defaults()` (an absolute-path suite in a temp folder, removed afterwards).

**Full suite:** `swift test` gives `✔ Test run with 593 tests in 33 suites passed` at `ce52493` (31 of them are mine) and at every commit from `7123204` on. `swift build` is clean, with no warnings in the Displays files.

**Load flakes:** while seven other agents were building, the machine's load average was 60–90. During the full runs for `1a3880e`, `7ffacc8` and `d8a0fa3` these existing tests failed:
- `ProcessTests.cancellationTerminates`: a timing assertion; it took 3.2–4.6 s against a 3 s limit.
- `VideoToolTests.joinMKVsOfDifferentSizesScalesToTheFirst`: the VideoToolbox encoder couldn't be opened.
- `compressReportsSizes`.

Each passed when re-run on its own (`swift test --filter ProcessTests` and `--filter compressReportsSizes`), and every full run after those commits was green. I committed those three units with my own tests green.

**Universal build:** `swift build -c release --arch arm64 --arch x86_64` reported "Build succeeded" at `ce52493`. `lipo -archs` gives "x86_64 arm64". The IOAVService code compiles on x86_64 and reports unsupported there.

## Snapshots I looked at
All under `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/displays/shots/`:
- `panel-1-light.png`, `panel-1-dark.png`: first pass. The built-in title "Built-in Liquid Retina XDR Display" was truncated in the middle.
- `panel-2-light.png`: after dropping the "Built-in " prefix. Still truncated.
- `panel-3-light.png`, `panel-4-dark.png`: **final**. "MacBook Pro / Built-in · 1728 × 1117 HiDPI · 72", "K272HUL / Software dimming · 80", "Q27G4ZD / DDC · 100", "P27u-20 · Left / DDC · up to 150 · 120 (striped, tinted, accent value)", "P27u-20 · Right / … · 90 (stripes past 100)". This is very close to the mockup's Displays tab.
- `settings-1-light.png`, `settings-2-dark.png`, `settings-3-light.png` (final): Brightness toggles and the per-display maximum rows ("DDC reports 150 of 100 · Auto (150)"). The Acer shows "Software dimming, 0–100" with no stepper.

## Builder's calls
1. **Learned maximum.** If a DDC reply's current value is above its reported maximum (the ThinkVisions' 150 / 100), the automatic range extends to it. The value is remembered per display in a new `displays.learnedMaximums`, so the boost zone survives turning the brightness down. It is capped at 2× the reported maximum, and an explicit override always wins.
2. **The boost zone starts at the reported maximum, not a fixed 100.** A monitor that natively reports 0–255 shows no stripes. The caption reads "DDC · up to N" only when there is a boost zone.
3. **Link brightness works on fractions of each display's own range.** It moves proportionally from the values when the drag began. Displays at 0 shift by the same amount instead, so they don't stay stuck at 0.
4. **Writes are throttled to one every 80 ms while dragging (latest value), plus a flush on release, rather than strictly debounced.** The brightness keeps following the finger. The DDC queue keeps only the latest value per display.
5. **Software dimming:**
   - The gamma floor is 10 %, so a slip can't blacken a screen.
   - The level is saved per display and re-applied at start, after display changes and on wake.
   - It is restored when the display goes back to 100, when the fallback is turned off, on stop, and on quit.
6. **DDC results are cached per session.** A display that answered stays DDC after a missed reply and keeps its last value. A display that stayed silent isn't re-probed on every panel open, only after a display change.
7. **Matching policy:** see "Matching" above (exact location first, locations compared only when comparable, then most pairs / best score / list order).
8. **Tile order and titles:** built-in first, then left to right. Identical monitors get "· Left" / "· Right".
   - The built-in tile takes the Mac's model name from the device tree ("MacBook Pro", as in the mockup).
   - Without it, the panel name loses its "Built-in " prefix.
9. **The mode menu groups refresh rates into submenus** (the AOC has 123 modes). A resolution change is applied `.permanently`, like System Settings, with no confirm or revert timer.
10. **The pill shows the raw DDC value** (120, 150), not a percent, so it matches the monitor's own menu.
11. **"Apple display" caption** for external displays that DisplayServices drives, such as a Studio Display (untested).
12. **Settings override:** the Stepper runs 100…255 in steps of 5 and starts from the Auto value. "Auto" resets it. Rows for software-dimmed monitors have no stepper, because overrides only affect DDC.
13. **While Displays is off, its Settings page lists the connected displays from the catalog only.** No DDC is used and nothing is written.
14. **Reads try 3 times** (write twice 10 ms apart, wait 50 ms, read). The brief allowed retries; I chose 3 so a silent monitor gives up in about 0.3 s.
15. **Rebased onto `39ca1ca`** to use `SnapshotFixtures` (controller note).

## Shell changes
None. I only touched `Sources/OrbitCore/Displays/`, `Sources/OrbitApp/Features/Displays/`, `Tests/OrbitCoreTests/DisplaysTests.swift` and `Tests/OrbitCoreTests/DisplaysMatchingTests.swift`.

## Needs hardware verification
- **DDC Set VCP 0x10 above 100 on the ThinkVisions.** Kevo says the monitors take 150 from their own menu, and they *report* 150 now. Nobody has checked that they accept 101–150 over DDC rather than clamping to 100 or ignoring it. No DDC write was ever sent during development. If they clamp, setting the maximum override to 100 in Settings removes the misleading boost zone.
- **DDC writes in general:** whether 80 ms throttling plus about 60 ms per write feels responsive, and whether any monitor needs a longer gap.
- **Gamma dimming on the Acer on macOS 26:**
  - That `CGSetDisplayTransferByTable` actually dims it.
  - Behaviour around sleep and wake.
  - That quitting Orbit, or a crash, restores the colours (macOS normally drops a process's gamma changes when it exits).
- **Mode switching.** No mode was ever changed during development. Nested `Menu` submenus inside `PanelMenuButton` (the menu bar panel) should be checked on screen.
- **The built-in DisplayServices path.** The lid is closed, so it was only seen in snapshots.
- **Hot-plug and lid-open re-matching** (`displaysChanged` → invalidate → rescan).
- **BetterDisplay is still running and also talks DDC.** Two apps polling the same monitors can collide until BetterDisplay is quit or uninstalled.

## Known gaps
- Brightness (VCP 0x10) is the only DDC control: no contrast, volume or input switching. Intel Macs get gamma dimming only (no IOFramebuffer I2C path).
- No HiDPI mode creation and no virtual screens (see above).
- A resolution change has no automatic revert.
- Two identical monitors with no `IODisplayLocation` and no serials fall back to list order. That's a guess, though one that doesn't happen on Kevo's Mac.
- Brightness changed from the monitor's own buttons while the panel is open isn't picked up until the next time the panel opens.
- `DisplaysModel` (app glue: probing, the throttle, link baseline) has no unit tests. Its maths is in the tested OrbitCore units.

## Hygiene
- **Read-only probes**, all in the scratchpad under `displays/`, none committed:
  - `probe/probe.swift` (output in `probe/probe-output.txt`): CG displays, CoreDisplay info, the IORegistry walk, and DDC **Get VCP 0x10 only**.
  - `modes/modes.swift` (output in `modes/modes.txt`).
  - `probe/screens.swift`.
  - `probe/ds.swift`: DisplayServices can-change and get.
  - `harness/main.swift` (output in `harness/run1.txt`): Orbit's real catalog and DDC read path. It sends Get VCP only, and redirects `Log` to `harness/harness.log`, so Orbit's real log was untouched (0 "displays:" lines in `~/Library/Logs/Orbit/orbit.log`).
- **No `~/Library/Preferences` plists** were created by my runs. I checked for files newer than the checkout matching orbit/fixture/snapshot/display: none. Tests use `Fixtures.defaults()`; snapshots use `SnapshotFixtures.defaults()`.
- I did not launch the app, change brightness, modes or gamma, write DDC, or touch `/Users/kevog/orbit`. `/Library/Displays` was only read.
- **Report location:** my write tools are confined to my worktree and scratchpad, so they refused the suite path. I wrote this report to the scratchpad (`displays/displays.md`) and copied it to the suite path where the sandbox allowed.

## Files
- **New, OrbitCore:** `Sources/OrbitCore/Displays/{DDC,BrightnessLink,DisplayModeList,BrightnessRange,DisplaySettings,DDCServiceMatcher,SoftwareDim,DisplayArrangement}.swift`
- **New, app:** `Sources/OrbitApp/Features/Displays/{BuiltInBrightness,DDCService,GammaDimmer,DisplayModeService,DisplayCatalog,DisplaysModel,DisplaysPanelView,DisplaysSettingsView,DisplaysFixtures}.swift`
- **Replaced:** `Sources/OrbitApp/Features/Displays/DisplaysFeature.swift` (same class name and `init(context:)`).
- **Tests:** `Tests/OrbitCoreTests/DisplaysTests.swift`, `Tests/OrbitCoreTests/DisplaysMatchingTests.swift`.

## Fix round 1
These commits sit on top of `ce52493` on `suite/displays`. No rebase and no push.

On this Mac I still made no DDC writes, mode changes, gamma changes or brightness writes. The read-only harness was re-run (Get VCP only). The new confirm window and the gamma paths were only built and snapshotted.

| SHA | Subject | Items |
|---|---|---|
| b3ec1ef | feat(displays): pure DDC tile-control policy with retry/backoff before demoting | M7, M1 (pure) |
| 889e7d6 | feat(displays): learn a boost range only after two readings in a row; forget on request | M3 (pure) |
| d9bf3cf | fix(displays): gamma dimming restores only Orbit's displays, from trusted originals | M4 |
| c353f2c | feat(displays): models for the resolution-confirm countdown and the other-display-app hint | M2, M6 (pure) |
| 9ef01ef | fix(displays): re-match DDC after wake, report failed writes, retry before demoting | I1, M1, M7, M9 (root release, merged invalidate) |
| 7b27eab | fix(displays): learn the boost range after two readings in a row; Reset learned range | M3 |
| 450ed3e | fix(displays): resolution changes ask Keep this resolution? and revert after 15 s | M2 |
| dd8d238 | fix(displays): one-line hint in the Displays tab while BetterDisplay also runs | M6 |
| 66f894b | fix(displays): the mode menu's last item says it opens macOS Display Settings | M9 |

### What changed
- **I1: wake and failed I/O.**
  - `DisplaysFeature` observes `NSWorkspace.screensDidWakeNotification` and `NSWorkspace.didWakeNotification`. The two usually arrive together, so they are coalesced and handled 1.5 s later. That calls `DisplaysModel.systemWoke`, which:
    - drops all DDC endpoints and queued writes (`ddc.invalidate()`) and forces a registry re-scan;
    - re-applies gamma;
    - resets the miss counts of silent displays;
    - refreshes the tiles if the tab is visible.
  - `DDCService`:
    - A failed read on a matched service is logged ("no valid DDC reply from display N after 3 attempts; will re-scan its service") and sets `needsScan`.
    - A write whose two attempts both return an error is logged with both IOReturn codes. It drops that endpoint, sets `needsScan` and calls `onWriteFailure`. The model then schedules a re-probe of the display (1 s, re-scanning first).
  - A display that answered DDC before and misses a reply now stays "DDC" with its last value. It is re-scanned and asked again (policy below), with a log line per miss.
- **M1 + M7: the policy.** The rules now live in `DisplayControlPolicy` in OrbitCore, a pure function with tests. `DisplaysModel.refresh`/`received` just apply its outcomes.
  - `start(state:ddcSupported:asleep:gammaFallback:)` gives the starting control and whether to probe:
    - never answered → probing
    - answered → DDC, ask again
    - Intel, or gave up → fallback
    - asleep → DDC if it answered, else fallback; not asked
  - `outcome(of:state:gammaFallback:)`:
    - A valid reply → DDC: adopt the value, clear software dimming, reset misses.
    - No reply → miss + 1; retry after 1 s, then 3 s (re-walking the registry); after 3 misses in a row → software dimming, or no control with the fallback off. A display that answered shows DDC while it retries; one that never answered shows "Checking DDC…".
  - `afterWake` re-asks displays that gave up.
  - `persistsSoftwareDim` is false for any display that has answered DDC. `DisplaySettings.answeredDDC` (`displays.answeredDDC`) remembers those across runs:
    - `rememberAnsweredDDC` drops any saved software level for that display;
    - `endEditing` never saves one;
    - `applySavedSoftwareDims` never re-applies one.
- **M2: Keep this resolution?**
  - `DisplayModeService.apply(_:to:permanently:)`.
  - `select` applies the new mode `.forSession`. It then shows a floating card (`ResolutionConfirmWindow`: a borderless, non-activating, key-capable panel one level above the status bar, on all Spaces). The card is centred on the changed display and re-centred on every screen-parameter change.
  - That display's tile also shows a row. Both read "Keep … ? Reverting in N s" with Revert (Esc) and Keep (Return).
  - **Keep** re-applies the mode `.permanently`.
  - **Revert**, or 15 s without an answer, applies the previous mode `.forSession`. If that fails it calls `CGRestorePermanentDisplayConfiguration()`.
  - Starting a second change reverts a pending one first. `stop()` and quit revert a pending change.
  - The countdown model is `ResolutionConfirmation` (OrbitCore, tested).
- **M3: learned boost.**
  - `BoostLearner` (OrbitCore) returns a maximum to remember only on the second validated reading in a row above the reported maximum (the lower of the two). A normal reading in between breaks the run.
  - The current session still uses the latest reading's value for the pill's range.
  - Settings shows "· learned 150" in the monitor's detail line and a **Reset learned range** link next to the override (`DisplaySettings.forgetLearnedMaximum` plus the learner's `forget`).
- **M4: gamma.**
  - `GammaDimmer` no longer calls `CGDisplayRestoreColorSyncSettings` anywhere.
  - Originals are captured once per display identity per run, before Orbit's first dim. `GammaRamp.trustedOriginal()` (OrbitCore, tested): a table whose peak is below 0.98 is suspect and is lifted to full keeping the channels' balance (logged); a nearly black one (< 0.05) becomes a straight ramp.
  - `restore`, `restoreAll` (stop/quit) and `reapply` (display change, wake) only re-apply those originals, scaled or not, to the displays Orbit dimmed.
- **M6: other display apps.** `DisplayConflicts.hint(runningBundleIDs:)` (OrbitCore, tested) knows BetterDisplay, MonitorControl and Lunar. `refresh()` checks `NSWorkspace.runningApplications`, and the tab shows one line under the header: "BetterDisplay is running too and may undo changes made here."
- **M9:**
  - The `IORegistryGetRootEntry` handle is released.
  - `disconnect()` is merged into `invalidate()`.
  - The mode menu item is now "Open macOS Display Settings…".

### Tests and commands
New pure units were written test-first against stubs.

**`swift test --filter DisplayControlPolicyTests`**
- RED, 6 tests failing, e.g.:
  - `start(state: new, …) → (control: .probing, probe: false)) == (.probing, true)`
  - `outcomes.map(\.control) → [.probing, .probing, .probing]) == [.probing, .probing, .software]`
- GREEN: `✔ Test run with 6 tests in 1 suite passed`.
- Tests: `startDecisions`, `successBecomesDDCAndClearsSoftwareDim`, `missedReplyKeepsDDCForADisplayThatAnswered`, `silentDisplayRetriesWithBackoffThenFallsBack`, `softwareDimIsOnlyRememberedForDisplaysThatNeverAnswered`, `wakeAsksDisplaysThatGaveUpAgain`.

**`swift test --filter BoostLearnerTests`**
- RED: `learner.observe(… 150 of 100 …) → nil) == 150`, and `settings.learnedMaximums → ["tv": 150, "aoc": 150]) == ["aoc": 150]`.
- GREEN: 3 passed (`learnsOnlyAfterTwoReadingsInARow`, `aNormalReadingOrForgetBreaksTheRun`, `settingsForgetTheLearnedRange`).
- `settingsRememberDisplaysThatAnsweredDDC` was added in the I1 commit. RED: `reloaded.answeredDDC → []`. GREEN: passed.

**`swift test --filter GammaRampTests`**
- RED: `normal.peak → 0.0) == 1`, `suspect` false, `ramp → GammaRamp(red: [], …)`.
- GREEN: 3 passed (`trustsANormalTable`, `liftsAnAlreadyDimmedTable`, `scalesEveryChannel`).

**`swift test --filter ResolutionConfirmationTests`**
- RED: `secondsLeft(at: start) → 0) == 15`, `hint(...) → nil`.
- GREEN: 2 passed (`countsDownFifteenSecondsThenExpires`, `hintNamesTheOtherDisplayApps`).
- When I shortened the hint to one line, I changed the test first. RED: the old sentence ≠ "BetterDisplay is running too and may undo changes made here." Then GREEN.

**Totals:**
- `swift test --filter Displays` → `✔ Test run with 46 tests in 12 suites passed` (31 before plus 15 new). The filter matches the `Displays*Tests.swift` file names.
- Full suite, once, at `66f894b` → `✔ Test run with 608 tests in 37 suites passed after 80.034 seconds`.
- `swift build -c release --arch arm64 --arch x86_64` → "Build succeeded". `lipo -archs` gives `x86_64 arm64`.

**Read-only harness re-run against the new `DDCService`** (Get VCP only, log redirected; output in `harness/run2.txt`):
- K272HUL: no valid reply.
- Q27G4ZD: 100/100.
- Both P27u-20: 150/100.
- On the second pass the registry was re-scanned after the Acer's failed read. That is the new `needsScan` path; `harness/harness.log` shows the line "no valid DDC reply from display 5 after 3 attempts; will re-scan its service".
- `~/Library/Logs/Orbit/orbit.log` still has 0 "displays:" lines.

### Snapshots (scratchpad `displays/shots/`)
- `fix1-panel-light.png`, `fix1-panel-dark.png`: the default tab, unchanged look.
- `fix1-busy-light.png`, `fix1-busy-dark.png`: the confirm and hint check. Run with `ORBIT_DISPLAYS_SNAPSHOT=busy Orbit --snapshot-panel displays …`; it shows:
  - the BetterDisplay hint line under the header;
  - the inline "Keep 1920 × 1080? Reverting in 12 s [Revert] [Keep]" row in the AOC tile;
  - the floating "Keep this resolution?" card drawn under the tiles. Live, it is centred on the changed display.
- `fix1-settings-light.png`, `fix1-settings-dark.png`: "DDC reports 150 of 100 · learned 150" with **Reset learned range** beside "Auto (150)" on P27u-20 · Left.

### Builder's calls (fix round)
1. **Retries.** Three probes per display (1 s, then 3 s apart), each re-walking the IORegistry. After three misses in a row the display falls back until wake or a display change. A display that answered before keeps showing DDC with its last value while it retries.
2. **`displays.answeredDDC`** is persisted so the "never save a software-dim level" rule holds across launches. Remembering a display also clears any level saved for it earlier.
3. **Wake handling** runs 1.5 s after the last wake notification, so the DCP has rebuilt its services. It probes only if the tab is visible; otherwise the next open re-scans.
4. **A failed write** schedules one re-probe of that display. The probe's outcome decides what happens next.
5. **Confirm UI.** I chose both a floating card on the changed display and an inline row in its tile. The card is the one that survives the panel closing or moving.
   - Revert = previous mode `.forSession`, falling back to `CGRestorePermanentDisplayConfiguration()`.
   - Keep = the same mode re-applied `.permanently`.
   - Keep and Revert are custom capsule buttons (accent / control fill), so they look the same live and offscreen.
6. **Learned boost.** The value learned is the lower of the two readings in a row. A single reading still sets this session's range, but is not remembered.
7. **Suspect gamma tables.** The threshold is a peak below 0.98. Such a table is lifted to a peak of 1 with its channels' balance kept; below 0.05 it is replaced by a straight ramp. Originals are kept per display identity for the run, so a ColorSync profile change mid-run isn't picked up until Orbit restarts.
8. **The hint also covers MonitorControl and Lunar.** It is checked whenever the tab refreshes, not watched live.
9. **Busy snapshot variant.** `ORBIT_DISPLAYS_SNAPSHOT=busy` is read only by `DisplaysFixtures` and `snapshotViews()`. It renders the confirm and hint state without a shell change to the snapshot CLI.

### Still needs hardware verification (additions)
- The confirm flow live:
  - that `.forSession`, then `.permanently` on the same mode, persists across logout;
  - that the floating card is clickable, keyboard included, and stays centred while the display changes size;
  - that the timeout really reverts.
- The wake path on real sleep and wake: whether 1.5 s is enough for the DCP to rebuild its `DCPAVServiceProxy` entries.
- Whether `IOAVServiceWriteI2C` actually returns errors for a stale service, which is what lets write failures be detected.
- Gamma restore without ColorSync reset on the Acer, together with Night Shift and True Tone.

### Shell changes
None.
