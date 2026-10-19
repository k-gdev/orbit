import Foundation

/// Pure hit-testing maths for the wheel. Offsets are relative to the wheel centre;
/// `dy` points UP (Cocoa convention). Angle 0 is straight up, increasing clockwise.
public struct WheelGeometry: Sendable, Equatable {
    public var deadZoneRadius: Double = 52
    public var outerRadius: Double = 170
    public var hitMargin: Double = 60
    public var subRingSliceDegrees: Double = 26.0

    public var subRingInner: Double { outerRadius + 10 }
    public var subRingOuter: Double { outerRadius + 92 }
    public var panelSide: Double { 2 * (subRingOuter + hitMargin) }

    public static let standard = WheelGeometry()

    public init() {}

    public func angle(of offset: CGVector) -> Double {
        var deg = atan2(Double(offset.dx), Double(offset.dy)) * 180 / .pi
        if deg < 0 { deg += 360 }
        if deg >= 360 { deg -= 360 }
        return deg
    }

    public func sliceIndex(offset: CGVector, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let r = hypot(Double(offset.dx), Double(offset.dy))
        guard r > deadZoneRadius, r <= outerRadius + hitMargin else { return nil }
        let width = 360.0 / Double(count)
        return Int((angle(of: offset) + width / 2) / width) % count
    }

    public func centerAngle(index: Int, count: Int) -> Double {
        360.0 / Double(count) * Double(index)
    }

    public func subRingIndex(offset: CGVector, parentIndex: Int, parentCount: Int, childCount: Int) -> Int? {
        guard childCount > 0, parentCount > 0 else { return nil }
        let r = hypot(Double(offset.dx), Double(offset.dy))
        guard r > outerRadius, r <= subRingOuter + hitMargin else { return nil }
        let span = Double(childCount) * subRingSliceDegrees
        let start = centerAngle(index: parentIndex, count: parentCount) - span / 2
        var delta = (angle(of: offset) - start).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        guard delta < span else { return nil }
        return min(Int(delta / subRingSliceDegrees), childCount - 1)
    }
}
