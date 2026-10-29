import Foundation

// Matching Apple Silicon DDC endpoints to displays.
//
// On Apple Silicon each external display has an `IOAVService` (IORegistry class `DCPAVServiceProxy`,
// `Location = External`) that can talk DDC/CI, but nothing on it says which `CGDirectDisplayID` it drives.
// Its framebuffer (`IOMobileFramebufferShim` / `AppleCLCD2`, the entry before it in the registry, under the
// same `dispextN` unit) carries the EDID facts; CoreGraphics / CoreDisplay give the same facts for each
// display, plus `IODisplayLocation`, the framebuffer's registry path. Identical monitors (Kevo's two
// ThinkVision P27u-20 share one EDID UUID and both report serial 0) can only be told apart by that path or
// an alphanumeric serial, so matching scores every pair on everything known and assigns by elimination.

/// The facts encoded in an IORegistry `EDID UUID` such as `30AECB62-0000-0000-1E24-0104B53C2278`:
/// bytes 0–1 the EDID manufacturer id (big-endian), 2–3 the product code (little-endian, as in the EDID),
/// 8 the week and 9 the year − 1990 of manufacture.
public struct EDIDUUID: Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var weekOfManufacture: Int
    public var yearOfManufacture: Int

    public init(vendorID: Int, productID: Int, weekOfManufacture: Int, yearOfManufacture: Int) {
        self.vendorID = vendorID
        self.productID = productID
        self.weekOfManufacture = weekOfManufacture
        self.yearOfManufacture = yearOfManufacture
    }

    public init?(_ text: String) {
        let hex = Array(text.replacingOccurrences(of: "-", with: ""))
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        for start in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(hex[start...start + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        vendorID = Int(bytes[0]) << 8 | Int(bytes[1])
        productID = Int(bytes[3]) << 8 | Int(bytes[2])
        weekOfManufacture = Int(bytes[8])
        yearOfManufacture = Int(bytes[9]) + 1990
    }
}

/// One external `IOAVService` and what its framebuffer says about the monitor on it.
public struct AVServiceDescriptor: Equatable, Sendable {
    /// The framebuffer's IORegistry path ("IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext0@B0000000/IOMobileFramebufferShim").
    public var framebufferPath: String?
    public var edidUUID: String?
    public var productName: String?
    public var vendorID: Int?
    public var productID: Int?
    /// The EDID's numeric serial; 0 means none.
    public var serialNumber: Int?
    /// The EDID's serial-number string ("V90GFKY1").
    public var alphanumericSerial: String?
    public var yearOfManufacture: Int?
    public var weekOfManufacture: Int?

    public init(framebufferPath: String? = nil, edidUUID: String? = nil, productName: String? = nil, vendorID: Int? = nil,
                productID: Int? = nil, serialNumber: Int? = nil, alphanumericSerial: String? = nil,
                yearOfManufacture: Int? = nil, weekOfManufacture: Int? = nil) {
        self.framebufferPath = framebufferPath
        self.edidUUID = edidUUID
        self.productName = productName
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.alphanumericSerial = alphanumericSerial
        self.yearOfManufacture = yearOfManufacture
        self.weekOfManufacture = weekOfManufacture
    }

    /// From a framebuffer's IORegistry properties: `EDID UUID` and `DisplayAttributes.ProductAttributes`
    /// (`ProductName`, `LegacyManufacturerID`, `ProductID`, `SerialNumber`, `AlphanumericSerialNumber`,
    /// `YearOfManufacture`, `WeekOfManufacture`). Facts missing there are taken from the EDID UUID.
    public init(framebufferPath: String?, properties: [String: Any]) {
        self.init(framebufferPath: framebufferPath)
        edidUUID = properties["EDID UUID"] as? String
        let decoded = edidUUID.flatMap(EDIDUUID.init)
        let attributes = properties["DisplayAttributes"] as? [String: Any]
        let product = attributes?["ProductAttributes"] as? [String: Any] ?? [:]
        productName = nonEmpty(product["ProductName"] as? String)
        vendorID = integer(product["LegacyManufacturerID"]) ?? decoded?.vendorID
        productID = integer(product["ProductID"]) ?? decoded?.productID
        serialNumber = integer(product["SerialNumber"])
        alphanumericSerial = nonEmpty(product["AlphanumericSerialNumber"] as? String)
        yearOfManufacture = integer(product["YearOfManufacture"]) ?? decoded?.yearOfManufacture
        weekOfManufacture = integer(product["WeekOfManufacture"]) ?? decoded?.weekOfManufacture
    }
}

/// One CoreGraphics display and what macOS says about the monitor.
public struct DisplayDescriptor: Equatable, Sendable {
    public var vendorID: Int?
    public var productID: Int?
    /// `CGDisplaySerialNumber`; 0 means none.
    public var serialNumber: Int?
    public var productName: String?
    /// CoreDisplay's `IODisplayLocation`: the display's framebuffer path in the IORegistry.
    public var ioDisplayLocation: String?
    public var alphanumericSerial: String?
    public var yearOfManufacture: Int?
    public var weekOfManufacture: Int?
    public var isBuiltIn: Bool

    public init(vendorID: Int? = nil, productID: Int? = nil, serialNumber: Int? = nil, productName: String? = nil,
                ioDisplayLocation: String? = nil, alphanumericSerial: String? = nil, yearOfManufacture: Int? = nil,
                weekOfManufacture: Int? = nil, isBuiltIn: Bool = false) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.productName = productName
        self.ioDisplayLocation = ioDisplayLocation
        self.alphanumericSerial = alphanumericSerial
        self.yearOfManufacture = yearOfManufacture
        self.weekOfManufacture = weekOfManufacture
        self.isBuiltIn = isBuiltIn
    }

    /// From `CGDisplayVendorNumber` / `ModelNumber` / `SerialNumber` / `IsBuiltin` and CoreDisplay's info
    /// dictionary (`IODisplayLocation`, `DisplayProductName` (localized; en_US preferred),
    /// `DisplayYearManufacture`, `DisplayWeekManufacture`). A vendor or model of 0 means unknown.
    public init(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltIn: Bool, info: [String: Any]?) {
        self.init(vendorID: vendor == 0 ? nil : Int(vendor), productID: model == 0 ? nil : Int(model),
                  serialNumber: Int(serial), isBuiltIn: isBuiltIn)
        guard let info else { return }
        ioDisplayLocation = nonEmpty(info["IODisplayLocation"] as? String)
        if let names = info["DisplayProductName"] as? [String: String] {
            productName = nonEmpty(names["en_US"] ?? names.sorted { $0.key < $1.key }.first?.value)
        }
        yearOfManufacture = integer(info["DisplayYearManufacture"])
        weekOfManufacture = integer(info["DisplayWeekManufacture"])
    }
}

/// Pairs each external `DCPAVServiceProxy` with its framebuffer from an IORegistry walk.
public enum AVServicePairing {
    public struct Entry: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case framebuffer
            case service(external: Bool)
        }
        public var kind: Kind
        public var path: String

        public init(_ kind: Kind, path: String) {
            self.kind = kind
            self.path = path
        }
    }

    /// For each external service (its index in `entries`), the index of its framebuffer: the one under the
    /// same `dispN`/`dispextN` unit when the paths say so, else the closest framebuffer before it in
    /// registry order (only when that can't contradict a unit name). Services with neither are left out.
    public static func pair(_ entries: [Entry]) -> [Int: Int] {
        var framebufferForUnit: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where entry.kind == .framebuffer {
            if let unit = unitToken(in: entry.path), framebufferForUnit[unit] == nil { framebufferForUnit[unit] = index }
        }
        var pairs: [Int: Int] = [:]
        var previous: Int?
        for (index, entry) in entries.enumerated() {
            switch entry.kind {
            case .framebuffer:
                previous = index
            case .service(let external):
                guard external else { continue }
                let unit = unitToken(in: entry.path)
                if let unit, let framebuffer = framebufferForUnit[unit] {
                    pairs[index] = framebuffer
                } else if let previous, unit == nil || unitToken(in: entries[previous].path) == nil {
                    pairs[index] = previous
                }
            }
        }
        return pairs
    }

    /// "dispext0" from ".../dispext0@B0000000/IOMobileFramebufferShim" or from
    /// ".../dispext0:dcpav-service-epic:0/DCPAVServiceProxy".
    public static func unitToken(in path: String) -> String? {
        for component in path.split(separator: "/") where component.hasPrefix("disp") {
            let name = component.prefix { $0 != "@" && $0 != ":" }
            guard name.count < component.count else { continue }
            var rest = name.dropFirst(4)
            if rest.hasPrefix("ext") { rest = rest.dropFirst(3) }
            if !rest.isEmpty, rest.allSatisfy({ $0.isASCII && $0.isNumber }) { return String(name) }
        }
        return nil
    }
}

/// Decides which `IOAVService` drives which display (scoring plus elimination).
public enum DDCServiceMatcher {
    /// Points for each fact two descriptors share. nil = these cannot be the same monitor (a built-in
    /// display, or a known vendor, product, serial, or comparable location that differs).
    public static func score(_ service: AVServiceDescriptor, _ display: DisplayDescriptor, locationsComparable: Bool = true) -> Int? {
        if display.isBuiltIn { return nil }
        var points = 0
        if locationsComparable, let a = normalizedLocation(service.framebufferPath), let b = normalizedLocation(display.ioDisplayLocation) {
            guard a == b else { return nil }
            points += Points.location
        }
        if let a = service.vendorID, let b = display.vendorID {
            guard a == b else { return nil }
            points += Points.model
        }
        if let a = service.productID, let b = display.productID {
            guard a == b else { return nil }
            points += Points.model
        }
        if let a = service.serialNumber, a != 0, let b = display.serialNumber, b != 0 {
            guard a == b else { return nil }
            points += Points.serial
        }
        if let a = nonEmpty(service.alphanumericSerial), let b = nonEmpty(display.alphanumericSerial) {
            guard a.caseInsensitiveCompare(b) == .orderedSame else { return nil }
            points += Points.serial
        }
        if let a = nonEmpty(service.productName), let b = nonEmpty(display.productName), a.caseInsensitiveCompare(b) == .orderedSame {
            points += Points.name
        }
        if let y1 = service.yearOfManufacture, let y2 = display.yearOfManufacture, y1 == y2,
           let w1 = service.weekOfManufacture, let w2 = display.weekOfManufacture, w1 == w2 {
            points += Points.date
        }
        return points
    }

    /// Service index → display index. Exact framebuffer-location matches are taken first; of the rest, the
    /// assignment that pairs the most services, then has the highest total score, then stays closest to
    /// list order wins (impossible pairs having been eliminated by `score`). Each side is used at most once.
    /// Locations are only compared when at least one pair matches exactly, so a different path format on
    /// some macOS version doesn't disqualify everything.
    public static func match(services: [AVServiceDescriptor], displays: [DisplayDescriptor]) -> [Int: Int] {
        let comparable = services.contains { s in displays.contains { d in !d.isBuiltIn && sameLocation(s, d) } }
        var options: [Int: [Choice]] = [:]
        for (si, service) in services.enumerated() {
            for (di, display) in displays.enumerated() {
                if let points = score(service, display, locationsComparable: comparable) {
                    options[si, default: []].append(Choice(display: di, score: points))
                }
            }
        }
        var result: [Int: Int] = [:]
        var taken = Set<Int>()
        if comparable {
            for si in services.indices {
                if let choice = options[si]?.first(where: { !taken.contains($0.display) && sameLocation(services[si], displays[$0.display]) }) {
                    result[si] = choice.display
                    taken.insert(choice.display)
                }
            }
        }
        let open = services.indices.filter { result[$0] == nil && !(options[$0] ?? []).isEmpty }
        let choices = open.map { si in
            (options[si] ?? []).filter { !taken.contains($0.display) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : abs($0.display - si) < abs($1.display - si) }
        }
        let picked = open.count <= exhaustiveLimit ? bestAssignment(open, choices, taken) : greedyAssignment(open, choices, taken)
        for (si, di) in picked { result[si] = di }
        return result
    }

    /// Above this many undecided services the search gives way to best-pair-first.
    static let exhaustiveLimit = 8

    private enum Points {
        static let location = 1000, serial = 100, model = 10, name = 5, date = 2
    }

    private struct Choice {
        let display: Int
        let score: Int
    }

    /// The registry path without the plane prefix or a trailing slash.
    static func normalizedLocation(_ path: String?) -> String? {
        guard var path = nonEmpty(path) else { return nil }
        if path.hasPrefix("IOService:") { path.removeFirst("IOService:".count) }
        while path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? nil : path
    }

    private static func sameLocation(_ service: AVServiceDescriptor, _ display: DisplayDescriptor) -> Bool {
        guard let a = normalizedLocation(service.framebufferPath), let b = normalizedLocation(display.ioDisplayLocation) else { return false }
        return a == b
    }

    /// How good an assignment is: more pairs, then more points, then less reordering.
    private struct Tally: Comparable {
        var count = 0, score = 0, distance = 0
        static func < (a: Tally, b: Tally) -> Bool {
            if a.count != b.count { return a.count < b.count }
            if a.score != b.score { return a.score < b.score }
            return a.distance > b.distance
        }
    }

    private static func bestAssignment(_ open: [Int], _ choices: [[Choice]], _ taken: Set<Int>) -> [Int: Int] {
        var best = (tally: Tally(), pairs: [Int: Int]())
        func search(_ k: Int, _ used: Set<Int>, _ tally: Tally, _ pairs: [Int: Int]) {
            guard k < open.count else {
                if best.tally < tally { best = (tally, pairs) }
                return
            }
            let si = open[k]
            for choice in choices[k] where !used.contains(choice.display) {
                var next = pairs
                next[si] = choice.display
                search(k + 1, used.union([choice.display]),
                       Tally(count: tally.count + 1, score: tally.score + choice.score,
                             distance: tally.distance + abs(choice.display - si)), next)
            }
            search(k + 1, used, tally, pairs)   // this service left unmatched
        }
        search(0, taken, Tally(), [:])
        return best.pairs
    }

    private static func greedyAssignment(_ open: [Int], _ choices: [[Choice]], _ taken: Set<Int>) -> [Int: Int] {
        var all: [(service: Int, choice: Choice)] = []
        for (k, si) in open.enumerated() { for choice in choices[k] { all.append((si, choice)) } }
        all.sort { a, b in
            if a.choice.score != b.choice.score { return a.choice.score > b.choice.score }
            let da = abs(a.choice.display - a.service), db = abs(b.choice.display - b.service)
            if da != db { return da < db }
            return a.service < b.service
        }
        var pairs: [Int: Int] = [:]
        var used = taken
        for item in all where pairs[item.service] == nil && !used.contains(item.choice.display) {
            pairs[item.service] = item.choice.display
            used.insert(item.choice.display)
        }
        return pairs
    }
}

// MARK: Helpers

private func nonEmpty(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    return (value as? NSNumber)?.intValue
}
