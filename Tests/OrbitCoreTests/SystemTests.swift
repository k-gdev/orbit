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

    @Test func clustersSplitByPerfLevel() {
        // M5 Max: hw.perflevel0 "Super" (6), hw.perflevel1 "Performance" (12). The kernel numbers the
        // slowest level first: cpu0-11 are the Performance cores, cpu12-17 the Super cores.
        let m5 = ClusterLayout([(name: "Super", logicalCPUs: 6), (name: "Performance", logicalCPUs: 12)])
        #expect(m5.coreCount == 18)
        let perCore = Array(repeating: 0.1, count: 12) + Array(repeating: 0.9, count: 6)
        let clusters = m5.clusters(perCore)
        #expect(clusters.map(\.name) == ["Super", "Performance"])
        #expect(clusters.map(\.cores.count) == [6, 12])
        #expect(abs(clusters[0].average - 0.9) < 1e-9)
        #expect(abs(clusters[1].average - 0.1) < 1e-9)

        // M1: perflevel0 "Performance" (4), perflevel1 "Efficiency" (4); cpu0-3 are Efficiency.
        let m1 = ClusterLayout([(name: "Performance", logicalCPUs: 4), (name: "Efficiency", logicalCPUs: 4)])
        let m1Clusters = m1.clusters([0.2, 0.2, 0.2, 0.2, 0.5, 0.6, 0.7, 0.8])
        #expect(m1Clusters.map(\.name) == ["Performance", "Efficiency"])
        #expect(m1Clusters[0].cores == [0.5, 0.6, 0.7, 0.8])
        #expect(abs(m1Clusters[0].average - 0.65) < 1e-9)
        #expect(m1Clusters[1].cores == [0.2, 0.2, 0.2, 0.2])

        // Loads that don't match the layout (or no perf levels at all, as on Intel) make one "CPU" cluster.
        #expect(m1.clusters([0.5, 0.5]).map(\.name) == ["CPU"])
        #expect(ClusterLayout([]).clusters([0.25, 0.75]) == [ClusterLoad(name: "CPU", cores: [0.25, 0.75])])
        #expect(ClusterLayout([]).clusters([]).isEmpty)
    }

    // MARK: History

    @Test func historyCapsAndOrders() {
        var history = SampleHistory<Int>(capacity: 3)
        #expect(history.isEmpty)
        #expect(history.values == [])
        #expect(history.latest == nil)
        history.append(1)
        history.append(2)
        #expect(history.values == [1, 2])
        history.append(3)
        history.append(4)
        history.append(5)
        // Oldest first, never more than the capacity.
        #expect(history.values == [3, 4, 5])
        #expect(history.count == 3)
        #expect(history.latest == 5)
        history.removeAll()
        #expect(history.isEmpty)
        history.append(9)
        #expect(history.values == [9])

        #expect(SampleHistory<Double>().capacity == 60)
        var big = SampleHistory<Double>()
        for i in 0..<150 { big.append(Double(i)) }
        #expect(big.values.count == 60)
        #expect(big.values.first == 90)
        #expect(big.values.last == 149)
        // A capacity below one still keeps the latest sample.
        var tiny = SampleHistory<Int>(capacity: 0)
        tiny.append(1)
        tiny.append(2)
        #expect(tiny.values == [2])
    }

    // MARK: Memory

    @Test func memoryUsedAndPressure() {
        let gib: UInt64 = 1 << 30
        // 16 KB pages: 1 GiB = 65 536 pages.
        let stats = MemoryStats(pageSize: 16_384, free: 65_536, active: 3 * 65_536, inactive: 2 * 65_536,
                                wired: 65_536, compressed: 65_536 / 2, totalBytes: 16 * gib, pressure: MemoryPressure(kernelLevel: 1))
        // Used = active + wired + compressed.
        #expect(stats.usedBytes == 4 * gib + gib / 2)
        #expect(stats.totalBytes == 16 * gib)
        #expect(abs(stats.usedFraction - 4.5 / 16) < 1e-9)
        #expect(stats.pressure == .normal)

        #expect(MemoryPressure(kernelLevel: 1) == .normal)
        #expect(MemoryPressure(kernelLevel: 2) == .warning)
        #expect(MemoryPressure(kernelLevel: 4) == .critical)
        #expect(MemoryPressure(kernelLevel: 0) == .normal)
        #expect(MemoryPressure.allCases.map(\.title) == ["Normal", "Warning", "Critical"])

        // Never more than all of it, and no division by zero.
        let odd = MemoryStats(pageSize: 4096, free: 0, active: 10, inactive: 0, wired: 0, compressed: 0, totalBytes: 0, pressure: .normal)
        #expect(odd.usedFraction == 0)
        let over = MemoryStats(pageSize: 4096, free: 0, active: 1000, inactive: 0, wired: 0, compressed: 0, totalBytes: 4096, pressure: .warning)
        #expect(over.usedFraction == 1)
    }

    @Test func systemFormatting() {
        let gib: UInt64 = 1 << 30
        #expect(SystemFormat.gigabytes(128 * gib) == "128 GB")
        #expect(SystemFormat.gigabytes(62 * gib + gib / 10 * 2) == "62.2 GB")
        #expect(SystemFormat.gigabytes(gib / 2) == "0.5 GB")
        #expect(SystemFormat.gigabytes(0) == "0 GB")
        #expect(SystemFormat.memory(used: 41 * gib, total: 128 * gib) == "41 of 128 GB")
        #expect(SystemFormat.memory(used: 41 * gib + gib / 2, total: 128 * gib) == "41.5 of 128 GB")
        #expect(SystemFormat.percent(0.234) == "23%")
        #expect(SystemFormat.percent(0.996) == "100%")
        #expect(SystemFormat.percent(-0.1) == "0%")
        #expect(SystemFormat.percent(1.4) == "100%")
        #expect(SystemFormat.celsius(53.4) == "53°")
        #expect(SystemFormat.celsius(nil) == "—")
    }
}
