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
