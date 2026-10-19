import CoreGraphics
import Foundation
import ImageIO

/// Several images in a square-celled grid on a white canvas.
public enum CollageMaker {
    static let canvasWidth = 2048
    static let gutter = 8

    /// Whether any source has an alpha channel (the collage is then a PNG, otherwise a JPG).
    public static func anyHasAlpha(_ srcs: [URL]) -> Bool {
        srcs.contains { (ImageFile.properties($0)[kCGImagePropertyHasAlpha] as? Bool) ?? false }
    }

    /// Writes the collage (format from `to`'s extension) and returns its size.
    @discardableResult
    public static func make(_ srcs: [URL], to: URL, quality: Double = 0.85) throws -> CGSize {
        guard !srcs.isEmpty else { throw OrbitError.unsupported("There are no images to put in a collage.") }
        let cols = Int(ceil(Double(srcs.count).squareRoot()))
        let rows = (srcs.count + cols - 1) / cols
        let cell = (canvasWidth - gutter * (cols + 1)) / cols
        let height = rows * cell + (rows + 1) * gutter
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: canvasWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw OrbitError.unsupported("Orbit couldn't make this collage.")
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: height))
        ctx.interpolationQuality = .high

        for (index, url) in srcs.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let image = try ImageFile.loadOriented(url)
                let row = index / cols, col = index % cols
                let x = gutter + col * (cell + gutter)
                let y = height - (gutter + (row + 1) * cell + row * gutter) // origin is bottom left
                let cellRect = CGRect(x: x, y: y, width: cell, height: cell)
                let scale = Double(cell) / Double(min(image.width, image.height))
                let w = Double(image.width) * scale, h = Double(image.height) * scale
                ctx.saveGState()
                ctx.clip(to: cellRect)
                ctx.draw(image, in: CGRect(x: cellRect.midX - w / 2, y: cellRect.midY - h / 2, width: w, height: h))
                ctx.restoreGState()
            }
        }
        guard let canvas = ctx.makeImage() else { throw OrbitError.unsupported("Orbit couldn't make this collage.") }
        let format: OutputFormat = to.pathExtension.lowercased() == "png" ? .png : .jpg
        try ImageFile.write(canvas, to: to, format: format, quality: format == .jpg ? quality : nil, properties: nil)
        return CGSize(width: canvasWidth, height: height)
    }
}
