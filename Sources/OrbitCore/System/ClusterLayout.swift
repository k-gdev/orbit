import Foundation

/// One CPU cluster's load: its name (`hw.perflevelN.name`, e.g. "Super", "Performance", "Efficiency")
/// and each of its logical CPUs' load, 0...1.
public struct ClusterLoad: Equatable, Sendable {
    public var name: String
    public var cores: [Double]

    public init(name: String, cores: [Double]) {
        self.name = name
        self.cores = cores
    }

    /// The mean of the cluster's core loads (0 when it has none).
    public var average: Double { cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count) }
}

/// How logical CPUs group into clusters, from the `hw.perflevelN.name` / `hw.perflevelN.logicalcpu`
/// sysctls (perf level 0 is the fastest). Cluster names are the sysctl's: an M5 Max has "Super" and
/// "Performance" and no "Efficiency" cluster, so nothing here assumes P and E.
///
/// `host_processor_info` lists CPUs in kernel order, which on Apple Silicon starts with the SLOWEST
/// level: on the M5 Max cpu0–11 are the 12 "Performance" cores and cpu12–17 the 6 "Super" cores (device
/// tree `cluster-type` M, M, P); on an M1 cpu0–3 are "Efficiency" and cpu4–7 "Performance". So the
/// layout hands out CPU indices from the last perf level backwards, and returns clusters in perf level
/// order (fastest first).
public struct ClusterLayout: Equatable, Sendable {
    public struct Level: Equatable, Sendable {
        public var name: String
        public var logicalCPUs: Int

        public init(name: String, logicalCPUs: Int) {
            self.name = name
            self.logicalCPUs = logicalCPUs
        }
    }

    /// The perf levels, fastest first.
    public var levels: [Level]

    public init(levels: [Level]) {
        self.levels = levels
    }

    /// From `(hw.perflevelN.name, hw.perflevelN.logicalcpu)` pairs, N = 0, 1, ….
    public init(_ levels: [(name: String, logicalCPUs: Int)]) {
        self.init(levels: levels.map { Level(name: $0.name, logicalCPUs: $0.logicalCPUs) })
    }

    /// Logical CPUs the layout accounts for.
    public var coreCount: Int { levels.reduce(0) { $0 + max($1.logicalCPUs, 0) } }

    /// Groups per-core loads (in `host_processor_info` order) into clusters, fastest level first. When the
    /// loads don't match the layout (no perf levels, as on Intel, or a different core count) they form a
    /// single "CPU" cluster; no loads give no clusters.
    public func clusters(_ perCore: [Double]) -> [ClusterLoad] {
        guard !perCore.isEmpty else { return [] }
        guard !levels.isEmpty, coreCount == perCore.count, levels.allSatisfy({ $0.logicalCPUs > 0 }) else {
            return [ClusterLoad(name: "CPU", cores: perCore)]
        }
        var start = 0
        var slowestFirst: [ClusterLoad] = []
        for level in levels.reversed() {
            slowestFirst.append(ClusterLoad(name: level.name, cores: Array(perCore[start..<start + level.logicalCPUs])))
            start += level.logicalCPUs
        }
        return slowestFirst.reversed()
    }
}
