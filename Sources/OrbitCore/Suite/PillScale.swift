import Foundation

/// The value range of a `PillSlider`: 0...`maximum`, with a "boost zone" past `boostStart` (drawn
/// striped) when `maximum` is larger. App volume uses `PillScale(maximum: 150)`, a ThinkVision's
/// brightness the maximum its DDC reply reports. All of the slider's value math lives here.
public struct PillScale: Sendable, Equatable {
    public var maximum: Double
    public var boostStart: Double

    public init(maximum: Double, boostStart: Double = 100) {
        self.maximum = maximum
        self.boostStart = boostStart
    }

    /// 0...100 with no boost zone.
    public static let percent = PillScale(maximum: 100)

    /// Whether the range extends past `boostStart`.
    public var hasBoost: Bool { maximum > boostStart }

    /// Where the boost zone begins along the track, 0...1 (1 when there is none).
    public var boostStartFraction: Double { hasBoost ? boostStart / maximum : 1 }

    /// Whether `value` lies in the boost zone.
    public func isBoosted(_ value: Double) -> Bool { hasBoost && value > boostStart }

    /// `value` limited to 0...maximum.
    public func clamped(_ value: Double) -> Double { min(max(value, 0), max(maximum, 0)) }

    /// How far along the track `value` sits, clamped to 0...1.
    public func fraction(for value: Double) -> Double {
        guard maximum > 0 else { return 0 }
        return min(max(value / maximum, 0), 1)
    }

    /// The value at `fraction` along the track, rounded to `step` (when positive) and clamped to 0...maximum.
    public func value(forFraction fraction: Double, step: Double = 1) -> Double {
        let raw = min(max(fraction, 0), 1) * maximum
        let rounded = step > 0 ? (raw / step).rounded() * step : raw
        return clamped(rounded)
    }

    /// How far one scroll-wheel notch moves the value: a fiftieth of the range, at least one `step`, and a
    /// whole number of steps.
    public func wheelStep(step: Double = 1) -> Double {
        guard step > 0 else { return maximum / 50 }
        return max(step, ((maximum / 50) / step).rounded() * step)
    }

    /// `value` moved by `notches` scroll-wheel notches (`wheelStep`), on the `step` grid, clamped.
    public func wheelNudged(_ value: Double, notches: Double, step: Double = 1) -> Double {
        guard step > 0 else { return clamped(value + notches * wheelStep(step: step)) }
        return nudged(value, by: notches * wheelStep(step: step) / step, step: step)
    }

    /// `value` moved by `steps` steps of `step` (arrow keys, accessibility increments), rounded and clamped.
    public func nudged(_ value: Double, by steps: Double, step: Double = 1) -> Double {
        let moved = value + steps * step
        let rounded = step > 0 ? (moved / step).rounded() * step : moved
        return clamped(rounded)
    }
}
