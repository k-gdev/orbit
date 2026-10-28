import Foundation

/// When the System feature samples and what: only while the System tab is visible (everything, at the
/// panel interval) or while the menu bar readout is on (just what it shows, every 2 s). Otherwise
/// nothing runs: no timer, no sensor client, no SMC connection.
public struct SamplingPlan: Equatable, Sendable {
    public var interval: TimeInterval
    public var metrics: Set<SystemMetric>

    public init(interval: TimeInterval, metrics: Set<SystemMetric>) {
        self.interval = interval
        self.metrics = metrics
    }

    /// The menu bar readout's refresh interval.
    public static let readoutInterval: TimeInterval = 2
    /// The fastest batteries are re-read (they change slowly and the queries go through powerd).
    public static let batteryRefresh: TimeInterval = 10

    /// The plan for the current state, or nil when nothing should run.
    public static func make(panelVisible: Bool, readout: MenuBarReadout, panelInterval: TimeInterval) -> SamplingPlan? {
        if panelVisible {
            let range = SystemSettings.intervalRange
            return SamplingPlan(interval: min(max(panelInterval, range.lowerBound), range.upperBound),
                                metrics: Set(SystemMetric.allCases))
        }
        guard readout != .off else { return nil }
        return SamplingPlan(interval: readoutInterval, metrics: readout.metrics)
    }

    /// Whether batteries should be re-read now.
    public static func isBatteryRefreshDue(lastRefresh: Date?, now: Date) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= batteryRefresh
    }

    /// Whether more than three samples were missed since `since` (the panel was closed, the Mac slept), so
    /// a sparkline should start over rather than join across the gap.
    public static func isGap(since: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) > 3 * interval
    }
}
