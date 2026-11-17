import Foundation

/// How an app's volume percentage (0…150) becomes the linear gain applied to its samples.
///
/// Below 100 the curve is a square law, so the slider feels even to the ear (50 % is about −12 dB
/// rather than −6 dB). From 100 to 150 it is linear, up to 1.5× (about +3.5 dB) of boost; past 1.0
/// the samples also go through `SoftClip` so a boosted app never hard-clips. Monotonic, 0 → 0,
/// 100 → 1, 150 → 1.5.
public enum VolumeCurve {
    public static func gain(forPercent percent: Double) -> Float {
        guard !percent.isNaN else { return 0 }
        let p = min(max(percent, 0), 150) / 100
        return Float(p <= 1 ? p * p : p)
    }
}

/// A soft limiter for boosted audio: samples up to the knee (0.9) pass untouched; above it they bend
/// along a tanh curve towards full scale, which they never exceed. Continuous with slope 1 at the knee,
/// monotonic and symmetric.
public enum SoftClip {
    public static let knee: Float = 0.9

    @inline(__always)
    public static func apply(_ x: Float) -> Float {
        guard !x.isNaN else { return 0 }
        let a = abs(x)
        guard a > knee else { return x }
        let headroom = 1 - knee
        let y = min(knee + headroom * tanh((a - knee) / headroom), 1)
        return x < 0 ? -y : y
    }
}

/// A per-frame linear ramp from the current gain to `target`, so volume and mute changes never click.
/// Moves `1 / rampFrames` of gain per frame (480 frames ≈ 10 ms at 48 kHz for a full 0 → 1 change) and
/// lands exactly on the target. Lives on the audio thread: no allocation, no locks.
public struct GainRamp: Sendable {
    public private(set) var current: Float
    /// Where the ramp is heading. Non-finite targets are ignored.
    public var target: Float
    public let step: Float

    public init(gain: Float, rampFrames: Int = 480) {
        current = gain.isFinite ? gain : 0
        target = current
        step = 1 / Float(max(rampFrames, 1))
    }

    /// The gain for the next frame.
    @inline(__always)
    public mutating func next() -> Float {
        guard target.isFinite, current != target else { return current }
        if current < target {
            let moved = current + step
            current = moved >= target - step * 0.5 ? target : moved
        } else {
            let moved = current - step
            current = moved <= target + step * 0.5 ? target : moved
        }
        return current
    }
}
