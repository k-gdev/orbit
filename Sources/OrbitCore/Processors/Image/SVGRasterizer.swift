import AppKit
import CoreGraphics
import Foundation

/// Renders an SVG through `NSImage`, which ImageIO cannot read.
public enum SVGRasterizer {
    /// Shortest allowed long edge, in pixels, so small icons stay sharp.
    static let minimumLongEdge: CGFloat = 1024

    /// Rasterizes at 2× the intrinsic size, enlarged further if the long edge would be under 1024 px.
    public static func rasterize(_ url: URL) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw OrbitError.unsupported("Orbit can't read this SVG.")
        }
        let longEdge = max(image.size.width, image.size.height)
        let scale = max(2, minimumLongEdge / longEdge)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw OrbitError.unsupported("Orbit can't read this SVG.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = rep.cgImage else { throw OrbitError.unsupported("Orbit can't read this SVG.") }
        return cg
    }
}
