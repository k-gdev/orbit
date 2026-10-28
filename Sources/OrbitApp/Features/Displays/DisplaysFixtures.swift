import CoreGraphics
import Foundation
import OrbitCore

/// Snapshot data shaped like Kevo's desk (plus the MacBook's own panel, which is closed tonight): the two
/// ThinkVision P27u-20 replying "150 of 100" over DDC, the AOC at 100 of 100, and the Acer that doesn't
/// answer DDC and is dimmed in software. No hardware is touched; settings live in a throwaway suite.
///
/// `ORBIT_DISPLAYS_SNAPSHOT=busy` in the environment of `Orbit --snapshot-panel displays` draws the busy
/// variant instead: a "Keep this resolution?" pending on the AOC (inline row, plus the floating card under the
/// tiles so its look can be checked) and the BetterDisplay hint. Only the snapshot CLI reads it.
@MainActor
enum DisplaysFixtures {
    static var isBusyVariant: Bool { ProcessInfo.processInfo.environment["ORBIT_DISPLAYS_SNAPSHOT"] == "busy" }

    static func model() -> DisplaysModel {
        let settings = DisplaySettings(defaults: SnapshotFixtures.defaults())
        settings.lastSoftwareDim = ["fixture-acer": 80]
        settings.learn(maximum: 150, reported: 100, for: "fixture-tv-left")
        guard isBusyVariant else { return DisplaysModel(settings: settings, driver: nil, tiles: tiles) }
        let aoc = qhdModes(current: 240, rates: [240, 144, 120, 60])
        let previous = aoc.current?.mode ?? RawDisplayMode(id: 0, width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 240)
        let proposed = RawDisplayMode(id: 1, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        let pending = ResolutionConfirmation(displayID: 3, displayTitle: "Q27G4ZD", previous: previous, proposed: proposed,
                                             proposedLabel: "1920 × 1080", startedAt: Date().addingTimeInterval(-3))
        return DisplaysModel(settings: settings, driver: nil, tiles: tiles, confirmation: pending,
                             conflictHint: DisplayConflicts.hint(runningBundleIDs: ["pro.betterdisplay.BetterDisplay"]))
    }

    static let tiles: [DisplaysModel.Tile] = [
        .init(id: 1, key: "fixture-builtin", title: "MacBook Pro", isBuiltIn: true, control: .native(builtIn: true),
              reading: nil, brightness: 72, modes: builtInModes),
        .init(id: 5, key: "fixture-acer", title: "K272HUL", isBuiltIn: false, control: .software,
              reading: nil, brightness: 80, modes: qhdModes(current: 60, rates: [75, 60])),
        .init(id: 3, key: "fixture-aoc", title: "Q27G4ZD", isBuiltIn: false, control: .ddc,
              reading: VCPValue(current: 100, maximum: 100), brightness: 100, modes: qhdModes(current: 240, rates: [240, 144, 120, 60])),
        .init(id: 2, key: "fixture-tv-left", title: "P27u-20 · Left", isBuiltIn: false, control: .ddc,
              reading: VCPValue(current: 150, maximum: 100), brightness: 120, modes: fourKModes),
        .init(id: 4, key: "fixture-tv-right", title: "P27u-20 · Right", isBuiltIn: false, control: .ddc,
              reading: VCPValue(current: 150, maximum: 100), brightness: 90, modes: fourKModes),
    ]

    /// A 4K panel: HiDPI sizes up to 3008 × 1692 (current, as on Kevo's ThinkVisions) plus 1:1 modes.
    static var fourKModes: DisplayModeList {
        var modes: [RawDisplayMode] = []
        var id: Int32 = 0
        func add(_ w: Int, _ h: Int, hiDPI: Bool, rates: [Double] = [60, 30, 25], flags: UInt32 = 0x3) {
            for rate in rates {
                id += 1
                modes.append(RawDisplayMode(id: id, width: w, height: h, pixelWidth: hiDPI ? w * 2 : w, pixelHeight: hiDPI ? h * 2 : h,
                                            refreshRate: rate, ioFlags: flags))
            }
        }
        for (w, h) in [(3360, 1890), (3200, 1800), (3008, 1692), (2560, 1440), (2304, 1296), (1920, 1080), (1600, 900), (1280, 720)] {
            add(w, h, hiDPI: true)
        }
        add(3840, 2160, hiDPI: false, flags: 0x0200_0003)
        for (w, h) in [(3008, 1692), (2560, 1440), (1920, 1080)] { add(w, h, hiDPI: false) }
        let current = modes.first { $0.width == 3008 && $0.isHiDPI && $0.refreshRate == 60 }
        return DisplayModeList(modes: modes, current: current)
    }

    static func qhdModes(current rate: Double, rates: [Double]) -> DisplayModeList {
        var modes: [RawDisplayMode] = []
        var id: Int32 = 100
        for (w, h, hiDPI) in [(2560, 1440, false), (1920, 1080, false), (1280, 720, true), (1280, 720, false), (1024, 768, false)] {
            for r in (w == 2560 ? rates : [60]) {
                id += 1
                modes.append(RawDisplayMode(id: id, width: w, height: h, pixelWidth: hiDPI ? w * 2 : w, pixelHeight: hiDPI ? h * 2 : h,
                                            refreshRate: r, ioFlags: w == 2560 ? 0x0200_0003 : 0x3))
            }
        }
        return DisplayModeList(modes: modes, current: modes.first { $0.width == 2560 && $0.refreshRate == rate })
    }

    static var builtInModes: DisplayModeList {
        let sizes = [(2056, 1329), (1728, 1117), (1496, 967), (1312, 848)]
        let modes = sizes.enumerated().map { i, size in
            RawDisplayMode(id: Int32(200 + i), width: size.0, height: size.1, pixelWidth: size.0 * 2, pixelHeight: size.1 * 2, refreshRate: 120)
        }
        return DisplayModeList(modes: modes, current: modes[1])
    }
}
