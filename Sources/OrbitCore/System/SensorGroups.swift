import Foundation

/// Which part of the chip a temperature sensor watches.
public enum SensorKind: String, CaseIterable, Sendable {
    case cpu, gpu, soc

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "SoC"
        }
    }
}

/// One temperature reading: an IOHID sensor's `Product` name ("PMU tdie3") or a four-character SMC key
/// ("Tg0C"), in degrees Celsius.
public struct SensorReading: Equatable, Sendable {
    public var name: String
    public var celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

/// The average and hottest of one group's plausible readings.
public struct SensorGroupStats: Equatable, Sendable {
    public var average: Double
    public var maximum: Double
    public var count: Int

    public init(average: Double, maximum: Double, count: Int) {
        self.average = average
        self.maximum = maximum
        self.count = count
    }
}

/// Temperature readings sorted into CPU, GPU and SoC, with implausible values dropped.
///
/// What the M5 Max actually has (read-only probe, macOS 26.5):
/// - IOHID (PrimaryUsagePage 0xff00, PrimaryUsage 5): "PMU tdie1"…"PMU tdie14" three times over (the SoC
///   die, ~53 °C idle), "PMU tdev1"…"PMU tdev8" (reading −9201, i.e. unusable), "PMU tcal" (a calibration
///   reference), "NAND CH0 temp" and "gas gauge battery". No per-cluster or GPU sensors any more.
/// - SMC float keys: 23 × "Tp??" (CPU, ~53 °C) and 84 × "Tg??" (GPU, ~50 °C), plus many others whose meaning
///   is unknown and which are ignored.
/// Older Apple Silicon (M1/M2) also names "pACC/eACC MTR Temp Sensor*", "GPU MTR Temp Sensor*" and
/// "SOC/ANE/ISP MTR Temp Sensor*" over IOHID; Intel Macs only have SMC keys ("TC0P", "TG0P", "TPCD").
public struct SensorGroups: Equatable, Sendable {
    public var cpu: SensorGroupStats?
    public var gpu: SensorGroupStats?
    public var soc: SensorGroupStats?

    public init(cpu: SensorGroupStats? = nil, gpu: SensorGroupStats? = nil, soc: SensorGroupStats? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.soc = soc
    }

    public init(readings: [SensorReading]) {
        var byKind: [SensorKind: [Double]] = [:]
        for reading in readings where Self.isPlausible(reading.celsius) {
            guard let kind = Self.classify(reading.name) else { continue }
            byKind[kind, default: []].append(reading.celsius)
        }
        func stats(_ kind: SensorKind) -> SensorGroupStats? {
            guard let values = byKind[kind], let maximum = values.max() else { return nil }
            return SensorGroupStats(average: values.reduce(0, +) / Double(values.count), maximum: maximum, count: values.count)
        }
        self.init(cpu: stats(.cpu), gpu: stats(.gpu), soc: stats(.soc))
    }

    public subscript(kind: SensorKind) -> SensorGroupStats? {
        switch kind {
        case .cpu: cpu
        case .gpu: gpu
        case .soc: soc
        }
    }

    public var isEmpty: Bool { cpu == nil && gpu == nil && soc == nil }

    /// The one temperature to show when there is room for one (the menu bar readout): the CPU average,
    /// else the SoC die's, else the GPU's.
    public var headline: Double? { cpu?.average ?? soc?.average ?? gpu?.average }

    /// A real temperature: finite, above 0 °C and below 150 °C.
    public static func isPlausible(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > 0 && celsius < 150
    }

    /// The group a sensor belongs to, or nil for sensors that are not chip temperatures (battery, NAND,
    /// calibration, board thermistors) or are unknown.
    public static func classify(_ name: String) -> SensorKind? {
        if name.count == 4, name.hasPrefix("T"), !name.contains(" ") { return classifySMC(name) }
        let lower = name.lowercased()
        if lower.hasPrefix("pacc") || lower.hasPrefix("eacc") { return .cpu }
        if lower.hasPrefix("gpu") { return .gpu }
        if lower.hasPrefix("pmu tdie") || lower.hasPrefix("soc") || lower.hasPrefix("ane") || lower.hasPrefix("isp") { return .soc }
        return nil
    }

    private static func classifySMC(_ key: String) -> SensorKind? {
        let chars = Array(key)
        switch (chars[1], chars[2], chars[3]) {
        // Apple Silicon: CPU die ("Tp" performance / "Te" efficiency) and GPU ("Tg").
        case ("p", _, _), ("e", _, _): return .cpu
        case ("g", _, _): return .gpu
        // Intel: CPU proximity/die/cores, GPU proximity/die, platform controller hub die.
        case ("C", "0", "P"), ("C", "0", "D"), ("C", "0", "E"), ("C", "0", "F"), ("C", "0", "H"): return .cpu
        case ("C", let n, "C") where n.isNumber: return .cpu
        case ("G", "0", "P"), ("G", "0", "D"), ("G", "0", "H"): return .gpu
        case ("P", "C", "D"): return .soc
        default: return nil
        }
    }
}

/// SMC (System Management Controller) four-character codes and the two temperature encodings.
public enum SMCCode {
    /// "TC0P" → 0x54433050.
    public static func code(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// 0x54433050 → "TC0P".
    public static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A temperature from an SMC value: `flt ` (little-endian Float32, Apple Silicon) or `sp78` (big-endian
    /// signed 8.8 fixed point, Intel). Any other type or size is not a temperature.
    public static func celsius(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }
}
