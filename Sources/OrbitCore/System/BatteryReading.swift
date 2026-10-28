import Foundation

/// One battery: the Mac's own, or a connected device's (AirPods, a keyboard, a mouse).
public struct BatteryReading: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case mac, headphones, keyboard, mouse, trackpad, gameController, other
    }

    /// A separately charged part of one device: AirPods' "L", "R" and "Case".
    public struct Part: Equatable, Sendable {
        public var name: String
        public var percent: Int

        public init(name: String, percent: Int) {
            self.name = name
            self.percent = percent
        }
    }

    /// Stable across samples: "internal", "bt:<address>", or the accessory identifier.
    public var id: String
    public var name: String
    public var kind: Kind
    /// 0...100.
    public var percent: Int
    public var isCharging: Bool
    public var isCharged: Bool
    /// Drawing from a power adapter ("Power Source State" = "AC Power").
    public var onPowerAdapter: Bool
    /// Minutes left on battery / to a full charge, when the system knows (never 0 or negative).
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var parts: [Part]
    /// The level the device itself calls low ("Low Warn Level"), if it says.
    public var lowWarnLevel: Int?

    public init(id: String, name: String, kind: Kind, percent: Int, isCharging: Bool = false, isCharged: Bool = false,
                onPowerAdapter: Bool = false, minutesToEmpty: Int? = nil, minutesToFull: Int? = nil, parts: [Part] = [],
                lowWarnLevel: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percent = percent
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.onPowerAdapter = onPowerAdapter
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.parts = parts
        self.lowWarnLevel = lowWarnLevel
    }

    /// At or below the device's low level (20 % when it doesn't say), and not charging.
    public var isLow: Bool { !isCharging && percent <= (lowWarnLevel ?? 20) }

    /// The line under the name: charge state for the Mac ("Charged", "Charging · 1 h 5 m to full",
    /// "3 h 20 m left"), the parts for AirPods ("L 100% · R 90% · Case 35%"), or "Charging" / "Low battery"
    /// for other devices (nil when there is nothing to add).
    public var statusText: String? {
        if kind == .mac {
            if isCharging {
                guard let minutesToFull else { return "Charging" }
                return "Charging · \(UptimeFormatter.string(seconds: Double(minutesToFull) * 60)) to full"
            }
            if onPowerAdapter { return isCharged || percent >= 100 ? "Charged" : "Not charging" }
            guard let minutesToEmpty else { return "On battery" }
            return "\(UptimeFormatter.string(seconds: Double(minutesToEmpty) * 60)) left"
        }
        if !parts.isEmpty { return parts.map { "\($0.name) \($0.percent)%" }.joined(separator: " · ") }
        if isCharging { return "Charging" }
        return isLow ? "Low battery" : nil
    }
}

/// Turns IOPowerSources descriptions and IORegistry HID properties into `BatteryReading`s.
public enum BatteryParser {
    /// Every battery, de-duplicated: the Mac's first, then devices by name. `powerSources` are
    /// `IOPSGetPowerSourceDescription` dictionaries (internal battery and accessories); `registry` are the
    /// property dictionaries of IORegistry HID services (`AppleDeviceManagementHIDEventService`), of which
    /// only those with `BatteryPercent` count. A registry device that is also a power source is dropped.
    public static func readings(powerSources: [[String: Any]], registry: [[String: Any]]) -> [BatteryReading] {
        let sources = self.powerSources(powerSources)
        let sourceNames = sources.map { normalized($0.name) }
        let devices = registryDevices(registry).filter { device in
            let name = normalized(device.name)
            return !sourceNames.contains { $0 == name || $0.contains(name) }
        }
        return sorted(sources + devices)
    }

    /// Readings from `IOPSGetPowerSourceDescription` dictionaries. AirPods report each earbud inside a
    /// "Combined" source ("Combined Parts") and the case as its own source in the same group: the case
    /// folds into the combined reading as a "Case" part.
    public static func powerSources(_ descriptions: [[String: Any]]) -> [BatteryReading] {
        var readings: [Parsed] = []
        var cases: [String: BatteryReading.Part] = [:]          // group identifier → case part
        var combinedGroups: Set<String> = []
        for description in descriptions {
            guard bool(description["Is Present"]) ?? true, let percent = percent(description) else { continue }
            let group = description["Group Identifier"] as? String
            let partID = description["Part Identifier"] as? String
            if let group, partID == "Case" {
                cases[group] = BatteryReading.Part(name: "Case", percent: percent)
            }
            if let group, partID == "Combined" { combinedGroups.insert(group) }
            readings.append(reading(from: description, percent: percent))
        }
        // Fold each case into its group's combined reading; a case without one keeps its own row.
        return readings.compactMap { reading in
            guard let group = reading.group else { return reading.base }
            if reading.partID == "Case" { return combinedGroups.contains(group) ? nil : reading.base }
            guard reading.partID == "Combined", let casePart = cases[group] else { return reading.base }
            var base = reading.base
            base.parts.append(casePart)
            return base
        }
    }

    /// Readings from IORegistry HID service properties with `BatteryPercent` (`Product`, `DeviceAddress`),
    /// de-duplicated by Bluetooth address.
    public static func registryDevices(_ properties: [[String: Any]]) -> [BatteryReading] {
        var seen: Set<String> = []
        var readings: [BatteryReading] = []
        for entry in properties {
            guard let level = int(entry["BatteryPercent"]) else { continue }
            let name = (entry["Product"] as? String) ?? "Bluetooth Device"
            let address = (entry["DeviceAddress"] as? String).map(normalizedAddress)
            let id = address.map { "bt:\($0)" } ?? "hid:\(normalized(name))"
            guard seen.insert(id).inserted else { continue }
            readings.append(BatteryReading(id: id, name: name, kind: kind(category: nil, name: name), percent: clamp(level)))
        }
        return readings
    }

    // MARK: Helpers

    private struct Parsed {
        var base: BatteryReading
        var group: String?
        var partID: String?
    }

    private static func reading(from d: [String: Any], percent: Int) -> Parsed {
        let isInternal = (d["Type"] as? String) == "InternalBattery"
        let name = (d["Name"] as? String) ?? "Battery"
        let id = isInternal ? "internal"
            : (d["Accessory Identifier"] as? String) ?? int(d["Power Source ID"]).map { "ps:\($0)" } ?? "ps:\(normalized(name))"
        var parts: [BatteryReading.Part] = []
        if let combined = d["Combined Parts"] as? [[String: Any]] {
            parts = combined.compactMap { part in
                guard let level = self.percent(part) else { return nil }
                let side = part["Part Identifier"] as? String
                return BatteryReading.Part(name: side == "Left" ? "L" : side == "Right" ? "R" : (side ?? "?"), percent: level)
            }
            .sorted { order($0.name) < order($1.name) }
        }
        let reading = BatteryReading(
            id: id,
            name: isInternal ? "This Mac" : name,
            kind: isInternal ? .mac : kind(category: d["Accessory Category"] as? String, name: name),
            percent: percent,
            isCharging: bool(d["Is Charging"]) ?? false,
            isCharged: bool(d["Is Charged"]) ?? false,
            onPowerAdapter: (d["Power Source State"] as? String) == "AC Power",
            minutesToEmpty: int(d["Time to Empty"]).flatMap { $0 > 0 ? $0 : nil },
            minutesToFull: int(d["Time to Full Charge"]).flatMap { $0 > 0 ? $0 : nil },
            parts: parts,
            lowWarnLevel: int(d["Low Warn Level"]))
        return Parsed(base: reading, group: d["Group Identifier"] as? String, partID: d["Part Identifier"] as? String)
    }

    /// "Current Capacity" over "Max Capacity" (100 when absent), as a whole percentage.
    private static func percent(_ d: [String: Any]) -> Int? {
        guard let current = int(d["Current Capacity"]) else { return nil }
        let maximum = int(d["Max Capacity"]) ?? 100
        guard maximum > 0 else { return nil }
        return clamp(Int((Double(current) * 100 / Double(maximum)).rounded()))
    }

    private static func kind(category: String?, name: String) -> BatteryReading.Kind {
        let text = ((category ?? "") + " " + name).lowercased()
        if text.contains("keyboard") { return .keyboard }
        if text.contains("mouse") { return .mouse }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("controller") || text.contains("gamepad") { return .gameController }
        if ["headset", "headphone", "audio", "airpods", "beats", "buds", "earphone"].contains(where: text.contains) { return .headphones }
        return .other
    }

    private static func sorted(_ readings: [BatteryReading]) -> [BatteryReading] {
        readings.sorted { a, b in
            if (a.kind == .mac) != (b.kind == .mac) { return a.kind == .mac }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func order(_ part: String) -> Int { ["L": 0, "R": 1, "Case": 2][part] ?? 3 }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 100) }

    /// Lowercased, curly apostrophes straightened, for matching names across sources.
    private static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: .whitespaces)
    }

    /// "A4-83-E7-11-22-33" and "a4:83:e7:11:22:33" → "a4:83:e7:11:22:33".
    private static func normalizedAddress(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: v
        case let v as NSNumber: v.intValue
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let v as Bool: v
        case let v as NSNumber: v.boolValue
        default: nil
        }
    }
}
