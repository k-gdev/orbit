import Foundation

/// The kernel's memory pressure (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical).
public enum MemoryPressure: String, CaseIterable, Sendable {
    case normal, warning, critical

    /// From the sysctl's value; anything unexpected reads as normal.
    public init(kernelLevel: Int) {
        switch kernelLevel {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// Memory use from `host_statistics64(HOST_VM_INFO64)` page counts and `hw.memsize`.
public struct MemoryStats: Equatable, Sendable {
    public var pageSize: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    /// Pages the compressor occupies (`compressor_page_count`).
    public var compressed: UInt64
    /// Physical memory (`hw.memsize`).
    public var totalBytes: UInt64
    public var pressure: MemoryPressure

    public init(pageSize: UInt64, free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64,
                totalBytes: UInt64, pressure: MemoryPressure) {
        self.pageSize = pageSize
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.totalBytes = totalBytes
        self.pressure = pressure
    }

    /// Active + wired + compressed pages, in bytes.
    public var usedBytes: UInt64 { (active + wired + compressed) * pageSize }

    /// Used over total, 0...1 (0 when the total is unknown).
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(usedBytes) / Double(totalBytes), 1)
    }
}

/// How the System tab writes its numbers.
public enum SystemFormat {
    private static let gib = Double(1 << 30)

    /// Binary gigabytes like Activity Monitor: "128 GB", "62.2 GB", "0.5 GB".
    public static func gigabytes(_ bytes: UInt64) -> String {
        "\(number(Double(bytes) / gib)) GB"
    }

    /// "41.5 of 128 GB".
    public static func memory(used: UInt64, total: UInt64) -> String {
        "\(number(Double(used) / gib)) of \(number(Double(total) / gib)) GB"
    }

    /// A 0...1 fraction as a whole percentage, clamped: "23%".
    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// Whole degrees Celsius, "53°", or "—" when there is no reading.
    public static func celsius(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))°"
    }

    /// One decimal, dropped when it is zero.
    private static func number(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))" : String(format: "%.1f", tenths / 10)
    }
}
