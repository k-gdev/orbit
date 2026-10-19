import CoreGraphics
import Foundation
import ImageIO

/// One image into another format.
public enum ImageConverter {
    static let icoMaxEdge = 256

    @discardableResult
    public static func convert(_ src: URL, to format: OutputFormat, output: URL, options: JobOptions) throws -> SummaryHint? {
        var image = try ImageFile.loadOriented(src)
        let original = CGSize(width: image.width, height: image.height)
        var downscaled = false

        if format == .ico, max(image.width, image.height) > icoMaxEdge {
            image = try scaled(image, toFit: icoMaxEdge)
            downscaled = true
        }
        if (format == .jpg || format == .bmp), ImageFile.hasAlpha(image) {
            image = try flattenedOnWhite(image)
        }

        let quality: Double? = switch format {
        case .jpg: options.jpegQuality
        case .heic: options.heicQuality
        case .webp: options.webpQuality
        case .avif: options.avifQuality
        default: nil
        }
        try ImageFile.write(image, to: output, format: format, quality: quality,
                            properties: carriedProperties(from: ImageFile.properties(src), for: format))

        if downscaled {
            return .dimensions(from: original, to: CGSize(width: image.width, height: image.height))
        }
        return .sizes(before: fileSize(src), after: fileSize(output))
    }

    /// Metadata worth keeping, with the orientation reset because the pixels are already upright.
    static func carriedProperties(from source: [CFString: Any], for format: OutputFormat) -> [CFString: Any]? {
        guard ![.gif, .bmp, .ico, .webp].contains(format) else { return nil }
        var result: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary] {
            if let dict = source[key] as? [CFString: Any] { result[key] = dict }
        }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            result[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let w = source[kCGImagePropertyDPIWidth] { result[kCGImagePropertyDPIWidth] = w }
        if let h = source[kCGImagePropertyDPIHeight] { result[kCGImagePropertyDPIHeight] = h }
        result[kCGImagePropertyOrientation] = 1
        return result
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func context(width: Int, height: Int, opaque: Bool) throws -> CGContext {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else {
            throw OrbitError.unsupported("Orbit couldn't prepare this image.")
        }
        ctx.interpolationQuality = .high
        return ctx
    }

    private static func finish(_ ctx: CGContext) throws -> CGImage {
        guard let image = ctx.makeImage() else { throw OrbitError.unsupported("Orbit couldn't prepare this image.") }
        return image
    }

    private static func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        let ctx = try context(width: image.width, height: image.height, opaque: true)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return try finish(ctx)
    }

    private static func scaled(_ image: CGImage, toFit edge: Int) throws -> CGImage {
        let factor = Double(edge) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * factor).rounded()))
        let h = max(1, Int((Double(image.height) * factor).rounded()))
        let ctx = try context(width: w, height: h, opaque: false)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return try finish(ctx)
    }
}
