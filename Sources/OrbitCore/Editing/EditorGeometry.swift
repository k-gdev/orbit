import CoreGraphics
import Foundation

/// Pure geometry for the image editors: where an aspect-fitted image sits in a view, mapping rectangles and
/// points between view space and image pixels, fixed-ratio crops, preview proxies and resize fields.
///
/// Both spaces have their origin at the top left, matching `MarkupDocument`.
public enum EditorGeometry {
    /// `image` scaled to fit inside `view` (never cropped), centered. Zero when either size is empty.
    public static func fittedRect(image: CGSize, in view: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let scale = min(view.width / image.width, view.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A rectangle drawn on the fitted image in `view`, as whole image pixels clamped to the image.
    /// Empty (zero width or height) when it misses the image.
    public static func viewToImage(_ r: CGRect, image: CGSize, view: CGSize) -> CGRect {
        let fitted = fittedRect(image: image, in: view)
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        let scale = image.width / fitted.width
        let r = r.standardized
        func edge(_ value: CGFloat, _ origin: CGFloat, _ limit: CGFloat) -> CGFloat {
            min(max(((value - origin) * scale).rounded(), 0), limit)
        }
        let x0 = edge(r.minX, fitted.minX, image.width), x1 = edge(r.maxX, fitted.minX, image.width)
        let y0 = edge(r.minY, fitted.minY, image.height), y1 = edge(r.maxY, fitted.minY, image.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// An image-pixel rectangle as it appears in `view`.
    public static func imageToView(_ r: CGRect, image: CGSize, view: CGSize) -> CGRect {
        let fitted = fittedRect(image: image, in: view)
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = fitted.width / image.width
        let r = r.standardized
        return CGRect(x: fitted.minX + r.minX * scale, y: fitted.minY + r.minY * scale,
                      width: r.width * scale, height: r.height * scale)
    }

    /// A point in `view` as image pixels (not rounded, not clamped).
    public static func viewToImage(_ p: CGPoint, image: CGSize, view: CGSize) -> CGPoint {
        let fitted = fittedRect(image: image, in: view)
        guard fitted.width > 0 else { return .zero }
        let scale = image.width / fitted.width
        return CGPoint(x: (p.x - fitted.minX) * scale, y: (p.y - fitted.minY) * scale)
    }

    /// An image-pixel point as it appears in `view`.
    public static func imageToView(_ p: CGPoint, image: CGSize, view: CGSize) -> CGPoint {
        let fitted = fittedRect(image: image, in: view)
        guard image.width > 0 else { return .zero }
        let scale = fitted.width / image.width
        return CGPoint(x: fitted.minX + p.x * scale, y: fitted.minY + p.y * scale)
    }

    /// `r` kept inside a canvas of size `within` (origin 0,0) and, when `aspect` (width ÷ height) is given,
    /// reshaped to it. The top-left corner stays put and the width leads; the rectangle shrinks, keeping the
    /// ratio, when the ratio would push it out of the canvas. Sizes are whole pixels.
    public static func constrain(_ r: CGRect, aspect: Double?, within: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: within)
        let clipped = r.standardized.intersection(bounds)
        guard !clipped.isNull else { return CGRect(origin: CGPoint(x: min(max(r.standardized.minX, 0), within.width),
                                                                  y: min(max(r.standardized.minY, 0), within.height)),
                                                   size: .zero) }
        guard let aspect, aspect > 0, clipped.width > 0 else { return clipped }

        let availableW = (within.width - clipped.minX).rounded(.down)
        let availableH = (within.height - clipped.minY).rounded(.down)
        var w = clipped.width
        var h = w / aspect
        if w > availableW { w = availableW; h = w / aspect }
        if h > availableH { h = availableH; w = h * aspect }
        w = min(w.rounded(), availableW)
        h = min(h.rounded(), availableH)
        return CGRect(x: clipped.minX, y: clipped.minY, width: w, height: h)
    }

    /// The crop rectangle for a drag that started at `anchor` (a fixed corner) and is now at `point`, kept
    /// inside a canvas of size `within` and, when `aspect` is given, reshaped to it. The rectangle shrinks
    /// toward the anchor; it never moves it.
    public static func cropRect(anchor: CGPoint, to point: CGPoint, aspect: Double?, within: CGSize) -> CGRect {
        // Mirror the canvas so the anchor is the top left corner, constrain, then mirror back.
        let flipX = point.x < anchor.x, flipY = point.y < anchor.y
        func mirrored(_ p: CGPoint) -> CGPoint {
            CGPoint(x: flipX ? within.width - p.x : p.x, y: flipY ? within.height - p.y : p.y)
        }
        let a = mirrored(anchor), p = mirrored(point)
        let r = constrain(CGRect(x: a.x, y: a.y, width: max(p.x - a.x, 0), height: max(p.y - a.y, 0)),
                          aspect: aspect, within: within)
        return CGRect(x: flipX ? within.width - r.maxX : r.minX, y: flipY ? within.height - r.maxY : r.minY,
                      width: r.width, height: r.height)
    }

    /// The largest rectangle of ratio `aspect` (width ÷ height) that fits in `within`, centered, in whole pixels.
    public static func centeredRect(aspect: Double, within: CGSize) -> CGRect {
        guard aspect > 0, within.width > 0, within.height > 0 else { return .zero }
        var w = within.width, h = w / aspect
        if h > within.height { h = within.height; w = h * aspect }
        w = w.rounded()
        h = h.rounded()
        return CGRect(x: ((within.width - w) / 2).rounded(), y: ((within.height - h) / 2).rounded(), width: w, height: h)
    }

    /// `image` shrunk so its long edge is at most `longEdge` pixels; never enlarged.
    public static func proxySize(for image: CGSize, longEdge: Int) -> CGSize {
        let long = max(image.width, image.height)
        guard long > 0, long > CGFloat(longEdge) else { return image }
        let scale = CGFloat(longEdge) / long
        return CGSize(width: max(1, (image.width * scale).rounded()), height: max(1, (image.height * scale).rounded()))
    }

    /// The size with this width and the original's aspect ratio (at least 1 × 1).
    public static func size(forWidth width: Double, keepingAspectOf original: CGSize) -> CGSize {
        guard original.width > 0, original.height > 0 else { return CGSize(width: max(1, width.rounded()), height: 1) }
        let w = max(1, width.rounded())
        return CGSize(width: w, height: max(1, (w * original.height / original.width).rounded()))
    }

    /// The size with this height and the original's aspect ratio (at least 1 × 1).
    public static func size(forHeight height: Double, keepingAspectOf original: CGSize) -> CGSize {
        guard original.width > 0, original.height > 0 else { return CGSize(width: 1, height: max(1, height.rounded())) }
        let h = max(1, height.rounded())
        return CGSize(width: max(1, (h * original.width / original.height).rounded()), height: h)
    }

    /// The original scaled by a percentage (at least 1 × 1).
    public static func size(forPercent percent: Double, of original: CGSize) -> CGSize {
        CGSize(width: max(1, (original.width * percent / 100).rounded()),
               height: max(1, (original.height * percent / 100).rounded()))
    }
}

/// Rotate and flip buttons act on what the preview shows. `AdjustRenderer` flips the original first and
/// turns it afterwards, so after an odd number of quarter turns a visual horizontal flip is a stored vertical one.
extension AdjustSettings {
    private var turnsAreOdd: Bool { ((quarterTurns % 4) + 4) % 2 == 1 }

    /// Whether the preview is mirrored left to right.
    public var isFlippedHorizontallyInPreview: Bool { turnsAreOdd ? flipVertical : flipHorizontal }
    /// Whether the preview is mirrored top to bottom.
    public var isFlippedVerticallyInPreview: Bool { turnsAreOdd ? flipHorizontal : flipVertical }

    public mutating func flipPreviewHorizontally() {
        if turnsAreOdd { flipVertical.toggle() } else { flipHorizontal.toggle() }
    }

    public mutating func flipPreviewVertically() {
        if turnsAreOdd { flipHorizontal.toggle() } else { flipVertical.toggle() }
    }

    /// One quarter turn, clockwise or counterclockwise; the count stays within 0...3.
    public mutating func rotate(clockwise: Bool) {
        quarterTurns = (((quarterTurns + (clockwise ? 1 : -1)) % 4) + 4) % 4
    }
}
