import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks an image toward a size target by lowering quality, then resolution.
public enum ImageCompressor {
    private static let lossy: Set<OutputFormat> = [.jpg, .heic, .webp, .avif]

    /// jpg, heic, webp and avif keep their format (when this Mac can write it); everything else is
    /// PNG when it has alpha, JPG when it hasn't.
    public static func outputFormat(for item: DroppedItem, hasAlpha: Bool,
                                    canWrite: (OutputFormat) -> Bool = ImageFile.canWrite) -> OutputFormat {
        let kept: OutputFormat? = switch item.formatKey {
        case "jpg": .jpg
        case "heic": .heic
        case "webp": .webp
        case "avif": .avif
        default: nil
        }
        if let kept, canWrite(kept) { return kept }
        return hasAlpha ? .png : .jpg
    }

    /// Writes the compressed image to `to` and returns the file sizes. Throws `.targetTooSmall`
    /// (and writes nothing) when no combination of quality and scale reaches the target.
    public static func compress(_ src: URL, target: CompressTarget, format: OutputFormat, to: URL,
                                options: JobOptions) throws -> (before: Int64, after: Int64) {
        let before = Int64(try src.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let targetBytes: Int64 = switch target {
        case .tier(let tier): Int64((Double(before) * tier.targetFraction).rounded(.down))
        case .fitUnder(let bytes): bytes
        }

        var image = try ImageFile.loadOriented(src)
        if format == .jpg, ImageFile.hasAlpha(image) { image = try ImageBitmap.flattenedOnWhite(image) }
        let properties = ImageConverter.carriedProperties(from: ImageFile.properties(src), for: format)
        let isLossy = lossy.contains(format)

        var best: Data?
        if isLossy {
            // The highest quality that fits, by bisection.
            var low = 0.05, high = 0.95
            for _ in 0..<7 {
                try Task.checkCancellation()
                let mid = (low + high) / 2
                let data = try encode(image, format: format, quality: mid, properties: properties)
                if Int64(data.count) <= targetBytes { best = data; low = mid } else { high = mid }
            }
        } else {
            let data = try encode(image, format: format, quality: nil, properties: properties)
            if Int64(data.count) <= targetBytes { best = data }
        }

        var current = image
        var step = 0
        while best == nil, step < 10 {
            try Task.checkCancellation()
            step += 1
            current = try scaled(current, by: 0.8)
            let data = try encode(current, format: format, quality: isLossy ? 0.6 : nil, properties: properties)
            if Int64(data.count) <= targetBytes { best = data }
        }

        guard let data = best else {
            throw OrbitError.targetTooSmall("Can't get this image under \(targetBytes) bytes.")
        }
        try data.write(to: to, options: .withoutOverwriting)
        return (before, Int64(data.count))
    }

    private static func encode(_ image: CGImage, format: OutputFormat, quality: Double?,
                               properties: [CFString: Any]?) throws -> Data {
        if format == .webp { return try WebPEncoder.encode(image, quality: quality ?? 0.8) }
        let type: UTType? = switch format {
        case .jpg: .jpeg
        case .heic: .heic
        case .avif: UTType("public.avif")
        default: .png
        }
        let data = NSMutableData()
        guard let type, let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw OrbitError.unsupported("Orbit can't write \(format.label) images on this Mac.")
        }
        var merged = properties ?? [:]
        if let quality { merged[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, merged as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OrbitError.unsupported("Orbit couldn't compress this image.")
        }
        return data as Data
    }

    private static func scaled(_ image: CGImage, by factor: Double) throws -> CGImage {
        let w = max(1, Int((Double(image.width) * factor).rounded()))
        let h = max(1, Int((Double(image.height) * factor).rounded()))
        let ctx = try ImageBitmap.makeContext(width: w, height: h, opaque: !ImageFile.hasAlpha(image))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = ctx.makeImage() else { throw OrbitError.unsupported("Orbit couldn't prepare this image.") }
        return result
    }
}
