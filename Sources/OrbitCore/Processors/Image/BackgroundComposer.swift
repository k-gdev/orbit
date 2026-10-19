import CoreGraphics
import CoreImage
import Foundation

/// Puts a cut-out subject on a solid colour, a gradient, or a blurred copy of the original photo.
/// The result is always opaque and as large as the subject.
public enum BackgroundComposer {
    public static func compose(subject: CGImage, original: CGImage?, style: BackgroundStyle) throws -> CGImage {
        let w = subject.width, h = subject.height
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let ctx = try ImageBitmap.makeContext(width: w, height: h, opaque: true)

        // Translucent backgrounds land on white so the output stays opaque.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)

        switch style {
        case .solid(let color):
            ctx.setFillColor(ImageBitmap.cgColor(color))
            ctx.fill(rect)
        case .gradient(let top, let bottom):
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let colors = [ImageBitmap.cgColor(top), ImageBitmap.cgColor(bottom)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else {
                throw OrbitError.unsupported("Orbit couldn't draw this background.")
            }
            // Bitmap contexts have y up, so the first colour sits at y = h (the top).
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
        case .blur(let radius):
            ctx.draw(try blurred(original ?? subject, radius: radius, width: w, height: h), in: rect)
        }

        ctx.draw(subject, in: rect)
        guard let result = ctx.makeImage() else { throw OrbitError.unsupported("Orbit couldn't add this background.") }
        return result
    }

    /// `image` blurred and scaled to cover `width`×`height`, with edges extended so they stay solid.
    private static func blurred(_ image: CGImage, radius: Double, width: Int, height: Int) throws -> CGImage {
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        var ci = CIImage(cgImage: image)
        let source = ci.extent
        ci = ci.clampedToExtent().applyingGaussianBlur(sigma: max(radius, 0)).cropped(to: source)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaled = ci.extent
        let dx = (scaled.width - Double(width)) / 2 + scaled.minX
        let dy = (scaled.height - Double(height)) / 2 + scaled.minY
        ci = ci.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let result = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                     format: .RGBA8, colorSpace: space) else {
            throw OrbitError.unsupported("Orbit couldn't blur this image.")
        }
        return result
    }
}
