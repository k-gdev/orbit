import CoreGraphics

/// Where the shelf window goes. All frames are in screen coordinates (y up), and `visible` is a screen's
/// visible frame (below the menu bar, above the Dock); frames with negative origins work.
public enum ShelfPlacement {
    /// The size of a shelf that has not been resized.
    public static let defaultSize = CGSize(width: 440, height: 168)
    /// The smallest the shelf can be resized to.
    public static let minimumSize = CGSize(width: 300, height: 132)
    /// The gap kept below the shelf when it opens at the bottom of the screen.
    public static let bottomMargin: CGFloat = 24

    /// A frame of `size` centred on `point` (the pointer), moved to lie inside `visible`. A shelf larger
    /// than the screen shrinks to it.
    public static func frame(size: CGSize, centeredOn point: CGPoint, in visible: CGRect) -> CGRect {
        let centred = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                             width: size.width, height: size.height)
        return clamped(centred, in: visible)
    }

    /// Where the shelf opens when nothing says otherwise (from the menu bar): bottom centre of the screen.
    public static func defaultFrame(size: CGSize, in visible: CGRect) -> CGRect {
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.minY + bottomMargin,
                           width: size.width, height: size.height)
        return clamped(frame, in: visible)
    }

    /// A remembered frame, pulled back onto `visible` (the display it was on may be gone).
    public static func restored(_ saved: CGRect, in visible: CGRect) -> CGRect {
        clamped(saved, in: visible)
    }

    /// `frame` shrunk to fit inside `visible` and shifted until it lies within it.
    public static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
