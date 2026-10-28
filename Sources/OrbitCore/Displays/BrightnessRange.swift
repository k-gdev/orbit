import Foundation

/// How far a display's brightness pill goes, and where its striped boost zone starts.
///
/// - `maximum` (the pill's end) = the per-display override from Settings ?? what DDC reported ?? 100.
///   When no override is set and the monitor has shown it goes higher than it reports (a DDC reply whose
///   current value exceeds its maximum, now or remembered from an earlier read), that higher value is used:
///   Kevo's ThinkVisions reply "150 of 100" after their own menu boosted them.
/// - `nominalMaximum` (where the boost begins) = what DDC reported ?? 100, never past `maximum`. A monitor
///   that natively reports 0...255 therefore has no boost zone; one that reports 100 but shows 150 does.
/// - `writableMaximum` (the most Orbit sends) = the override ?? `nominalMaximum`. A boost seen only in a
///   reading is the monitor's own (its menu set it) and DDC can't reach it: the ThinkVisions clamp every write
///   above their reported 100 to 100. The pill shows the boost but stops there; an override is Kevo's word that
///   the monitor takes more over DDC, so writes go up to it.
public struct BrightnessRange: Equatable, Sendable {
    public private(set) var maximum: Int
    public private(set) var nominalMaximum: Int
    public private(set) var writableMaximum: Int

    /// The largest maximum Orbit accepts from anywhere (DDC values are 16-bit).
    public static let ceiling = 0xFFFF
    /// An observed value extends the automatic range to at most this multiple of the reported maximum, so
    /// one garbage reading can't stretch a pill to 65535.
    public static let observedExtensionLimit = 2

    /// 0...100 with no boost (built-in panels, software dimming, displays that never answered).
    public static let percent = BrightnessRange(override: nil, reportedMaximum: nil)

    public init(override: Int?, reportedMaximum: Int?, reportedCurrent: Int? = nil, learnedMaximum: Int? = nil) {
        let reported = reportedMaximum.flatMap { $0 > 0 ? min($0, Self.ceiling) : nil } ?? 100
        let limit = reported * Self.observedExtensionLimit
        let observed = [reportedCurrent, learnedMaximum].compactMap { $0 }.filter { $0 > reported }.map { min($0, limit) }.max()
        let automatic = max(reported, observed ?? reported)
        let overridden = override.flatMap { $0 > 0 ? min($0, Self.ceiling) : nil }
        let chosen = overridden ?? automatic
        maximum = chosen
        nominalMaximum = min(reported, chosen)
        writableMaximum = overridden ?? nominalMaximum
    }

    /// The `PillSlider` scale: 0...maximum, striped past `nominalMaximum`, settable up to `writableMaximum`.
    public var scale: PillScale {
        PillScale(maximum: Double(maximum), boostStart: Double(nominalMaximum),
                  limit: writableMaximum < maximum ? Double(writableMaximum) : nil)
    }

    /// Whether the pill has a boost zone.
    public var isBoostable: Bool { maximum > nominalMaximum }

    /// Whether Orbit can set values in the boost zone (an override), rather than only show them.
    public var isBoostWritable: Bool { writableMaximum > nominalMaximum }

    /// `value` limited to 0...maximum: what the pill can show.
    public func clamped(_ value: Double) -> Double { min(max(value, 0), Double(maximum)) }

    /// `value` limited to 0...writableMaximum: the most that is ever sent to the display.
    public func clampedForWrite(_ value: Double) -> Double { min(max(value, 0), Double(writableMaximum)) }

    /// `value` as a fraction of the writable range, 0...1 (for linking). Writable rather than shown, so a
    /// monitor boosted to 150 of a reported 100 counts as full and a linked move never asks for more than DDC takes.
    public func fraction(for value: Double) -> Double { writableMaximum > 0 ? clampedForWrite(value) / Double(writableMaximum) : 0 }

    /// The value at `fraction` of the writable range, rounded to a whole step.
    public func value(forFraction fraction: Double) -> Double {
        clampedForWrite((min(max(fraction, 0), 1) * Double(writableMaximum)).rounded())
    }
}

/// How Orbit drives a display's brightness, in the order it tries them.
public enum BrightnessControl: Equatable, Sendable {
    /// DisplayServices: the built-in panel, and Apple displays (Studio Display, Pro Display XDR).
    case native(builtIn: Bool)
    /// DDC/CI VCP 0x10 over the display cable.
    case ddc
    /// Gamma-table dimming, for displays that don't answer DDC.
    case software
    /// Still asking the display over DDC.
    case probing
    /// None of the above (no DDC and software dimming turned off).
    case unavailable

    /// The tile's caption under the display name: "Built-in", "DDC · boost from monitor menu", "Software dimming", ...
    public func caption(range: BrightnessRange) -> String {
        switch self {
        case .native(let builtIn): builtIn ? "Built-in" : "Apple display"
        case .ddc: range.isBoostable ? (range.isBoostWritable ? "DDC · up to \(range.maximum)" : "DDC · boost from monitor menu") : "DDC"
        case .software: "Software dimming"
        case .probing: "Checking DDC…"
        case .unavailable: "Brightness not adjustable"
        }
    }

    /// Whether the tile shows a brightness pill.
    public var hasPill: Bool {
        switch self {
        case .native, .ddc, .software, .probing: true
        case .unavailable: false
        }
    }
}
