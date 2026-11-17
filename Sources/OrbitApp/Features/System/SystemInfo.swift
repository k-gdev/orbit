import Darwin
import Foundation
import OrbitCore

/// Read-only `sysctl` lookups for the System feature.
enum SystemInfo {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // 32-bit sysctls fill only the first four bytes.
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The CPU clusters from `hw.perflevelN.name` / `.logicalcpu` ("Super" 6, "Performance" 12 on an M5 Max).
    /// Empty on Intel (no perf levels), which `ClusterLayout` treats as one "CPU" cluster.
    static func clusterLayout() -> ClusterLayout {
        let count = int("hw.nperflevels") ?? 0
        var levels: [ClusterLayout.Level] = []
        for n in 0..<max(count, 0) {
            guard let cpus = int("hw.perflevel\(n).logicalcpu") else { return ClusterLayout(levels: []) }
            levels.append(ClusterLayout.Level(name: string("hw.perflevel\(n).name") ?? "Cluster \(n + 1)", logicalCPUs: cpus))
        }
        return ClusterLayout(levels: levels)
    }

    /// "Apple M5 Max" (or the Intel brand string).
    static func chipName() -> String? {
        string("machdep.cpu.brand_string")?.trimmingCharacters(in: .whitespaces)
    }

    /// Seconds since boot, wall clock (sleep included, like `uptime`), from `kern.boottime`.
    static func uptime(now: Date = Date()) -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        let bootTime = TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000
        return max(now.timeIntervalSince1970 - bootTime, 0)
    }
}
