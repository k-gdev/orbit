import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import OrbitCore

/// Pixel-level helpers for the image editor tests (markup, adjust, background).
struct EditPixel: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    static let black = EditPixel(r: 0, g: 0, b: 0, a: 1)
    static let white = EditPixel(r: 1, g: 1, b: 1, a: 1)
    static let red = EditPixel(r: 1, g: 0, b: 0, a: 1)
    static let blue = EditPixel(r: 0, g: 0, b: 1, a: 1)

    /// Equal within about 2/255 per channel.
    static func == (l: EditPixel, r: EditPixel) -> Bool {
        abs(l.r - r.r) < 0.01 && abs(l.g - r.g) < 0.01 && abs(l.b - r.b) < 0.01 && abs(l.a - r.a) < 0.01
    }
}

extension Fixtures {
    /// Premultiplied RGBA bytes (origin top left) of `image` drawn into an sRGB bitmap.
    static func editBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func editPixel(_ image: CGImage, _ x: Int, _ y: Int) -> EditPixel {
        let bytes = editBytes(image)
        let i = (y * image.width + x) * 4
        let a = Double(bytes[i + 3]) / 255
        func channel(_ v: UInt8) -> Double { a == 0 ? 0 : min(1, Double(v) / 255 / a) }
        return EditPixel(r: channel(bytes[i]), g: channel(bytes[i + 1]), b: channel(bytes[i + 2]), a: a)
    }

    /// An image built by `draw` in a top-left-origin coordinate space.
    static func editImage(_ w: Int, _ h: Int, opaque: Bool = true, _ draw: (CGContext) -> Void) -> CGImage {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        return ctx.makeImage()!
    }

    static func editSolid(_ w: Int, _ h: Int, r: Double, g: Double, b: Double) -> CGImage {
        editImage(w, h) { ctx in
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    static func editWhite(_ w: Int, _ h: Int) -> CGImage { editSolid(w, h, r: 1, g: 1, b: 1) }

    /// A smooth colour ramp that stands in for a photo.
    static func editPhoto(_ w: Int, _ h: Int) -> CGImage {
        editImage(w, h) { ctx in
            for x in 0..<w {
                let t = Double(x) / Double(max(w - 1, 1))
                ctx.setFillColor(CGColor(srgbRed: 0.15 + 0.7 * t, green: 0.6 - 0.3 * t, blue: 0.2 + 0.5 * (1 - t), alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
            }
        }
    }

    static func editColorful(_ w: Int, _ h: Int) -> CGImage { editSolid(w, h, r: 0.9, g: 0.3, b: 0.1) }

    /// An opaque blue square in the middle of a transparent `size`×`size` image.
    static func editSquareOnTransparent(_ size: Int) -> CGImage {
        editImage(size, size, opaque: false) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        }
    }

    static func editNonWhiteCount(_ image: CGImage) -> Int {
        let bytes = editBytes(image)
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 250 || bytes[$0 + 1] < 250 || bytes[$0 + 2] < 250 }.count
    }

    static func editMaxDiff(_ a: CGImage, _ b: CGImage) -> Int {
        let x = editBytes(a), y = editBytes(b)
        guard x.count == y.count else { return Int.max }
        return zip(x, y).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    static func editMinAlpha(_ image: CGImage) -> Double {
        let bytes = editBytes(image)
        return Double(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.min() ?? 0) / 255
    }

    static func writeEditPNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
