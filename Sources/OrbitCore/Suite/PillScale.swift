import Foundation

/// The value range of a `PillSlider`: 0...`maximum`, with a "boost zone" past `boostStart` (drawn
/// striped) when `maximum` is larger. App volume uses `PillScale(maximum: 150)`, a ThinkVision's
/// brightness the maximum its DDC reply reports. All of the slider's value math lives here.
///
/// `limit` lets a pill show more than it lets anyone set: a monitor boosted from its own menu reads 150, the
/// pill shows it, but a drag, scroll or key stops at the `limit` (what DDC accepts).
public struct PillScale: Sendable, Equatable {
    public var maximum: Double
    public var boostStart: Double
    /// The highest value input can set when that is below `maximum`; nil means `maximum`.
    public var limit: Double?

    public init(maximum: Double, boostStart: Double = 100, limit: Double? = nil) {
        self.maximum = maximum
        self.boostStart = boostStart
        self.limit = limit
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

    /// The highest value input can set: `limit`, never past `maximum`.
    public var settableMaximum: Double { min(limit ?? maximum, maximum) }

    /// `value` moved by `delta`, limited to 0...`settableMaximum`. A value already past the limit (a boost
    /// the monitor set itself) is left alone by a move further up, so scrolling up at 150 doesn't drop it to 100.
    public func moved(_ value: Double, by delta: Double) -> Double { limited(value + delta, from: value) }

    /// `target` limited to 0...`settableMaximum`, except that a move up from at or past the limit keeps `value`.
    private func limited(_ target: Double, from value: Double) -> Double {
        if target > value, value >= settableMaximum { return clamped(value) }
        return min(max(target, 0), max(settableMaximum, 0))
    }

    /// How far along the track `value` sits, clamped to 0...1.
    public func fraction(for value: Double) -> Double {
        guard maximum > 0 else { return 0 }
        return min(max(value / maximum, 0), 1)
    }

    /// The value at `fraction` along the track, rounded to `step` (when positive) and clamped to 0...settableMaximum.
    public func value(forFraction fraction: Double, step: Double = 1) -> Double {
        let raw = min(max(fraction, 0), 1) * maximum
        let rounded = step > 0 ? (raw / step).rounded() * step : raw
        return min(max(rounded, 0), max(settableMaximum, 0))
    }

    /// How far one scroll-wheel notch moves the value: a fiftieth of the range, at least one `step`, and a
    /// whole number of steps.
    public func wheelStep(step: Double = 1) -> Double {
        guard step > 0 else { return maximum / 50 }
        return max(step, ((maximum / 50) / step).rounded() * step)
    }

    /// `value` moved by `notches` scroll-wheel notches (`wheelStep`), on the `step` grid, clamped.
    public func wheelNudged(_ value: Double, notches: Double, step: Double = 1) -> Double {
        guard step > 0 else { return moved(value, by: notches * wheelStep(step: step)) }
        return nudged(value, by: notches * wheelStep(step: step) / step, step: step)
    }

    /// `value` moved by `steps` steps of `step` (arrow keys, accessibility increments), rounded and clamped.
    public func nudged(_ value: Double, by steps: Double, step: Double = 1) -> Double {
        let target = value + steps * step
        return limited(step > 0 ? (target / step).rounded() * step : target, from: value)
    }
}
