import Foundation

/// Software dimming: for displays that don't answer DDC, Orbit scales the display's gamma tables. The pill
/// runs 0...100 like any brightness; 100 leaves the display untouched and 0 dims to `floor`, never to black,
/// so a slip of the slider can't leave a screen unreadable.
public enum SoftwareDim {
    /// The gamma multiplier at brightness 0.
    public static let floor = 0.1

    /// The gamma multiplier for a pill value 0...100 (clamped): linear from `floor` to 1.
    public static func factor(forBrightness value: Double) -> Double {
        guard value.isFinite else { return 1 }
        let fraction = min(max(value, 0), 100) / 100
        return floor + (1 - floor) * fraction
    }

    /// Whether `value` dims at all (anything below 100).
    public static func dims(_ value: Double) -> Bool {
        factor(forBrightness: value) < 1
    }

    /// One channel of a gamma transfer table scaled by `factor` (clamped to 0...1), each entry kept in 0...1.
    public static func scaled(_ table: [Float], by factor: Double) -> [Float] {
        let f = Float(factor.isFinite ? min(max(factor, 0), 1) : 1)
        return table.map { min(max($0 * f, 0), 1) }
    }
}

/// A display's gamma transfer table (one ramp per channel), as `CGGetDisplayTransferByTable` returns it.
public struct GammaRamp: Equatable, Sendable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A captured table whose brightest entry is below this has probably been dimmed already (by another
    /// app, or by Orbit before a crash) and isn't trusted as the display's original.
    public static let suspectPeak: Float = 0.98

    /// A straight 0...1 ramp of `count` entries per channel.
    public static func identity(count: Int) -> GammaRamp {
        let n = max(count, 1)
        let ramp: [Float] = n == 1 ? [1] : (0..<n).map { Float($0) / Float(n - 1) }
        return GammaRamp(red: ramp, green: ramp, blue: ramp)
    }

    /// The brightest entry over all three channels.
    public var peak: Float { (red + green + blue).max() ?? 0 }

    /// The table to keep as the display's original before Orbit dims it. A suspect table (peak below
    /// `suspectPeak`) is scaled back up so its peak is 1 (keeping the channels' balance); a nearly black one
    /// is replaced by a straight ramp.
    public func trustedOriginal() -> (ramp: GammaRamp, wasSuspect: Bool) {
        let top = peak
        guard top < Self.suspectPeak else { return (self, false) }
        guard top >= 0.05 else { return (.identity(count: red.count), true) }
        func lift(_ channel: [Float]) -> [Float] { channel.map { min(max($0 / top, 0), 1) } }
        return (GammaRamp(red: lift(red), green: lift(green), blue: lift(blue)), true)
    }

    /// Every channel scaled by `factor` (`SoftwareDim.scaled`).
    public func scaled(by factor: Double) -> GammaRamp {
        GammaRamp(red: SoftwareDim.scaled(red, by: factor), green: SoftwareDim.scaled(green, by: factor),
                  blue: SoftwareDim.scaled(blue, by: factor))
    }
}
