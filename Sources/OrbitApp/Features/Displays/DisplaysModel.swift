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

    let confirmWindow = ResolutionConfirmWindow()

    func apply(_ mode: RawDisplayMode, to id: CGDirectDisplayID, permanently: Bool) -> Bool {
        DisplayModeService.apply(mode, to: id, permanently: permanently)
    }

    /// Puts every display back to its saved (permanent) configuration: the last resort for a revert.
    func restorePermanentConfiguration() { CGRestorePermanentDisplayConfiguration() }

    func modes(for id: CGDirectDisplayID) -> DisplayModeList { DisplayModeService.list(for: id) }

    func stop() {
        ddc.invalidate()
        gamma.restoreAll()
        confirmWindow.close()
    }
}

/// The Displays tab's state: one tile per display with how its brightness is driven, its value and its
/// resolution menu. How a tile is driven follows `DisplayControlPolicy` (OrbitCore, tested): DDC monitors keep
/// DDC through missed replies and are re-scanned, silent ones are asked three times with backoff before they
/// fall back to software dimming, and wake / display changes ask again. Brightness changes are previewed in
/// the tile at once and written at most every 80 ms while a drag lasts (`writeInterval`), then once more
/// when it ends.
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
    /// DDC history per display key for this run (`hasAnswered` is seeded from `settings.answeredDDC`).
    private var probeStates: [String: DDCProbeState] = [:]
    /// The last catalog scan, for building DDC targets on retries.
    private var infos: [DisplayInfo] = []
    private var rescanDDC = true
    private var retries: [CGDirectDisplayID: DispatchWorkItem] = [:]
    /// Values when the current linked drag began.
    private var linkBaseline: [CGDirectDisplayID: Double]?
    private var pendingWrites: [CGDirectDisplayID: (value: Double, control: BrightnessControl, key: String)] = [:]
    private var writeTimer: DispatchWorkItem?
    /// Bumped on every user change, so a DDC reading that was in flight doesn't undo it.
    private var edits: [CGDirectDisplayID: Int] = [:]
    private var learner = BoostLearner()
    private var cancellables: Set<AnyCancellable> = []

    /// A model without a driver that lists the connected displays (catalog only) for Settings while the
    /// feature is off. Fixture models leave it false and never look at the hardware.
    private let readsCatalogWhenIdle: Bool

    /// "BetterDisplay is also running…" while another app that drives these monitors runs (`DisplayConflicts`).
    @Published private(set) var conflictHint: String?

    /// `confirmation` and `conflictHint` are for fixtures (snapshots).
    init(settings: DisplaySettings, driver: DisplaysDriver?, tiles: [Tile] = [], readsCatalogWhenIdle: Bool = false,
         confirmation: ResolutionConfirmation? = nil, conflictHint: String? = nil) {
        self.settings = settings
        self.driver = driver
        self.tiles = tiles
        self.readsCatalogWhenIdle = readsCatalogWhenIdle
        self.confirmation = confirmation
        self.conflictHint = conflictHint
        self.hasScanned = !tiles.isEmpty || driver == nil
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        settings.$useGammaFallback.dropFirst().removeDuplicates().sink { [weak self] on in
            // `$` publishes before the property changes; act once it has.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.gammaFallbackChanged(on) } }
        }.store(in: &cancellables)
        driver?.ddc.onWriteFailure = { [weak self] id in self?.ddcWriteFailed(id) }
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

    private func probeState(for key: String) -> DDCProbeState {
        probeStates[key] ?? DDCProbeState(hasAnswered: settings.answeredDDC.contains(key))
    }

    /// Re-reads the display list, built-in brightness and (in the background) each external monitor's DDC
    /// brightness. Called when the tab appears and after display changes or wake.
    func refresh() {
        guard let driver else { return }
        infos = driver.scan()
        var next: [Tile] = []
        var toRead: Set<CGDirectDisplayID> = []
        for info in infos {
            let old = tiles.first { $0.id == info.id && $0.key == info.key }
            var tile = Tile(id: info.id, key: info.key, title: info.title, isBuiltIn: info.isBuiltIn, control: .probing,
                            reading: old?.reading, brightness: old?.brightness ?? 100, modes: info.modes)
            if let native = driver.nativeBrightness(info.id) {
                tile.control = .native(builtIn: info.isBuiltIn)
                tile.brightness = native
            } else {
                let start = DisplayControlPolicy.start(state: probeState(for: info.key), ddcSupported: DDCService.isSupported,
                                                       asleep: info.isAsleep, gammaFallback: settings.useGammaFallback)
                tile.control = start.control
                if tile.control == .software || tile.control == .unavailable {
                    tile.brightness = driver.gamma.dims[info.id] ?? savedSoftwareDim(for: info.key) ?? 100
                }
                if start.probe { toRead.insert(info.id) }
            }
            next.append(tile)
        }
        tiles = next
        hasScanned = true
        conflictHint = DisplayConflicts.hint(runningBundleIDs: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        probe(toRead)
    }

    /// Reads DDC from `ids` (matching every non-native display, re-walking the registry when needed).
    private func probe(_ ids: Set<CGDirectDisplayID>) {
        guard let driver, !ids.isEmpty else { return }
        for id in ids { retries.removeValue(forKey: id)?.cancel() }
        let nonNative = Set(tiles.filter { if case .native = $0.control { return false } else { return true } }.map(\.id))
        let targets = infos.filter { nonNative.contains($0.id) }
            .map { DDCService.Target(id: $0.id, descriptor: $0.descriptor, read: ids.contains($0.id)) }
        guard targets.contains(where: \.read) else { return }
        let started = edits
        let rescan = rescanDDC
        rescanDDC = false
        driver.ddc.probe(targets, rescan: rescan) { [weak self] id, value in
            self?.received(value, for: id, editsAtStart: started[id] ?? 0)
        }
    }

    private func received(_ value: VCPValue?, for id: CGDirectDisplayID, editsAtStart: Int) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let key = tiles[index].key
        let before = probeState(for: key)
        let outcome = DisplayControlPolicy.outcome(of: value, state: before, gammaFallback: settings.useGammaFallback)
        probeStates[key] = outcome.state
        let wasFallback = tiles[index].control == .software || tiles[index].control == .unavailable

        if let value {
            settings.rememberAnsweredDDC(key)
            // Remember a boost range only after two readings in a row above the reported maximum.
            if let learned = learner.observe(value, for: key) {
                settings.learn(maximum: learned, reported: value.maximum, for: key)
            }
            tiles[index].reading = value
        } else if before.hasAnswered {
            Log.info("displays: \(tiles[index].title) missed a DDC reply (\(outcome.state.misses) in a row)")
        }
        if outcome.clearsSoftwareDim { driver?.gamma.restore(id) }
        tiles[index].control = outcome.control
        if outcome.adoptsReading, let value, (edits[id] ?? 0) == editsAtStart {
            tiles[index].brightness = range(for: tiles[index]).clamped(Double(value.current))
        }
        let isFallback = outcome.control == .software || outcome.control == .unavailable
        if isFallback, !wasFallback {
            Log.info("displays: \(tiles[index].title) didn't answer DDC \(DisplayControlPolicy.maxMisses) times; using "
                     + (outcome.control == .software ? "software dimming" : "no brightness control"))
            tiles[index].brightness = savedSoftwareDim(for: key) ?? 100
        }
        if let delay = outcome.retryAfter { scheduleRetry(id, after: delay) }
    }

    private func scheduleRetry(_ id: CGDirectDisplayID, after delay: TimeInterval) {
        retries.removeValue(forKey: id)?.cancel()
        rescanDDC = true
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.probe([id]) } }
        retries[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A DDC write was refused (the service went stale, e.g. after sleep): re-scan and ask the display again.
    private func ddcWriteFailed(_ id: CGDirectDisplayID) {
        guard tiles.contains(where: { $0.id == id && $0.control == .ddc }) else { return }
        scheduleRetry(id, after: DisplayControlPolicy.retryDelays.first ?? 1)
    }

    /// The saved software-dimming level for `key`, if it may be used (never for a display that answered DDC).
    private func savedSoftwareDim(for key: String) -> Double? {
        DisplayControlPolicy.persistsSoftwareDim(probeState(for: key)) ? settings.lastSoftwareDim[key] : nil
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

    /// The display set changed (connected, disconnected, rearranged, mode switched): macOS may have reset
    /// gamma tables, and the DDC services may have moved.
    func displaysChanged(refreshTiles: Bool) {
        startOver()
        applySavedSoftwareDims()
        driver?.confirmWindow.reposition()   // the changed display may have a new size
        if refreshTiles { refresh() }
    }

    /// The Mac or its screens woke: the DCP may have rebuilt its DDC services, gamma may have been reset, and
    /// displays that gave up on DDC are asked again.
    func systemWoke(refreshTiles: Bool) {
        startOver()
        if refreshTiles { refresh() }
    }

    private func startOver() {
        for work in retries.values { work.cancel() }
        retries.removeAll()
        probeStates = probeStates.mapValues(DisplayControlPolicy.afterWake)
        rescanDDC = true
        driver?.ddc.invalidate()
        driver?.gamma.reapply()
    }

    /// Re-applies the software dimming saved for connected displays (at start and after display changes),
    /// never for displays that have answered DDC.
    func applySavedSoftwareDims() {
        guard let driver, settings.useGammaFallback, !settings.lastSoftwareDim.isEmpty else { return }
        for info in driver.scan() where driver.nativeBrightness(info.id) == nil {
            if let level = savedSoftwareDim(for: info.key), SoftwareDim.dims(level), driver.gamma.dims[info.id] != level {
                driver.gamma.set(level, for: info.id, key: info.key)
            }
        }
    }

    private func gammaFallbackChanged(_ on: Bool) {
        if on {
            for index in tiles.indices where tiles[index].control == .unavailable {
                tiles[index].control = .software
                tiles[index].brightness = savedSoftwareDim(for: tiles[index].key) ?? 100
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

    /// A drag ended or a scroll burst settled: write now and remember software-dimming levels (only for
    /// displays that never answered DDC; a DDC monitor dimmed in software while it misses replies isn't saved).
    func endEditing() {
        linkBaseline = nil
        flushWrites()
        for tile in tiles where tile.control == .software {
            guard DisplayControlPolicy.persistsSoftwareDim(probeState(for: tile.key)) else {
                settings.lastSoftwareDim[tile.key] = nil
                continue
            }
            settings.lastSoftwareDim[tile.key] = SoftwareDim.dims(tile.brightness) ? tile.brightness : nil
        }
    }

    /// Settings → Reset learned range: forget the remembered boost range (the latest reading still counts
    /// for this session; it's learned again only after two readings in a row above the reported maximum).
    func resetLearnedRange(for key: String) {
        settings.forgetLearnedMaximum(for: key)
        learner.forget(key)
    }

    func setLinked(_ on: Bool) {
        settings.linkBrightness = on
        linkBaseline = nil
    }

    // MARK: Resolution

    /// A resolution change waiting for Keep / Revert (applied for this session only meanwhile).
    @Published private(set) var confirmation: ResolutionConfirmation?
    private var confirmationTimer: DispatchWorkItem?

    /// Switches `id` to `entry` for this session only and asks "Keep this resolution?" for 15 s; Keep makes it
    /// permanent, Revert or no answer goes back. A change still waiting is reverted first.
    func select(_ entry: DisplayModeEntry, for id: CGDirectDisplayID) {
        guard !entry.isCurrent, let driver, let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        if confirmation != nil { revertResolution() }
        guard let previous = driver.modes(for: id).current?.mode ?? tiles[index].modes.current?.mode else {
            Log.info("displays: not switching \(tiles[index].title): its current mode is unknown, so it couldn't be reverted")
            return
        }
        guard driver.apply(entry.mode, to: id, permanently: false) else { return }
        let pending = ResolutionConfirmation(displayID: id, displayTitle: tiles[index].title, previous: previous, proposed: entry.mode,
                                             proposedLabel: entry.label, startedAt: Date())
        confirmation = pending
        refreshModes(id)
        driver.confirmWindow.show(model: self, on: id)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.confirmation == pending else { return }
                Log.info("displays: no answer to Keep this resolution? for \(pending.displayTitle); reverting")
                self.revertResolution()
            }
        }
        confirmationTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ResolutionConfirmation.duration, execute: work)
    }

    /// Keep: the new mode becomes permanent.
    func keepResolution() {
        guard let pending = endConfirmation() else { return }
        if driver?.apply(pending.proposed, to: pending.displayID, permanently: true) != true {
            Log.info("displays: couldn't save \(pending.proposedLabel) for \(pending.displayTitle) permanently; it stays for this session")
        }
        refreshModes(pending.displayID)
    }

    /// Revert (or the countdown ran out): the previous mode comes back.
    func revertResolution() {
        guard let pending = endConfirmation(), let driver else { return }
        if !driver.apply(pending.previous, to: pending.displayID, permanently: false) {
            Log.info("displays: couldn't switch \(pending.displayTitle) back directly; restoring the saved display configuration")
            driver.restorePermanentConfiguration()
        }
        refreshModes(pending.displayID)
    }

    private func endConfirmation() -> ResolutionConfirmation? {
        confirmationTimer?.cancel()
        confirmationTimer = nil
        driver?.confirmWindow.close()
        defer { confirmation = nil }
        return confirmation
    }

    private func refreshModes(_ id: CGDirectDisplayID) {
        guard let driver, let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[index].modes = driver.modes(for: id)
    }

    // MARK: Lifecycle

    /// The feature stopped (or Orbit quits): revert a resolution change nobody kept, drop queued writes and
    /// retries, give gamma back, release DDC services.
    func stop() {
        if confirmation != nil { revertResolution() }
        writeTimer?.cancel()
        writeTimer = nil
        pendingWrites.removeAll()
        for work in retries.values { work.cancel() }
        retries.removeAll()
        linkBaseline = nil
        driver?.ddc.onWriteFailure = nil
        driver?.stop()
        cancellables.removeAll()
    }
}
