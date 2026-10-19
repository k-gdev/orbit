import CoreGraphics
import Foundation
import libwebp

/// WebP encoding through the bundled libwebp (ImageIO can read WebP but not write it).
public enum WebPEncoder {
    /// WebP's hard limit per side.
    static let maxDimension = 16383

    /// Lossy WebP at `quality` 0...1 (libwebp takes 0...100). Alpha is kept.
    public static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let width = image.width
        let height = image.height
        guard width <= maxDimension, height <= maxDimension else {
            throw OrbitError.unsupported("WebP can't be larger than \(maxDimension) pixels on a side.")
        }
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = ctx.data else {
            throw OrbitError.unsupported("Orbit couldn't prepare this image for WebP.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // `ctx` owns the pixel buffer, so it must outlive every use of `pixels`.
        return try withExtendedLifetime(ctx) {
            // CoreGraphics holds premultiplied colour; WebPEncodeRGBA wants straight alpha.
            let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                let a = Int(pixels[i + 3])
                guard a != 0, a != 255 else { continue }
                for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
            }

            var output: UnsafeMutablePointer<UInt8>?
            let size = WebPEncodeRGBA(pixels, Int32(width), Int32(height), Int32(width * 4),
                                      Float(min(1, max(0, quality)) * 100), &output)
            guard size > 0, let output else { throw OrbitError.unsupported("Orbit couldn't write this WebP.") }
            defer { WebPFree(output) }
            return Data(bytes: output, count: size)
        }
    }
}
