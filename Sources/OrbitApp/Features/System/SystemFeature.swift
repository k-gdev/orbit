import Combine
import OrbitCore
import SwiftUI

/// System (spec §5.2): CPU per cluster with a sparkline, GPU, memory and pressure, Apple Silicon
/// temperatures, uptime, and batteries (the Mac's and Bluetooth devices'), plus an optional menu bar
/// readout. No permissions.
///
/// Cost: nothing at all while off. While on, sampling runs only while the System tab is visible (every
/// `sampleInterval`) or while the menu bar readout is on (every 2 s, just the readout's numbers); see
/// `SamplingPlan` and `SystemMonitor`.
@MainActor
final class SystemFeature: SuiteFeature {
    let id = FeatureID.system
    private let context: SuiteContext
    private let settings: SystemSettings
    private let monitor: SystemMonitor
    private var readoutItem: SystemReadoutItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var isRunning = false

    init(context: SuiteContext) {
        self.context = context
        settings = SystemSettings(defaults: context.defaults)
        monitor = SystemMonitor(sampleInterval: settings.sampleInterval)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // `@Published` publishes before the property changes, so use the emitted values.
        settings.$menuBarReadout
            .sink { [weak self] readout in self?.applyReadout(readout) }
            .store(in: &subscriptions)
        settings.$sampleInterval
            .sink { [weak self] interval in self?.monitor.setPanelInterval(interval) }
            .store(in: &subscriptions)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        subscriptions.removeAll()
        readoutItem?.remove()
        readoutItem = nil
        monitor.stopAll()
    }

    func panelDidAppear() {
        guard isRunning else { return }
        monitor.setPanelVisible(true)
    }

    func panelDidDisappear() {
        monitor.setPanelVisible(false)
    }

    func makePanelView() -> AnyView { AnyView(SystemPanelView(monitor: monitor, settings: settings)) }

    func makeSettingsView() -> AnyView { AnyView(SystemSettingsView(settings: settings)) }

    static func snapshotViews() -> FeatureSnapshotViews {
        let settings = SystemSettings(defaults: SystemFixtures.throwawayDefaults())
        let monitor = SystemMonitor.fixture(SystemFixtures.readings(), chipName: "Apple M5 Max", gpuCores: 40)
        return FeatureSnapshotViews(panel: SystemPanelView(monitor: monitor, settings: settings),
                                    settings: SystemSettingsView(settings: settings))
    }

    private func applyReadout(_ readout: MenuBarReadout) {
        monitor.setReadout(readout)
        if readout == .off {
            readoutItem?.remove()
            readoutItem = nil
        } else if let readoutItem {
            readoutItem.setReadout(readout)
        } else {
            readoutItem = SystemReadoutItem(readout: readout, monitor: monitor, settings: settings,
                                            openSettings: { [weak self] in self?.context.openSettings(.feature(.system)) })
        }
    }
}

/// Fixture data for `--snapshot-panel system`: an M5 Max mid-afternoon (no hardware is read).
enum SystemFixtures {
    /// A defaults suite at an absolute path in the temp folder (never ~/Library/Preferences). Nothing is
    /// written to it unless a snapshot changes a setting.
    static func throwawayDefaults() -> UserDefaults {
        let path = FileManager.default.temporaryDirectory.appending(path: "orbit-system-fixture-\(UUID().uuidString).plist").path
        guard let defaults = UserDefaults(suiteName: path) else { preconditionFailure("SystemFixtures: no throwaway defaults suite") }
        return defaults
    }

    static func readings() -> SystemReadings {
        // cpu0-11 "Performance", cpu12-17 "Super" (kernel order).
        let performance = [0.22, 0.31, 0.12, 0.18, 0.09, 0.27, 0.15, 0.08, 0.2, 0.11, 0.06, 0.14]
        let superCores = [0.62, 0.48, 0.71, 0.35, 0.55, 0.4]
        let load = CPULoad(total: (performance + superCores).reduce(0, +) / 18, perCore: performance + superCores)
        let layout = ClusterLayout([(name: "Super", logicalCPUs: 6), (name: "Performance", logicalCPUs: 12)])

        var cpuHistory = SampleHistory<Double>()
        var gpuHistory = SampleHistory<Double>()
        for i in 0..<60 {
            let t = Double(i)
            cpuHistory.append(0.2 + 0.1 * sin(t / 4) + 0.06 * sin(t / 1.3) + (i > 44 && i < 50 ? 0.25 : 0))
            gpuHistory.append(0.14 + 0.08 * sin(t / 6 + 1) + 0.04 * sin(t / 1.7))
        }
        cpuHistory.append(load.total)
        gpuHistory.append(0.19)

        let gib: UInt64 = 1 << 30
        let pages = { (bytes: UInt64) in bytes / 16_384 }
        let memory = MemoryStats(pageSize: 16_384, free: pages(11 * gib), active: pages(33 * gib), inactive: pages(52 * gib),
                                 wired: pages(7 * gib), compressed: pages(gib + gib / 2), totalBytes: 128 * gib, pressure: .normal)
        let sensors = SensorGroups(cpu: SensorGroupStats(average: 53.1, maximum: 56.4, count: 23),
                                   gpu: SensorGroupStats(average: 49.7, maximum: 50.4, count: 84),
                                   soc: SensorGroupStats(average: 53.4, maximum: 54.9, count: 42))
        let batteries = [
            BatteryReading(id: "internal", name: "This Mac", kind: .mac, percent: 100, isCharged: true, onPowerAdapter: true),
            BatteryReading(id: "airpods", name: "Kevo’s AirPods Pro", kind: .headphones, percent: 90, isCharging: false,
                           parts: [.init(name: "L", percent: 100), .init(name: "R", percent: 90), .init(name: "Case", percent: 35)]),
            BatteryReading(id: "bt:mouse", name: "Magic Mouse", kind: .mouse, percent: 64),
            BatteryReading(id: "mxkeys", name: "MX KEYS S", kind: .keyboard, percent: 10, lowWarnLevel: 20),
        ]
        return SystemReadings(cpu: load, clusters: layout.clusters(load.perCore), cpuHistory: cpuHistory,
                              gpu: 0.19, gpuHistory: gpuHistory, memory: memory, sensors: sensors,
                              uptime: 3 * 86_400 + 11 * 3600 + 24 * 60, batteries: batteries)
    }
}
