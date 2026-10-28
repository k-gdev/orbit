import Foundation

/// The geometry of a `PillSlider` track, Control Center style: the fill is never narrower than a circle
/// of the track's height (it carries the leading icon), and it grows from there to the full width. A
/// drag puts the centre of the fill's rounded end under the pointer. Values go through `PillScale`.
public struct PillTrack: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// How far the fill's end can travel.
    public var travel: Double { max(width - height, 0) }

    /// The fill's width for a track fraction (0...1, clamped).
    public func fillWidth(forFraction fraction: Double) -> Double {
        min(height + min(max(fraction, 0), 1) * travel, width)
    }

    /// The track fraction (0...1) for a pointer at `x` from the track's leading edge.
    public func fraction(atX x: Double) -> Double {
        guard travel > 0 else { return 0 }
        return min(max((x - height / 2) / travel, 0), 1)
    }
}
