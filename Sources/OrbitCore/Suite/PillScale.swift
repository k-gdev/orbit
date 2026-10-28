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

    /// `value` moved by `steps` steps of `step` (scroll wheel, arrow keys), rounded and clamped.
    public func nudged(_ value: Double, by steps: Double, step: Double = 1) -> Double {
        let moved = value + steps * step
        let rounded = step > 0 ? (moved / step).rounded() * step : moved
        return clamped(rounded)
    }
}
