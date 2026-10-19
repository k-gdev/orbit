import CoreGraphics
import Foundation

/// Shared sRGB 8-bit bitmap helpers for the image processors.
enum ImageBitmap {
    static let failure = OrbitError.unsupported("Orbit couldn't prepare this image.")

    /// An sRGB 8-bit bitmap context (premultiplied alpha, or opaque with the alpha byte skipped).
    static func makeContext(width: Int, height: Int, opaque: Bool) throws -> CGContext {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { throw failure }
        ctx.interpolationQuality = .high
        return ctx
    }

    /// The image composited over opaque white, with no alpha channel.
    static func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        let ctx = try makeContext(width: image.width, height: image.height, opaque: true)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let result = ctx.makeImage() else { throw failure }
        return result
    }

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
