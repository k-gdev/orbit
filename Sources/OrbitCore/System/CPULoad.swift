import Foundation

/// One logical CPU's cumulative tick counters, as `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`
/// reports them (`CPU_STATE_USER`, `_SYSTEM`, `_IDLE`, `_NICE`). The counters only grow, and wrap
/// past `UInt32.max`.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// CPU load between two tick snapshots: per logical CPU and in total, each 0...1.
public struct CPULoad: Equatable, Sendable {
    /// Busy ticks over all ticks, summed over every core (so a busier-ticking core weighs more).
    public var total: Double
    /// Each logical CPU's load, in `host_processor_info` order.
    public var perCore: [Double]

    public init(total: Double, perCore: [Double]) {
        self.total = total
        self.perCore = perCore
    }

    /// The load between `previous` and `current`. Cores missing from either snapshot are left out;
    /// a core whose counters did not move reads 0. Counter wrap-around is handled.
    public init(previous: [CPUTicks], current: [CPUTicks]) {
        var perCore: [Double] = []
        var busySum: UInt64 = 0
        var allSum: UInt64 = 0
        for (old, new) in zip(previous, current) {
            let busy = UInt64(new.user &- old.user) + UInt64(new.system &- old.system) + UInt64(new.nice &- old.nice)
            let all = busy + UInt64(new.idle &- old.idle)
            perCore.append(all == 0 ? 0 : Double(busy) / Double(all))
            busySum += busy
            allSum += all
        }
        self.init(total: allSum == 0 ? 0 : Double(busySum) / Double(allSum), perCore: perCore)
    }
}
