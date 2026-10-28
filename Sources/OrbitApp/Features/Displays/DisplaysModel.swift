import AppKit
import Combine
import CoreGraphics
import OrbitCore

/// The live hardware behind the Displays tab. `DisplaysModel` without one (snapshots) never touches a display.
@MainActor
final class DisplaysDriver {
    let ddc = DDCService()
    let gamma = GammaDimmer()

    func scan() -> [DisplayInfo] { DisplayCatalog.scan() }

    /// DisplayServices brightness (0...100) when it drives `id`, else nil.
    func nativeBrightness(_ id: CGDirectDisplayID) -> Double? {
        BuiltInBrightness.canControl(id) ? BuiltInBrightness.brightness(of: id) : nil
    }

    func write(_ value: Double, control: BrightnessControl, to id: CGDirectDisplayID, key: String) {
        switch control {
        case .native: BuiltInBrightness.setBrightness(value, of: id)
        case .ddc: ddc.write(Int(value.rounded()), to: id)
        case .software: gamma.set(value, for: id, key: key)
        case .probing, .unavailable: break
        }
    }

    func apply(_ mode: RawDisplayMode, to id: CGDirectDisplayID) -> Bool { DisplayModeService.apply(mode, to: id) }

    func modes(for id: CGDirectDisplayID) -> DisplayModeList { DisplayModeService.list(for: id) }

    func stop() {
        ddc.disconnect()
        gamma.restoreAll()
    }
}

/// The Displays tab's state: one tile per display with how its brightness is driven, its value and its
/// resolution menu. Brightness changes are previewed in the tile at once and written at most every 80 ms
/// while a drag lasts (`writeInterval`), then once more when it ends.
@MainActor
final class DisplaysModel: ObservableObject {
    struct Tile: Identifiable, Equatable {
        let id: CGDirectDisplayID
        var key: String
        var title: String
        var isBuiltIn: Bool
        var control: BrightnessControl
        /// The last valid DDC reply for VCP 0x10.
        var reading: VCPValue?
        /// In `range(for:)` units: 0...100 for native and software, the DDC range otherwise.
        var brightness: Double
        var modes: DisplayModeList
    }

    @Published private(set) var tiles: [Tile]
    /// False until the first scan finished (the tab shows "Looking for displays…").
    @Published private(set) var hasScanned: Bool
    let settings: DisplaySettings

    static let writeInterval: TimeInterval = 0.08

    private let driver: DisplaysDriver?
    /// Per display key: did it answer DDC since the last display change? nil = not asked yet.
    private var answersDDC: [String: Bool] = [:]
    private var rescanDDC = true
    /// Values when the current linked drag began.
    private var linkBaseline: [CGDirectDisplayID: Double]?
    private var pendingWrites: [CGDirectDisplayID: (value: Double, control: BrightnessControl, key: String)] = [:]
    private var writeTimer: DispatchWorkItem?
    /// Bumped on every user change, so a DDC reading that was in flight doesn't undo it.
    private var edits: [CGDirectDisplayID: Int] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// A model without a driver that lists the connected displays (catalog only) for Settings while the
    /// feature is off. Fixture models leave it false and never look at the hardware.
    private let readsCatalogWhenIdle: Bool

    init(settings: DisplaySettings, driver: DisplaysDriver?, tiles: [Tile] = [], readsCatalogWhenIdle: Bool = false) {
        self.settings = settings
        self.driver = driver
        self.tiles = tiles
        self.readsCatalogWhenIdle = readsCatalogWhenIdle
        self.hasScanned = !tiles.isEmpty || driver == nil
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        settings.$useGammaFallback.dropFirst().removeDuplicates().sink { [weak self] on in
            // `$` publishes before the property changes; act once it has.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.gammaFallbackChanged(on) } }
        }.store(in: &cancellables)
    }

    // MARK: Ranges

    /// The pill's range for `tile`: DDC displays get their reported / learned / overridden range.
    func range(for tile: Tile) -> BrightnessRange {
        guard tile.control == .ddc || (tile.control == .probing && tile.reading != nil) else { return .percent }
        return BrightnessRange(override: settings.maxOverride(for: tile.key), reportedMaximum: tile.reading?.maximum,
                               reportedCurrent: tile.reading?.current, learnedMaximum: settings.learnedMaximums[tile.key])
    }

    func caption(for tile: Tile) -> String { tile.control.caption(range: range(for: tile)) }

    /// The automatic maximum for `tile` (what "Auto" means in Settings), without the override.
    func automaticMaximum(for tile: Tile) -> Int? {
        guard tile.reading != nil || settings.learnedMaximums[tile.key] != nil else { return nil }
        return BrightnessRange(override: nil, reportedMaximum: tile.reading?.maximum, reportedCurrent: tile.reading?.current,
                               learnedMaximum: settings.learnedMaximums[tile.key]).maximum
    }

    // MARK: Scanning

    /// Re-reads the display list, built-in brightness and (in the background) each external monitor's DDC
    /// brightness. Called when the tab appears and after display changes.
    func refresh() {
        guard let driver else { return }
        let infos = driver.scan()
        var next: [Tile] = []
        var targets: [DDCService.Target] = []
        for info in infos {
            let old = tiles.first { $0.id == info.id && $0.key == info.key }
            var tile = Tile(id: info.id, key: info.key, title: info.title, isBuiltIn: info.isBuiltIn, control: .probing,
                            reading: old?.reading, brightness: old?.brightness ?? 100, modes: info.modes)
            if let native = driver.nativeBrightness(info.id) {
                tile.control = .native(builtIn: info.isBuiltIn)
                tile.brightness = native
            } else {
                let known = answersDDC[info.key]
                let ask = DDCService.isSupported && !info.isAsleep && known != false
                if known == true {
                    tile.control = .ddc         // re-read in the background, keep the last value meanwhile
                } else if ask {
                    tile.control = .probing
                } else {
                    tile.control = fallbackControl
                }
                if tile.control == .software || tile.control == .unavailable {
                    tile.brightness = settings.lastSoftwareDim[info.key] ?? 100
                }
                targets.append(DDCService.Target(id: info.id, descriptor: info.descriptor, read: ask))
            }
            next.append(tile)
        }
        tiles = next
        hasScanned = true
        guard targets.contains(where: \.read) else { return }
        let started = edits
        let rescan = rescanDDC
        rescanDDC = false
        driver.ddc.probe(targets, rescan: rescan) { [weak self] id, value in
            self?.received(value, for: id, editsAtStart: started[id] ?? 0)
        }
    }

    /// The Settings page appeared: a full refresh when live; while the feature is off, just the display list
    /// (no DDC, no writes); nothing for fixtures.
    func refreshForSettings() {
        if driver != nil {
            refresh()
        } else if readsCatalogWhenIdle {
            tiles = DisplayCatalog.scan().map { info in
                Tile(id: info.id, key: info.key, title: info.title, isBuiltIn: info.isBuiltIn,
                     control: BuiltInBrightness.canControl(info.id) ? .native(builtIn: info.isBuiltIn) : .probing,
                     reading: nil, brightness: 100, modes: info.modes)
            }
            hasScanned = true
        }
    }

    private var fallbackControl: BrightnessControl { settings.useGammaFallback ? .software : .unavailable }

    private func received(_ value: VCPValue?, for id: CGDirectDisplayID, editsAtStart: Int) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let key = tiles[index].key
        if let value {
            answersDDC[key] = true
            settings.learn(maximum: value.current, reported: value.maximum, for: key)
            if tiles[index].control == .software || settings.lastSoftwareDim[key] != nil {
                // It answers DDC now (DDC/CI turned on in its menu): stop dimming it in software.
                driver?.gamma.restore(id)
                settings.lastSoftwareDim[key] = nil
            }
            tiles[index].control = .ddc
            tiles[index].reading = value
            if (edits[id] ?? 0) == editsAtStart {
                tiles[index].brightness = range(for: tiles[index]).clamped(Double(value.current))
            }
        } else if answersDDC[key] == true {
            tiles[index].control = .ddc   // answered before: a missed reply, keep the last value
        } else {
            answersDDC[key] = false
            Log.info("displays: \(tiles[index].title) didn't answer DDC; using \(fallbackControl == .software ? "software dimming" : "no brightness control")")
            tiles[index].control = fallbackControl
            tiles[index].brightness = settings.lastSoftwareDim[key] ?? 100
        }
    }

    /// The display set changed (connected, disconnected, rearranged, mode switched): macOS may have reset
    /// gamma tables, and the DDC services may have moved.
    func displaysChanged(refreshTiles: Bool) {
        answersDDC = answersDDC.filter { $0.value }   // ask the silent ones again
        rescanDDC = true
        driver?.ddc.invalidate()
        driver?.gamma.reapply()
        applySavedSoftwareDims()
        if refreshTiles { refresh() }
    }

    /// The screens woke: gamma tables may have been reset.
    func screensWoke() {
        driver?.gamma.reapply()
    }

    /// Re-applies the software dimming saved for connected displays (at start and after display changes).
    func applySavedSoftwareDims() {
        guard let driver, settings.useGammaFallback, !settings.lastSoftwareDim.isEmpty else { return }
        for info in driver.scan() where answersDDC[info.key] != true && driver.nativeBrightness(info.id) == nil {
            if let level = settings.lastSoftwareDim[info.key], SoftwareDim.dims(level), driver.gamma.dims[info.id] != level {
                driver.gamma.set(level, for: info.id, key: info.key)
            }
        }
    }

    private func gammaFallbackChanged(_ on: Bool) {
        if on {
            for index in tiles.indices where tiles[index].control == .unavailable {
                tiles[index].control = .software
                tiles[index].brightness = settings.lastSoftwareDim[tiles[index].key] ?? 100
            }
            applySavedSoftwareDims()
        } else {
            driver?.gamma.restoreAll()
            for index in tiles.indices where tiles[index].control == .software { tiles[index].control = .unavailable }
        }
    }

    // MARK: Brightness

    func brightness(of id: CGDirectDisplayID) -> Double { tiles.first { $0.id == id }?.brightness ?? 0 }

    private func isAdjustable(_ tile: Tile) -> Bool {
        switch tile.control {
        case .native, .ddc, .software: true
        case .probing, .unavailable: false
        }
    }

    /// The pill moved: preview at once, write soon. With Link brightness on, every adjustable display moves
    /// proportionally from where it was when this drag began.
    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }), isAdjustable(tiles[index]) else { return }
        let linked = tiles.filter(isAdjustable)
        if settings.linkBrightness, linked.count > 1 {
            let baseline = linkBaseline ?? Dictionary(uniqueKeysWithValues: linked.map { ($0.id, $0.brightness) })
            linkBaseline = baseline
            let members = linked.map { BrightnessLink.Member(id: String($0.id), range: range(for: $0), value: baseline[$0.id] ?? $0.brightness) }
            let values = BrightnessLink.values(changing: String(id), to: value, members: members)
            for i in tiles.indices {
                guard let new = values[String(tiles[i].id)], new != tiles[i].brightness else { continue }
                change(i, to: new)
            }
        } else {
            let new = range(for: tiles[index]).clamped(value.rounded())
            if new != tiles[index].brightness { change(index, to: new) }
        }
    }

    private func change(_ index: Int, to value: Double) {
        let id = tiles[index].id
        tiles[index].brightness = value
        edits[id, default: 0] += 1
        pendingWrites[id] = (value, tiles[index].control, tiles[index].key)
        guard writeTimer == nil else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flushWrites() } }
        writeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeInterval, execute: work)
    }

    private func flushWrites() {
        writeTimer?.cancel()
        writeTimer = nil
        let writes = pendingWrites
        pendingWrites.removeAll()
        for (id, write) in writes { driver?.write(write.value, control: write.control, to: id, key: write.key) }
    }

    /// A drag ended or a scroll burst settled: write now and remember software dimming levels.
    func endEditing() {
        linkBaseline = nil
        flushWrites()
        for tile in tiles where tile.control == .software {
            settings.lastSoftwareDim[tile.key] = SoftwareDim.dims(tile.brightness) ? tile.brightness : nil
        }
    }

    func setLinked(_ on: Bool) {
        settings.linkBrightness = on
        linkBaseline = nil
    }

    // MARK: Resolution

    func select(_ entry: DisplayModeEntry, for id: CGDirectDisplayID) {
        guard !entry.isCurrent, let driver, let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        if driver.apply(entry.mode, to: id) {
            tiles[index].modes = driver.modes(for: id)
        }
    }

    // MARK: Lifecycle

    /// The feature stopped: drop queued writes, give gamma back, release DDC services.
    func stop() {
        writeTimer?.cancel()
        writeTimer = nil
        pendingWrites.removeAll()
        linkBaseline = nil
        driver?.stop()
        cancellables.removeAll()
    }
}
