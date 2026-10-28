import Foundation
import Testing
@testable import OrbitCore

/// DDC/CI framing and reply parsing. The reply vectors are the real bytes Kevo's monitors sent to a
/// Get VCP 0x10 on 2026-10-28 (ThinkVision P27u-20: 150 of 100; AOC Q27G4ZD: 100 of 100).
@Suite struct DDCTests {
    /// An independent checksum: XOR of `seed` and every byte.
    private func xor(_ seed: UInt8, _ bytes: [UInt8]) -> UInt8 { bytes.reduce(seed, ^) }

    /// A well-formed Get VCP reply, checksummed from 0x50.
    private func reply(result: UInt8 = 0, code: UInt8 = 0x10, maximum: Int, current: Int) -> [UInt8] {
        let body: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00,
                             UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        return body + [xor(0x50, body)]
    }

    @Test func getRequestFraming() {
        // 6E 51 82 01 10 AC is the textbook "get brightness"; the I2C layer adds the 6E.
        #expect(DDC.getVCPRequest(code: 0x10) == [0x51, 0x82, 0x01, 0x10, 0xAC])
        let contrast = DDC.getVCPRequest(code: 0x12)
        #expect(contrast.prefix(4) == [0x51, 0x82, 0x01, 0x12])
        // The checksum covers the destination address 0x6E too.
        #expect(contrast.last == xor(0x6E, Array(contrast.dropLast())))
        #expect(DDC.chipAddress == 0x37)
    }

    @Test func setRequestFraming() {
        #expect(DDC.setVCPRequest(code: 0x10, value: 50) == [0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDC.setVCPRequest(code: 0x10, value: 150) == [0x51, 0x84, 0x03, 0x10, 0x00, 0x96, 0x3E])
        // Big-endian 16-bit value; out-of-range values are clamped, never wrapped.
        let big = DDC.setVCPRequest(code: 0x10, value: 0x1234)
        #expect(Array(big[4...5]) == [0x12, 0x34])
        #expect(big.last == xor(0x6E, Array(big.dropLast())))
        #expect(Array(DDC.setVCPRequest(code: 0x10, value: -5)[4...5]) == [0x00, 0x00])
        #expect(Array(DDC.setVCPRequest(code: 0x10, value: 70_000)[4...5]) == [0xFF, 0xFF])
    }

    @Test func parsesValidReply() {
        let thinkVision: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x96, 0x56]
        #expect(DDC.parseVCPReply(thinkVision, code: 0x10) == VCPValue(current: 150, maximum: 100))
        let aoc: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4]
        #expect(DDC.parseVCPReply(aoc, code: 0x10) == VCPValue(current: 100, maximum: 100))
        #expect(DDC.parseVCPReply(reply(maximum: 255, current: 300), code: 0x10) == VCPValue(current: 300, maximum: 255))
        // Trailing bytes past the frame the length byte describes are ignored.
        #expect(DDC.parseVCPReply(aoc + [0x00, 0x00], code: 0x10) == VCPValue(current: 100, maximum: 100))
    }

    @Test func rejectsBadChecksum() {
        var bytes = reply(maximum: 100, current: 40)
        bytes[10] ^= 0x01
        #expect(DDC.parseVCPReply(bytes, code: 0x10) == nil)
        // A flipped data bit with the old checksum is caught too.
        var flipped = reply(maximum: 100, current: 40)
        flipped[9] ^= 0x04
        #expect(DDC.parseVCPReply(flipped, code: 0x10) == nil)
        // All zeros (what a silent bus reads back) has a wrong checksum and source.
        #expect(DDC.parseVCPReply([UInt8](repeating: 0, count: 11), code: 0x10) == nil)
    }

    @Test func rejectsShortReply() {
        let good = reply(maximum: 100, current: 40)
        for length in 0..<good.count {
            #expect(DDC.parseVCPReply(Array(good.prefix(length)), code: 0x10) == nil)
        }
        // The DDC/CI "null message" a busy display sends: 6E 80 BE.
        #expect(DDC.parseVCPReply([0x6E, 0x80, 0xBE], code: 0x10) == nil)
    }

    @Test func rejectsWrongCode() {
        #expect(DDC.parseVCPReply(reply(code: 0x12, maximum: 100, current: 50), code: 0x10) == nil)
        #expect(DDC.parseVCPReply(reply(code: 0x12, maximum: 100, current: 50), code: 0x12) == VCPValue(current: 50, maximum: 100))
    }

    @Test func rejectsWrongOpcodeSourceLengthAndErrorResult() {
        // Result 01 = unsupported VCP code.
        #expect(DDC.parseVCPReply(reply(result: 0x01, maximum: 100, current: 50), code: 0x10) == nil)
        // Wrong opcode (a capabilities reply, E3), re-checksummed so only the opcode is wrong.
        var opcode = Array(reply(maximum: 100, current: 50).dropLast())
        opcode[2] = 0xE3
        #expect(DDC.parseVCPReply(opcode + [xor(0x50, opcode)], code: 0x10) == nil)
        // Not from the display's address.
        var source = Array(reply(maximum: 100, current: 50).dropLast())
        source[0] = 0x6F
        #expect(DDC.parseVCPReply(source + [xor(0x50, source)], code: 0x10) == nil)
        // A length byte that isn't 0x88 (8 payload bytes).
        var length = Array(reply(maximum: 100, current: 50).dropLast())
        length[1] = 0x87
        #expect(DDC.parseVCPReply(length + [xor(0x50, length)], code: 0x10) == nil)
    }
}

/// Link brightness: proportional moves, clamped.
@Suite struct BrightnessLinkTests {
    private func close(_ a: [String: Double], _ b: [String: Double]) -> Bool {
        a.keys.sorted() == b.keys.sorted() && a.allSatisfy { key, value in abs(value - (b[key] ?? .nan)) < 1e-9 }
    }

    @Test func linkProportional() {
        let start = ["tv-left": 0.5, "tv-right": 0.8, "aoc": 0.2]
        // Halving one halves the others.
        #expect(close(BrightnessLink.values(changing: "tv-left", to: 0.25, current: start),
                      ["tv-left": 0.25, "tv-right": 0.4, "aoc": 0.1]))
        // Up by 20 %.
        #expect(close(BrightnessLink.values(changing: "tv-left", to: 0.6, current: start),
                      ["tv-left": 0.6, "tv-right": 0.96, "aoc": 0.24]))
        // No change, no movement.
        #expect(close(BrightnessLink.values(changing: "aoc", to: 0.2, current: start), start))
        // A display the caller didn't list joins at its new value and moves nobody.
        #expect(close(BrightnessLink.values(changing: "new", to: 0.7, current: start),
                      start.merging(["new": 0.7]) { $1 }))
        // Alone, it just takes the new value.
        #expect(close(BrightnessLink.values(changing: "only", to: 0.3, current: ["only": 0.9]), ["only": 0.3]))
    }

    @Test func linkClamps() {
        let start = ["a": 0.5, "b": 0.8, "c": 0.2, "d": 0.0]
        // Doubling: b would be 1.6; d has no ratio and shifts by +0.5.
        #expect(close(BrightnessLink.values(changing: "a", to: 1.0, current: start),
                      ["a": 1.0, "b": 1.0, "c": 0.4, "d": 0.5]))
        // The moved value itself is clamped first (1.4 → 1, -0.2 → 0).
        #expect(close(BrightnessLink.values(changing: "a", to: 1.4, current: start),
                      ["a": 1.0, "b": 1.0, "c": 0.4, "d": 0.5]))
        #expect(close(BrightnessLink.values(changing: "a", to: -0.2, current: start),
                      ["a": 0.0, "b": 0.0, "c": 0.0, "d": 0.0]))
        // From zero there is no ratio: everything shifts by the same amount.
        #expect(close(BrightnessLink.values(changing: "d", to: 0.3, current: start),
                      ["a": 0.8, "b": 1.0, "c": 0.5, "d": 0.3]))
        // Out-of-range inputs for the others are clamped too.
        #expect(close(BrightnessLink.values(changing: "a", to: 0.5, current: ["a": 0.5, "z": 1.7]), ["a": 0.5, "z": 1.0]))
    }
}

/// The resolution menu. Modes are a subset of what Kevo's main ThinkVision P27u-20 lists (2026-10-28).
@Suite struct DisplayModeListTests {
    private func mode(_ id: Int32, _ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ hz: Double = 60,
                      usable: Bool = true, flags: UInt32 = 0x3) -> RawDisplayMode {
        RawDisplayMode(id: id, width: w, height: h, pixelWidth: pw, pixelHeight: ph, refreshRate: hz, isUsable: usable, ioFlags: flags)
    }

    @Test func modeListDedupesAndLabelsHiDPI() {
        let current = mode(82, 3008, 1692, 6016, 3384)
        let modes = [
            mode(56, 1920, 1080, 1920, 1080), mode(150, 1920, 1080, 1920, 1080),        // duplicate size
            mode(76, 2560, 1440, 2560, 1440),
            mode(75, 2560, 1440, 5120, 2880),
            current, mode(85, 3008, 1692, 6016, 3384, 30), mode(86, 3008, 1692, 6016, 3384, 25),
            mode(83, 3008, 1692, 3008, 1692), mode(84, 3008, 1692, 3008, 1692, 30),
            mode(100, 3840, 2160, 3840, 2160, flags: 0x0200_0003),
            mode(119, 512, 384, 1024, 768, usable: false, flags: 0x1),                  // unusable
            mode(120, 512, 384, 1024, 768, usable: false, flags: 0x1),
        ]
        let list = DisplayModeList(modes: modes, current: current)
        #expect(list.entries.map(\.label) == [
            "3840 × 2160",
            "3008 × 1692 HiDPI · 60 Hz", "3008 × 1692 HiDPI · 30 Hz", "3008 × 1692 HiDPI · 25 Hz",
            "3008 × 1692 · 60 Hz", "3008 × 1692 · 30 Hz",
            "2560 × 1440 HiDPI", "2560 × 1440",
            "1920 × 1080",
        ])
        #expect(list.entries.filter(\.isCurrent).map(\.mode) == [current])
        #expect(list.title == "3008 × 1692 HiDPI")
        #expect(list.current?.label == "3008 × 1692 HiDPI · 60 Hz")
        // Groups: one per size, rates inside, fastest first.
        #expect(list.groups.map(\.sizeLabel) == ["3840 × 2160", "3008 × 1692 HiDPI", "3008 × 1692", "2560 × 1440 HiDPI",
                                                 "2560 × 1440", "1920 × 1080"])
        #expect(list.groups[1].entries.map(\.refreshLabel) == ["60 Hz", "30 Hz", "25 Hz"])
        #expect(list.groups.filter(\.isCurrent).map(\.sizeLabel) == ["3008 × 1692 HiDPI"])
        #expect(list.groups.map(\.isHiDPI) == [false, true, false, true, false, false])
        // The duplicate kept the first of the two identical modes.
        #expect(list.entries.last?.mode.id == 56)
        #expect(Set(list.entries.map(\.id)).count == list.entries.count)
    }

    @Test func modeListPrefersCurrentAndNativeDuplicatesAndKeepsAnUnusableCurrent() {
        // Of two identical-looking modes, the current one survives even if it comes second.
        let current = mode(9, 1920, 1080, 1920, 1080)
        let list = DisplayModeList(modes: [mode(8, 1920, 1080, 1920, 1080), current], current: current)
        #expect(list.entries.map(\.mode.id) == [9])
        #expect(list.current?.mode.id == 9)
        // Otherwise the native-flagged one does.
        let native = DisplayModeList(modes: [mode(1, 2560, 1440, 2560, 1440), mode(2, 2560, 1440, 2560, 1440, flags: 0x0200_0007)],
                                     current: nil)
        #expect(native.entries.map(\.mode.id) == [2])
        #expect(native.title == "Resolution")
        // An unusable current mode is still listed (the menu must show where the display is).
        let odd = mode(5, 640, 480, 640, 480, usable: false)
        let withOdd = DisplayModeList(modes: [mode(4, 800, 600, 800, 600), odd], current: odd)
        #expect(withOdd.entries.map(\.mode.id) == [4, 5])
        #expect(withOdd.title == "640 × 480")
        // A current mode missing from the list is added.
        let missing = mode(7, 1024, 768, 2048, 1536)
        #expect(DisplayModeList(modes: [mode(4, 800, 600, 800, 600)], current: missing).entries.map(\.mode.id) == [7, 4])
        // Fractional rates keep their decimals; a 0 Hz rate (unknown) gets no label of its own.
        let rates = DisplayModeList(modes: [mode(1, 1920, 1080, 1920, 1080, 59.94), mode(2, 1920, 1080, 1920, 1080, 120),
                                            mode(3, 1280, 720, 1280, 720, 0)], current: nil)
        #expect(rates.entries.map(\.label) == ["1920 × 1080 · 120 Hz", "1920 × 1080 · 59.94 Hz", "1280 × 720"])
        #expect(DisplayModeList.empty.entries.isEmpty)
        #expect(DisplayModeList.empty.groups.isEmpty)
    }
}

/// Brightness ranges, boost zones and tile captions.
@Suite struct BrightnessRangeTests {
    @Test func rangeUsesOverrideThenDDC() {
        // Override wins over everything.
        let overridden = BrightnessRange(override: 150, reportedMaximum: 100)
        #expect(overridden.maximum == 150)
        #expect(overridden.nominalMaximum == 100)
        #expect(overridden.isBoostable)
        #expect(overridden.scale == PillScale(maximum: 150, boostStart: 100))
        #expect(BrightnessRange(override: 120, reportedMaximum: 100, reportedCurrent: 150).maximum == 120)
        // An override below the reported maximum limits the pill, with no boost zone.
        let limited = BrightnessRange(override: 80, reportedMaximum: 100)
        #expect(limited.maximum == 80)
        #expect(limited.nominalMaximum == 80)
        #expect(!limited.isBoostable)
        // Then what DDC reported.
        #expect(BrightnessRange(override: nil, reportedMaximum: 100).maximum == 100)
        #expect(!BrightnessRange(override: nil, reportedMaximum: 100).isBoostable)
        // A native 0...255 monitor has no boost zone.
        let wide = BrightnessRange(override: nil, reportedMaximum: 255)
        #expect(wide.maximum == 255)
        #expect(!wide.isBoostable)
        // Then 100.
        #expect(BrightnessRange(override: nil, reportedMaximum: nil) == .percent)
        #expect(BrightnessRange.percent.maximum == 100)
        #expect(BrightnessRange.percent.scale == .percent)
        // A zero or negative override / maximum means "unknown".
        #expect(BrightnessRange(override: 0, reportedMaximum: 0).maximum == 100)
        #expect(BrightnessRange(override: -3, reportedMaximum: 60).maximum == 60)
    }

    @Test func rangeLearnsFromObservedValues() {
        // Kevo's ThinkVision: "150 of 100".
        let thinkVision = BrightnessRange(override: nil, reportedMaximum: 100, reportedCurrent: 150)
        #expect(thinkVision.maximum == 150)
        #expect(thinkVision.nominalMaximum == 100)
        #expect(thinkVision.isBoostable)
        // Remembered from an earlier read, after the user turned it down to 80.
        #expect(BrightnessRange(override: nil, reportedMaximum: 100, reportedCurrent: 80, learnedMaximum: 150).maximum == 150)
        // A current value at or below the maximum changes nothing.
        #expect(BrightnessRange(override: nil, reportedMaximum: 100, reportedCurrent: 60).maximum == 100)
        // Observations stretch the range at most to twice the reported maximum.
        #expect(BrightnessRange(override: nil, reportedMaximum: 100, reportedCurrent: 65_535).maximum == 200)
        // Overrides are capped at the 16-bit DDC ceiling.
        #expect(BrightnessRange(override: 100_000, reportedMaximum: 100).maximum == 0xFFFF)
    }

    @Test func rangeMapsFractions() {
        let range = BrightnessRange(override: 150, reportedMaximum: 100)
        #expect(range.fraction(for: 75) == 0.5)
        #expect(range.fraction(for: 300) == 1)
        #expect(range.value(forFraction: 0.5) == 75)
        #expect(range.value(forFraction: 0.333) == 50)
        #expect(range.value(forFraction: 2) == 150)
        #expect(range.clamped(-4) == 0)
    }

    @Test func captions() {
        let boost = BrightnessRange(override: nil, reportedMaximum: 100, reportedCurrent: 150)
        #expect(BrightnessControl.ddc.caption(range: boost) == "DDC · up to 150")
        #expect(BrightnessControl.ddc.caption(range: BrightnessRange(override: nil, reportedMaximum: 100)) == "DDC")
        #expect(BrightnessControl.native(builtIn: true).caption(range: .percent) == "Built-in")
        #expect(BrightnessControl.native(builtIn: false).caption(range: .percent) == "Apple display")
        #expect(BrightnessControl.software.caption(range: .percent) == "Software dimming")
        #expect(BrightnessControl.probing.caption(range: .percent) == "Checking DDC…")
        #expect(BrightnessControl.unavailable.caption(range: .percent) == "Brightness not adjustable")
        #expect(!BrightnessControl.unavailable.hasPill)
        #expect(BrightnessControl.software.hasPill)
    }
}

/// Gamma-table dimming for displays without DDC.
@Suite struct SoftwareDimTests {
    @Test func softwareDimFactorHasAFloor() {
        #expect(SoftwareDim.factor(forBrightness: 100) == 1)
        #expect(SoftwareDim.factor(forBrightness: 0) == SoftwareDim.floor)
        #expect(abs(SoftwareDim.factor(forBrightness: 50) - 0.55) < 1e-9)
        #expect(SoftwareDim.factor(forBrightness: 140) == 1)
        #expect(SoftwareDim.factor(forBrightness: -20) == SoftwareDim.floor)
        #expect(SoftwareDim.factor(forBrightness: .nan) == 1)
        #expect(SoftwareDim.dims(99))
        #expect(!SoftwareDim.dims(100))
        #expect(!SoftwareDim.dims(.nan))
    }

    @Test func softwareDimScalesTables() {
        let identity: [Float] = [0, 0.25, 0.5, 1]
        #expect(SoftwareDim.scaled(identity, by: 0.5) == [0, 0.125, 0.25, 0.5])
        #expect(SoftwareDim.scaled(identity, by: 1) == identity)
        // Factors and entries are clamped to 0...1.
        #expect(SoftwareDim.scaled(identity, by: 3) == identity)
        #expect(SoftwareDim.scaled([1.2, -0.1], by: 1) == [1, 0])
        #expect(SoftwareDim.scaled([], by: 0.5).isEmpty)
    }
}

/// Tile order and titles. Frames are Kevo's CGDisplayBounds on 2026-10-28.
@Suite struct DisplayArrangementTests {
    static let kevo = [
        DisplayArrangement.Item(name: "P27u-20 (1)", frame: CGRect(x: 0, y: 0, width: 3008, height: 1692)),
        DisplayArrangement.Item(name: "Q27G4ZD", frame: CGRect(x: 18, y: -1440, width: 2560, height: 1440)),
        DisplayArrangement.Item(name: "P27u-20 (2)", frame: CGRect(x: 3008, y: 0, width: 3008, height: 1692)),
        DisplayArrangement.Item(name: "K272HUL", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440)),
    ]

    @Test func ordersBuiltInThenLeftToRight() {
        // Acer (left), AOC (above the main ThinkVision), ThinkVision, ThinkVision.
        #expect(DisplayArrangement.order(Self.kevo) == [3, 1, 0, 2])
        let withLaptop = Self.kevo + [DisplayArrangement.Item(name: "Built-in Retina Display",
                                                              frame: CGRect(x: 6016, y: 400, width: 1728, height: 1117), isBuiltIn: true)]
        #expect(DisplayArrangement.order(withLaptop) == [4, 3, 1, 0, 2])
        // Same centre: top first.
        let stacked = [DisplayArrangement.Item(name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                       DisplayArrangement.Item(name: "A", frame: CGRect(x: 0, y: -100, width: 100, height: 100))]
        #expect(DisplayArrangement.order(stacked) == [1, 0])
        #expect(DisplayArrangement.order([]).isEmpty)
    }

    @Test func titlesDisambiguateIdenticalMonitors() {
        #expect(DisplayArrangement.titles(Self.kevo) == ["P27u-20 · Left", "Q27G4ZD", "P27u-20 · Right", "K272HUL"])
        // Two stacked.
        let stacked = [DisplayArrangement.Item(name: "LG (2)", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                       DisplayArrangement.Item(name: "LG (1)", frame: CGRect(x: 10, y: -100, width: 100, height: 100))]
        #expect(DisplayArrangement.titles(stacked) == ["LG · Bottom", "LG · Top"])
        // Three in a row are numbered left to right.
        let three = (0..<3).map { i in
            DisplayArrangement.Item(name: "Dell (\(i + 1))", frame: CGRect(x: Double(2 - i) * 100, y: 0, width: 100, height: 100))
        }
        #expect(DisplayArrangement.titles(three) == ["Dell · 3", "Dell · 2", "Dell · 1"])
        // A lone numbered name loses its suffix; an empty one gets a name; "(beta)" isn't a macOS suffix.
        #expect(DisplayArrangement.titles([.init(name: "Studio Display (1)", frame: .zero), .init(name: " ", frame: .zero),
                                           .init(name: "Cinema (beta)", frame: .zero)])
                == ["Studio Display", "Display", "Cinema (beta)"])
    }
}

/// `DisplaySettings` persistence (throwaway defaults suites only).
@Suite struct DisplaySettingsTests {
    @Test func settingsRoundTrip() {
        let (defaults, cleanup) = Fixtures.defaults()
        defer { cleanup() }

        let fresh = DisplaySettings(defaults: defaults)
        #expect(fresh.linkBrightness == false)
        #expect(fresh.maxOverrides.isEmpty)
        #expect(fresh.useGammaFallback == true)
        #expect(fresh.lastSoftwareDim.isEmpty)
        #expect(fresh.learnedMaximums.isEmpty)

        fresh.linkBrightness = true
        fresh.useGammaFallback = false
        fresh.setMaxOverride(150, for: "TV-LEFT")
        fresh.setMaxOverride(200, for: "AOC")
        fresh.setMaxOverride(nil, for: "AOC")
        fresh.lastSoftwareDim = ["ACER": 42.5]
        fresh.learn(maximum: 150, reported: 100, for: "TV-RIGHT")

        let reloaded = DisplaySettings(defaults: defaults)
        #expect(reloaded.linkBrightness == true)
        #expect(reloaded.useGammaFallback == false)
        #expect(reloaded.maxOverrides == ["TV-LEFT": 150])
        #expect(reloaded.maxOverride(for: "TV-LEFT") == 150)
        #expect(reloaded.maxOverride(for: "AOC") == nil)
        #expect(reloaded.lastSoftwareDim == ["ACER": 42.5])
        #expect(reloaded.learnedMaximums == ["TV-RIGHT": 150])
        // Every key is prefixed with the feature id.
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("displays.") }
        #expect(Set(keys) == ["displays.linkBrightness", "displays.useGammaFallback", "displays.maxOverrides",
                              "displays.lastSoftwareDim", "displays.learnedMaximums"])
    }

    @Test func settingsLearnKeepsTheHighestAndIgnoresJunk() {
        let (defaults, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        let settings = DisplaySettings(defaults: defaults)
        settings.learn(maximum: 80, reported: 100, for: "A")       // not above the reported max
        #expect(settings.learnedMaximums.isEmpty)
        settings.learn(maximum: 150, reported: 100, for: "A")
        settings.learn(maximum: 120, reported: 100, for: "A")      // lower than what we saw
        #expect(settings.learnedMaximums == ["A": 150])
        // Overrides outside 1...65535 are refused (cleared).
        settings.setMaxOverride(150, for: "B")
        settings.setMaxOverride(0, for: "B")
        #expect(settings.maxOverride(for: "B") == nil)

        // Values of the wrong type in the defaults fall back instead of crashing.
        defaults.set("yes", forKey: "displays.maxOverrides")
        defaults.set(["X": "loud"], forKey: "displays.lastSoftwareDim")
        defaults.set(["A": 150, "B": "x"], forKey: "displays.learnedMaximums")
        let reloaded = DisplaySettings(defaults: defaults)
        #expect(reloaded.maxOverrides.isEmpty)
        #expect(reloaded.lastSoftwareDim.isEmpty)
        #expect(reloaded.learnedMaximums == ["A": 150])
    }
}
