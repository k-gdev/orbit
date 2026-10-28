import Foundation
import Testing
@testable import OrbitCore

/// The System feature's pure logic: CPU load and clusters, sparkline history, memory, temperature
/// sensors, batteries, uptime, settings and when sampling runs.
@Suite struct SystemTests {
    // MARK: CPU

    @Test func cpuLoadFromTicks() {
        let before = [CPUTicks(user: 100, system: 50, idle: 800, nice: 50),
                      CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        // Core 0: 60 busy of 100; core 1: 10 busy of 40.
        let after = [CPUTicks(user: 140, system: 60, idle: 840, nice: 60),
                     CPUTicks(user: 5, system: 5, idle: 1030, nice: 0)]
        let load = CPULoad(previous: before, current: after)
        #expect(load.perCore.count == 2)
        #expect(abs(load.perCore[0] - 0.6) < 1e-9)
        #expect(abs(load.perCore[1] - 0.25) < 1e-9)
        // Total weights every tick on every core: 70 busy of 140.
        #expect(abs(load.total - 0.5) < 1e-9)

        // Counters that wrapped past UInt32.max still give the right delta.
        let wrapped = CPULoad(previous: [CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)],
                              current: [CPUTicks(user: 10, system: 0, idle: 20, nice: 0)])
        #expect(abs(wrapped.total - 0.5) < 1e-9)

        // A core count that changed between snapshots compares only the cores both have.
        let shrunk = CPULoad(previous: before, current: Array(after.prefix(1)))
        #expect(shrunk.perCore.count == 1)
    }

    @Test func cpuLoadZeroDeltaIsZero() {
        let ticks = [CPUTicks(user: 10, system: 10, idle: 10, nice: 10)]
        let load = CPULoad(previous: ticks, current: ticks)
        #expect(load.total == 0)
        #expect(load.perCore == [0])
        #expect(CPULoad(previous: [], current: []).total == 0)
        #expect(CPULoad(previous: [], current: []).perCore.isEmpty)
    }
}
