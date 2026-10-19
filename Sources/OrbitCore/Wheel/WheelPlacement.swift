import CoreGraphics

public enum WheelPlacement {
    /// Wheel centre for a pointer position, clamped so the whole circle of `radius`
    /// lies inside `visibleFrame` (works for frames with negative origins). If the
    /// frame is smaller than the circle on an axis, the circle is centred on that axis.
    public static func center(for pointer: CGPoint, radius: CGFloat, in visibleFrame: CGRect) -> CGPoint {
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi)
        }
        return CGPoint(
            x: clamp(pointer.x, visibleFrame.minX + radius, visibleFrame.maxX - radius),
            y: clamp(pointer.y, visibleFrame.minY + radius, visibleFrame.maxY - radius))
    }
}
