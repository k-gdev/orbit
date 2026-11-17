import Combine
import Foundation

/// A number the System feature can measure. The sampler measures only the ones the current
/// `SamplingPlan` asks for.
public enum SystemMetric: String, CaseIterable, Sendable {
    case cpu, gpu, memory, temperature, batteries, uptime
}

/// What Orbit shows in the menu bar beside its icon while the System feature is on.
public enum MenuBarReadout: String, CaseIterable, Sendable {
    case off, cpu, temperature, cpuAndTemperature

    public var title: String {
        switch self {
        case .off: "Off"
        case .cpu: "CPU load"
        case .temperature: "Temperature"
        case .cpuAndTemperature: "CPU load and temperature"
        }
    }

    /// What has to be sampled to show it.
    public var metrics: Set<SystemMetric> {
        switch self {
        case .off: []
        case .cpu: [.cpu]
        case .temperature: [.temperature]
        case .cpuAndTemperature: [.cpu, .temperature]
        }
    }

    /// The status item's text: "CPU 23%", "53°C", "7% · 54°C"; a dash for a value not read yet; nil when off.
    /// `cpu` is the 0...1 total load, `celsius` the headline temperature (`SensorGroups.headline`).
    public func text(cpu: Double?, celsius: Double?) -> String? {
        let load = cpu.map(SystemFormat.percent) ?? "—"
        let degrees = celsius.flatMap { $0.isFinite ? "\(Int($0.rounded()))" : nil } ?? "—"
        switch self {
        case .off: return nil
        case .cpu: return "CPU \(load)"
        case .temperature: return "\(degrees)°C"
        case .cpuAndTemperature: return "\(load) · \(degrees)°C"
        }
    }
}

/// The System feature's persisted settings (`system.` keys).
public final class SystemSettings: ObservableObject {
    /// How often the panel may refresh, in seconds.
    public static let intervalRange: ClosedRange<TimeInterval> = 0.5...10
    /// The intervals Settings offers.
    public static let intervalChoices: [TimeInterval] = [1, 2, 5]

    private let defaults: UserDefaults

    private enum Key {
        static let menuBarReadout = "system.menuBarReadout"
        static let sampleInterval = "system.sampleInterval"
        static let showPerCluster = "system.showPerCluster"
    }

    /// The optional menu bar readout (off by default; while on it samples every 2 s).
    @Published public var menuBarReadout: MenuBarReadout {
        didSet { defaults.set(menuBarReadout.rawValue, forKey: Key.menuBarReadout) }
    }

    /// How often the System tab refreshes while it is visible (1 s by default).
    @Published public var sampleInterval: TimeInterval {
        didSet { defaults.set(sampleInterval, forKey: Key.sampleInterval) }
    }

    /// Whether the CPU tile shows each cluster ("Super", "Performance") under the total.
    @Published public var showPerCluster: Bool {
        didSet { defaults.set(showPerCluster, forKey: Key.showPerCluster) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarReadout = defaults.string(forKey: Key.menuBarReadout).flatMap(MenuBarReadout.init(rawValue:)) ?? .off
        let interval = defaults.object(forKey: Key.sampleInterval) as? Double ?? 1
        sampleInterval = min(max(interval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
        showPerCluster = defaults.object(forKey: Key.showPerCluster) as? Bool ?? true
    }
}
