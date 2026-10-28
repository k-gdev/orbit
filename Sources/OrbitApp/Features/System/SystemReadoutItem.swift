import AppKit
import Combine
import OrbitCore

/// The optional menu bar readout ("CPU 23%", "53°C", "7% · 54°C"): its own status item beside Orbit's
/// icon, shown only while the System feature is on and the setting isn't Off. Clicking it opens a small
/// menu (the full numbers, Hide Readout, System Settings…). `remove()` takes the item out of the menu bar.
@MainActor
final class SystemReadoutItem: NSObject {
    private let item: NSStatusItem
    private let monitor: SystemMonitor
    private let settings: SystemSettings
    private let openSettings: () -> Void
    private var readout: MenuBarReadout
    private var subscription: AnyCancellable?

    init(readout: MenuBarReadout, monitor: SystemMonitor, settings: SystemSettings, openSettings: @escaping () -> Void) {
        self.readout = readout
        self.monitor = monitor
        self.settings = settings
        self.openSettings = openSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.toolTip = "Orbit System readout"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        subscription = monitor.$readings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] readings in self?.render(readings) }
    }

    func setReadout(_ readout: MenuBarReadout) {
        self.readout = readout
        render(monitor.readings)
    }

    func remove() {
        subscription = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    private func render(_ readings: SystemReadings) {
        let text = readout.text(cpu: readings.cpu?.total, celsius: readings.sensors?.headline) ?? ""
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
        item.button?.setAccessibilityLabel("System: \(text)")
    }

    @objc private func clicked() {
        let readings = monitor.readings
        let menu = NSMenu()
        menu.autoenablesItems = false
        var lines: [String] = []
        if let cpu = readings.cpu { lines.append("CPU \(SystemFormat.percent(cpu.total))") }
        if let sensors = readings.sensors {
            lines += SensorKind.allCases.compactMap { kind in sensors[kind].map { "\(kind.title) \(SystemFormat.celsius($0.average))" } }
        }
        if lines.isEmpty { lines = ["Reading…"] }
        let summary = NSMenuItem(title: lines.joined(separator: "  ·  "), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Readout", action: #selector(hideReadout), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        let open = NSMenuItem(title: "System Settings…", action: #selector(showSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func hideReadout() { settings.menuBarReadout = .off }

    @objc private func showSettings() { openSettings() }
}
