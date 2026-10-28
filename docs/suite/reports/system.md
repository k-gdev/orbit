# Orbit Suite — System (Task 8): report

Branch **`suite/system`**, based on `1a84988 docs(suite): shell implementer report`. 14 commits, not pushed (per the
dispatch instructions). Every commit was gated by a script that runs `swift build` and the full `swift test`, and only
commits when both pass (see "Test gate" for the one caveat). Only my owned paths changed:
`Sources/OrbitCore/System/`, `Sources/OrbitApp/Features/System/`, `Tests/OrbitCoreTests/SystemTests.swift`.
**No shell changes.**

(This report was meant for `/Users/kevog/orbit/.claude/worktrees/suite-77e4bb/docs/suite/reports/system.md`. The
worktree isolation guard refused writes outside my worktree, so it lives in my scratchpad; please copy it over.)

| Commit | Subject |
|---|---|
| 4f3c77e | feat(system): CPU load from processor tick snapshots |
| 9d23ec5 | feat(system): CPU clusters by perf level name |
| ab4caef | feat(system): fixed-capacity sample history for sparklines |
| c30fc1c | feat(system): memory use, pressure and number formatting |
| 1313649 | feat(system): classify M5 Max temperature sensors and decode SMC values |
| bfa96d0 | feat(system): uptime formatter |
| 59ef51f | feat(system): battery readings from power sources and Bluetooth HID |
| cfc32bc | feat(system): settings and menu bar readout text |
| 00862bb | feat(system): sampling plan (only while visible or the readout is on) |
| c32d611 | feat(system): readings model with sparkline histories |
| d1bf8e9 | feat(system): heat levels for temperature colours |
| 0e551d5 | feat(system): sparkline scale with headroom |
| 1f8c0f2 | feat(system): samplers, monitor, panel tab, settings and menu bar readout |
| bafd4c5 | fix(system): first CPU reading after half a second; retry SMC discovery after an empty listing |

Tests: 561 → **579** (18 new in `Tests/OrbitCoreTests/SystemTests.swift`), all passing. No compiler warnings in the new
files (debug or release).

Universal release build: `swift build -c release --arch arm64 --arch x86_64` → `Build complete!` (exit 0).
`lipo -archs .build/apple/Products/Release/Orbit` → `x86_64 arm64`.

## What was built

### Core (`Sources/OrbitCore/System/`), all pure and tested
- **`CPULoad.swift`**: `CPUTicks` (user/system/idle/nice, `UInt32` like the kernel) and
  `CPULoad(previous:current:)`, giving `total` (busy ticks over all ticks, summed across cores) and `perCore`. It
  handles counter wrap-around (`&-`), compares only the cores both snapshots have, and returns 0 for a zero delta.
- **`ClusterLayout.swift`**: follows the ruling, `ClusterLayout([(name:logicalCPUs:)])` from
  `hw.perflevelN.name/.logicalcpu`. `clusters(_ perCore:)` returns `[ClusterLoad]` (name, cores, average), fastest
  level first, using the sysctl names. **Core order:** `host_processor_info` lists the slowest level first. On this
  M5 Max the device tree shows cpu0–11 as `cluster-type` "M" (clusters 0 and 1, the 12 "Performance" cores) and
  cpu12–17 as "P" (cluster 2, the 6 "Super" cores); an M1 lists its E cores first too. So CPU indices are handed out
  from the last perf level backwards (see [builder's call] 1). Loads that don't match the layout, or Intel with no
  perf levels, become one "CPU" cluster.
- **`SampleHistory.swift`**: `SampleHistory<T>` is a ring buffer (default capacity 60) with `values` oldest first,
  `latest`, `removeAll`, and conditional Equatable/Sendable. Also `SparklineScale.ceiling(for:)`: the peak × 1.25,
  clamped to 0.5…1, so a quiet machine still draws a shape.
- **`MemoryStats.swift`**: `MemoryStats` takes page counts, page size, `hw.memsize` and pressure; `usedBytes` is
  active + wired + compressed, as the brief says. `MemoryPressure(kernelLevel:)` maps 1/2/4 to normal/warning/critical.
  `SystemFormat` writes binary GB ("41.5 of 128 GB"), percentages ("23%", clamped) and degrees ("53°", "—").
- **`SensorGroups.swift`**: `SensorKind` (CPU/GPU/SoC), `SensorReading`, `SensorGroupStats` (average, max, count),
  `SensorGroups(readings:)`, which ignores readings ≤ 0, ≥ 150, NaN or ±∞. `classify` is based on the names actually
  on this Mac (below) and is tolerant of M1/M2 IOHID names and Intel SMC keys. `headline` is the CPU average, else the
  SoC's, else the GPU's. `HeatLevel` gives the colour bands (<80 normal, <95 warm, else hot). `SMCCode` converts
  four-character codes and decodes `flt ` (little-endian Float32, Apple Silicon) and `sp78` (big-endian 8.8, Intel).
- **`BatteryReading.swift`**: a `BatteryReading` has kind (mac, headphones, keyboard, mouse, trackpad,
  gameController, other), percent, charging, charged, on-adapter, minutes to empty/full, parts (L/R/Case),
  `lowWarnLevel`, `isLow` and `statusText` ("Charged", "Charging · 1 h 5 m to full", "3 h 20 m left", "Not charging",
  "L 100% · R 90% · Case 35%", "Low battery").
  `BatteryParser`:
  - `powerSources` reads IOPS descriptions. AirPods' "Combined Parts" become L/R, and the case, a separate source in
    the same "Group Identifier", folds in as a "Case" part.
  - `registryDevices` reads IORegistry `BatteryPercent`/`Product`/`DeviceAddress`, deduplicated by normalised
    address.
  - `readings` merges both: a registry device that is also a power source is dropped, then the Mac comes first and
    devices follow by name.
- **`UptimeFormatter.swift`**: "3 d 4 h", "5 h 12 m", "12 m", "< 1 m". It is also used for battery time remaining.
- **`SystemSettings.swift`**:
  - Keys: `system.menuBarReadout` (`.off` default), `system.sampleInterval` (1 s, clamped 0.5…10, Settings offers
    1/2/5) and `system.showPerCluster` (true).
  - `MenuBarReadout` (off, cpu, temperature, cpuAndTemperature) has a title, `metrics` and `text(cpu:celsius:)`
    ("CPU 23%", "53°C", "7% · 54°C", dashes before the first sample).
  - `SystemMetric` lists the things that can be sampled.
- **`SamplingPlan.swift`**: the rule for "never otherwise". `make(panelVisible:readout:panelInterval:)` gives nil
  when the tab is hidden and the readout is off, the readout's metrics every 2 s when only the readout is on, and
  everything at the panel interval while the tab shows. Also `isBatteryRefreshDue` (at most every 10 s) and `isGap`
  (more than 3 missed samples).
- **`SystemReadings.swift`**: `SystemSample` holds one tick, with nil meaning "not measured". `SystemReadings`
  holds the latest values plus the CPU/GPU histories. `apply(_:layout:at:interval:)` restarts both histories after a
  gap, so a sparkline never joins readings taken minutes apart.

### App (`Sources/OrbitApp/Features/System/`)
- **`CPUSampler`** uses `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` with `vm_deallocate`, one host port, and
  `reset()` after gaps.
- **`GPUSampler`** reads IOAccelerator `PerformanceStatistics` → "Device Utilization %" (public IORegistry). The
  service is cached until `close()`. `coreCount()` reads `gpu-core-count`.
- **`MemorySampler`** uses `host_statistics64(HOST_VM_INFO64)`, `host_page_size`, `physicalMemory` and
  `kern.memorystatus_vm_pressure_level`.
- **`SystemInfo`** reads sysctls: the perf levels → `ClusterLayout`, `machdep.cpu.brand_string`, and uptime from
  `kern.boottime`.
- **`ThermalSampler`** merges two read-only sources:
  - IOHID, through `PrivateSymbol`: `IOHIDEventSystemClientCreate`/`SetMatching` (0xff00/5), `CopyServices`,
    `IOHIDServiceClientCopyProperty("Product")`, `IOHIDServiceClientCopyEvent` type 15, and `IOHIDEventGetFloatValue`
    field 15<<16. It degrades to nothing when any symbol is missing.
  - The SMC, through `SMCReader`.

  Nothing opens before the first sample, and `close()` releases both.
- **`SMCReader`** opens the `AppleSMC` user client with public IOKit `IOServiceOpen`/`IOConnectCallStructMethod`.
  It sends **only the read commands** (5 read key, 8 key at index, 9 key info), never 6/write. It refuses to run
  unless the 80-byte C struct layout matches. Keys are discovered once per process and cached; an empty discovery is
  not cached, and each reader tries discovery only once.
- **`BatterySampler`** combines two sources:
  - IOPowerSources via `IOPSCopyPowerSourcesByType(0)`, which is private and reached through `PrivateSymbol`. It
    falls back to the public `IOPSCopyPowerSourcesInfo`.
  - IORegistry `AppleDeviceManagementHIDEventService` entries with `BatteryPercent`.
- **`SystemMonitor`** (main actor, `ObservableObject`) publishes `readings`, plus `chipName` and `gpuCores`, which
  it reads lazily the first time the tab shows. It owns a **`SamplingEngine` only while `SamplingPlan` returns a
  plan**. With no plan there is no engine at all: no timer, no queue work, no HID client, no SMC connection.
  - The engine runs every sampler on one serial utility queue, using a `DispatchSourceTimer` with 10 % leeway.
  - The first tick fires at once. When it only recorded a CPU baseline, a one-off CPU reading follows 0.5 s later.
  - A generation token drops late deliveries from an engine that has been replaced.
- **`SystemPanelView`** follows the existing look (PanelTile, PanelSectionHeader, PanelStyle and the accent
  everywhere):
  - PROCESSOR (chip name trailing): a CPU tile with the total in 22 pt rounded type, "18 cores · 2 clusters", a
    sparkline, and per-cluster rows (sysctl name, one small bar per core, cluster average).
  - GPU tile (% + "40 cores" + sparkline) beside a Memory tile (%, meter coloured by pressure, "41.5 of 128 GB",
    pressure dot + word).
  - TEMPERATURES & UPTIME: a CPU/GPU/SoC tile (average in large type with heat colour, "max N°") beside an Uptime tile
    ("3 d 11 h", "since Sat 14:18").
  - BATTERIES: "This Mac" with its status, a divider, then each device with a kind icon (AirPods by model, Beats,
    keyboard, magicmouse, trackpad, gamecontroller), status line, % and a battery glyph (green when charging, red when
    low). An empty-state line shows when no device reports a level.
  - VoiceOver labels on the composite rows.
- **`SystemSettingsView`** has three sections: Menu bar (readout picker), Panel ("Show each CPU cluster",
  "Refresh every 1/2/5 seconds") and Sensors (a note on where the numbers come from; no permissions).
- **`SystemReadoutItem`** is its own `NSStatusItem` (variable length, monospaced digits), shown only while the
  feature runs and the readout isn't Off. Clicking it opens a menu: the current numbers, Hide Readout, and System
  Settings… (`context.openSettings(.feature(.system))`).
- **`SystemFeature`**:
  - `init` is cheap: it builds settings and the monitor and reads nothing.
  - `start()` subscribes to `$menuBarReadout` (show/hide/update the readout and the monitor's plan) and
    `$sampleInterval`.
  - `stop()` drops the subscriptions, removes the status item and calls `monitor.stopAll()`. Both are idempotent.
  - `panelDidAppear` only samples while the feature is running.
  - `snapshotViews()` uses `SystemMonitor.fixture` (never samples) and `SystemFixtures.readings()`: an M5 Max with
    18 cores in Super/Performance, 41.5 of 128 GB, 53/50/53 °C, AirPods Pro L/R/Case, Magic Mouse and MX Keys S at a
    low 10 %. Settings sit on a throwaway absolute-path defaults suite in the temp folder.

## Sensor names found on this Mac (M5 Max, macOS 26.5; read-only probes)
- **IOHID** (PrimaryUsagePage 0xff00, PrimaryUsage 5): 77 services.
  - "PMU tdie1"…"PMU tdie14", each ×3 (~53 °C idle): these are the SoC die.
  - "PMU tdev1"…"PMU tdev8" ×3 read **−9201**, i.e. garbage; dropped by plausibility and not classified.
  - "PMU tcal" ×3 holds steady at 51.82, a calibration reference; ignored.
  - Also "NAND CH0 temp" (38) and "gas gauge battery" ×6 (33); both ignored.
  - There are **no** pACC/eACC/GPU MTR sensors any more.
- **SMC** (3,668 keys): 23 × "Tp??" `flt ` (~53 °C → CPU) and 84 × "Tg??" `flt ` (~50 °C → GPU). There are many
  others (Tm, TV, TD, Ts, TR, TU, TPD, TC…) whose meaning is unknown; they are ignored. "TG0B" etc. here are `ioft`
  values, not temperatures.
- **Live check** (a throwaway executable built from copies of the sampler sources, nothing launched as an app):
  - layout Super=6 / Performance=12, "Apple M5 Max", 40 GPU cores
  - 107 SMC temperature keys, CPU 76 °C / GPU 63 °C / SoC 62 °C under the other agents' build load
  - memory 63 of 128 GB, Normal
  - batteries: This Mac 92 % "Charging · 53 m to full", **Kevo's AirPods 100 % with L 100 / R 100 / Case 35** and
    **MX KEYS S 10 % "Low battery"**

  So Bluetooth accessories *are* visible, through the IOPS accessory list rather than IORegistry (the hardware note
  says IORegistry has none, which is also true).
- **Cost per tick on the sampling queue**: temperatures ~2 ms CPU (~43 ms wall: the HID event copies wait on the
  sensors), CPU/GPU/memory/uptime < 0.2 ms together, batteries ~1.2 ms CPU every 10 s. SMC discovery costs ~48 ms CPU
  (0.5 s wall) once per process.

## TDD evidence
Every core unit followed RED (compile failure: the symbol didn't exist yet) → implement → GREEN. Each RED/GREEN used
`swift test --filter SystemTests`:

| Unit | RED (error counts) | GREEN |
|---|---|---|
| CPU load | `cannot find 'CPULoad'` ×12, `'CPUTicks'` ×14 | 2 tests in 1 suite passed |
| Clusters | `cannot find 'ClusterLayout'` ×8, `'ClusterLoad'` ×2 | 3 tests passed |
| History | `cannot find 'SampleHistory'` ×8 | 4 tests passed |
| Memory + format | `'MemoryPressure'` ×12, `'MemoryStats'` ×6, `'SystemFormat'` ×24 | 6 tests passed |
| Sensors + SMC | `'SensorGroups'` ×70, `'SensorReading'` ×32, `'SMCCode'` ×20, `'SensorGroupStats'` ×8, `'SensorKind'` ×2 | 9 tests passed |
| Uptime | `cannot find 'UptimeFormatter'` ×20 | 10 tests passed |
| Batteries | `cannot find 'BatteryParser'` ×30, `'BatteryReading'` ×6 | 12 tests passed (after one compile fix in my own parser) |
| Settings + readout | `'MenuBarReadout'` ×26, `'SystemSettings'` ×20 | 14 tests passed |
| Sampling plan | `cannot find 'SamplingPlan'` ×32 | 15 tests passed |
| Readings | `'SystemSample'` ×8, `'SystemReadings'` ×2 | 16 tests passed |
| Heat levels | `cannot find 'HeatLevel'` ×14 | 17 tests passed |
| Sparkline scale | `cannot find 'SparklineScale'` ×12 | 18 tests passed |

Final full runs: `✔ Test run with 579 tests in 26 suites passed`.

The brief's test names are all present: `cpuLoadFromTicks`, `cpuLoadZeroDeltaIsZero`, `clustersSplitByPerfLevel`
(renamed per the ruling: one Super/Performance case, one Performance/Efficiency case), `historyCapsAndOrders`,
`memoryUsedAndPressure`, `sensorClassification`, `sensorIgnoresImplausible`, `batteryParsesInternal`,
`batteryParsesBluetoothAndDedupes`, `uptimeStrings`, `settingsRoundTrip`. Extras: `systemFormatting`, `smcDecoding`,
`heatLevels`, `menuBarReadoutText`, `samplingPlan`, `readingsApplySamples`, `sparklineCeiling`.

**Test gate:** the existing ffmpeg `VideoToolTests` failed intermittently during full runs. The causes were "The
hardware encoder may be busy" (-12903) and a timing tolerance in `trimMKVStaysMKV` (0.17 vs 0.15), because the other
worktrees saturate the encoder and CPUs. When VideoToolTests was the *only* failing suite, my commit script re-ran each
failing test on its own, up to 3 times, and committed only if it passed. This happened for 9d23ec5, c30fc1c and d1bf8e9
(every re-run passed on the first try). My diff never touches that code. `trimMKVStaysMKV` passed 3/3 alone when
checked by hand.

## Snapshots checked (light and dark, looked at each)
In `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/system/`:
- `final-panel-light.png`, `final-panel-dark.png`, `final-settings-light.png`, `final-settings-dark.png`: the
  finished tab and page.
- Iterations: `panel-v1-light.png` / `panel-v1-dark.png`, `panel-v2-light.png` and `panel-v3-dark.png`.
  - v1 had flat sparklines on the floor, which led to the auto-scale.
  - v3's memory subtitle truncated at half width, so it was reverted.
- `panel-empty-state.png`: before the first sample (rendered with a temporary fixture change, reverted before
  committing).
- `gallery-light.png`: the shell's reference.

## [builder's call]
1. **Cluster core order.** CPU indices go from the last perf level backwards (slowest-first kernel numbering). The
   evidence is the M5 Max device tree (cpu12–17 = cluster-type P, 6 CPUs = perflevel0 "Super") and known M1
   numbering. The ruling's "groups cores in that order" read literally would put the Super label on the Performance
   cores. A single-thread spin test was inconclusive because every core sat at 100 % under the other agents' load.
2. **SMC as a second temperature source.** IOHID on the M5 Max has no CPU-cluster or GPU sensors, so GPU temperature
   (and true CPU die sensors) come from the SMC's "Tg??"/"Tp??" float keys. It uses public IOKit calls, read
   commands only, behind a struct-layout check; IOHID still supplies the SoC die. Classification:
   - `Tp`/`Te`, pACC/eACC and Intel `TC0P/D/E/F/H`, `TCnC` → CPU
   - `Tg`, `GPU*` and Intel `TG0P/D/H` → GPU
   - `PMU tdie*`, `SOC*`, `ANE*`, `ISP*` and Intel `TPCD` → SoC
   - `PMU tcal`, `PMU tdev*`, NAND, battery and unknown names → ignored

   This deviates from the brief's "PMU tdie* = CPU" because the dedicated CPU sensors exist.
3. **Batteries from `IOPSCopyPowerSourcesByType(kIOPSSourceAll = 0)`** (private, via `PrivateSymbol`). On this
   macOS, 0 = all, 1 = internal, 3 = internal + UPS, 4 = accessories. It falls back to the public list. AirPods'
   case folds into the AirPods row as a part.
4. **Menu bar readout**: options Off (default), CPU load, Temperature, CPU load and temperature. The text is "CPU
   23%" / "53°C" / "7% · 54°C". Its temperature is the CPU average (SoC fallback). Clicking it opens a small menu
   (numbers, Hide Readout, System Settings…).
5. **When the readout alone is on, only its metrics are sampled** (CPU and/or temperature), every 2 s. The tab
   samples everything at `sampleInterval`. Batteries are re-read at most every 10 s, even while the tab is open.
6. **Sparklines restart after a gap** of more than 3 missed samples (tab closed, sleep), and the CPU baseline resets
   at the same time. History lives in memory only.
7. **Sparkline scale**: top = peak × 1.25, clamped to 50–100 %, so an idle Mac doesn't draw a flat line at the bottom.
8. **Uptime** uses `kern.boottime` (wall clock, sleep included, like `uptime`), with "since <weekday time>" (or a date
   after a week).
9. **Used memory = active + wired + compressed** (the brief's formula). Pressure colours: accent / orange / red.
10. **Heat colours**: below 80 °C accent, 80–95 °C orange, 95 °C and above red.
11. **Settings page**: added a "Refresh every 1/2/5 seconds" picker for `sampleInterval` and a short Sensors note.
12. **Chip name and GPU core count** are read once, when the tab first shows (never in `init`).
13. **Battery naming**: the internal battery is "This Mac". Low = at or below the device's own "Low Warn Level"
    (20 % default) and not charging.

## Needs hardware verification (I could not launch the app; Kevo's Orbit was running)
- The readout status item: its look in the menu bar, the click menu, Hide Readout, and that it disappears when System
  is turned off.
- Live panel behaviour: tab open → numbers start (CPU after 0.5 s; temperatures after ~0.5 s on the very first open
  for SMC discovery); tab closed → sampling stops (no engine); readout on → 2 s updates continue with the panel
  closed.
- The cluster mapping on an idle machine. Run something single-threaded and heavy, then check the Super row rises
  first.
- A Magic Mouse/Keyboard/Trackpad (IORegistry path) deduplicating against its IOPS accessory entry: the name-based
  cross-source match is heuristic.
- On-battery strings ("3 h 20 m left") and charging AirPods with different L/R levels.
- Intel Macs: SMC `sp78` decoding and the Intel key classification are tested as pure code, never on hardware.

## Known gaps
- No GPU-specific temperature without the SMC (on the M5 Max IOHID has none). If the SMC refuses, CPU and GPU show
  "no sensor" and SoC still reads.
- Accessories that macOS reports through neither IOPS nor IORegistry (some third-party Bluetooth devices) don't show.
- The core-bar row of a 12-core cluster is ~100 pt wide. A chip with many more cores in one cluster would crowd it
  (it doesn't wrap).
- Snapshot fidelity caveats from the shell apply: the settings toggle draws inactive, and glass renders flat.

## Shell changes
None.

## Housekeeping
- No `~/Library/Preferences` plist was created by my runs: the only files changed there during the session are macOS
  daemon plists. Tests use `Fixtures.defaults()` (absolute-path suites in temp folders). The snapshot fixture uses an
  absolute-path suite in the temp folder and writes nothing (0 `orbit-system-fixture*` files there).
- Scratch probes (sensor, SMC, power-source, SF Symbol listing, sampler check) and logs are in
  `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/`.
  All are read-only and nothing is committed.
