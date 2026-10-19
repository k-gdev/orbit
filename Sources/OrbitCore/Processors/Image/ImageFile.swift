import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading and writing single images with ImageIO (plus libwebp and the SVG rasterizer).
public enum ImageFile {
    /// The image at full size with its EXIF orientation applied to the pixels. SVG is rasterized.
    public static func loadOriented(_ url: URL) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" { return try SVGRasterizer.rasterize(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw OrbitError.unsupported("Orbit can't read this image.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OrbitError.unsupported("Orbit can't read this image.")
        }
        return image
    }

    /// The first image's metadata dictionary (empty for SVG and unreadable files).
    public static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        return props
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Writes `image` in `format`. `quality` (0...1) applies to the lossy formats; `properties` is
    /// the metadata to embed (see `ImageConverter` for how it is prepared).
    public static func write(_ image: CGImage, to url: URL, format: OutputFormat, quality: Double?,
                             properties: [CFString: Any]?) throws {
        switch format {
        case .webp:
            let data = try WebPEncoder.encode(image, quality: quality ?? 0.8)
            try data.write(to: url, options: .withoutOverwriting)
        case .pdf:
            let dpi = dpi(from: properties ?? [:])
            try PDFWriter.write(count: 1, to: url) { _ in (image, dpi) }
        case .ico:
            try ICOWriter.write(image, to: url)
        default:
            guard let type = imageType(for: format) else {
                throw OrbitError.unsupported("Orbit can't write \(format.label) images.")
            }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw OrbitError.unsupported("Orbit can't write \(format.label) images on this Mac.")
            }
            var merged = properties ?? [:]
            if let quality { merged[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(destination, image, merged as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw OrbitError.unsupported("Orbit couldn't write this \(format.label) image.")
            }
        }
    }

    /// Pixels per inch from a metadata dictionary; 72 when it says nothing sensible.
    static func dpi(from properties: [CFString: Any]) -> Double {
        let value = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
        return value >= 1 ? value : 72
    }

    private static func imageType(for format: OutputFormat) -> UTType? {
        switch format {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        case .avif: UTType("public.avif")
        default: nil
        }
    }
}

/// Image-only PDFs: one page per image, each page as large as the image at its DPI.
enum PDFWriter {
    /// Streams `count` pages: `page(i)` is called, drawn and released before the next, so memory
    /// stays at one image regardless of the batch size.
    static func write(count: Int, to url: URL, page: (Int) throws -> (image: CGImage, dpi: Double)) throws {
        guard count > 0 else { throw OrbitError.unsupported("There are no images to put in a PDF.") }
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw OrbitError.unsupported("Orbit couldn't create this PDF.")
        }
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let (image, dpi) = try page(index)
                var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
                let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                context.beginPDFPage(pageInfo)
                context.draw(image, in: box)
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
}

/// ICO files with one PNG-compressed image. ImageIO's own ICO encoder only accepts a few square
/// sizes, so the (up to 256 px) image is wrapped in the ICO container by hand.
enum ICOWriter {
    static func write(_ image: CGImage, to url: URL) throws {
        guard image.width <= 256, image.height <= 256 else {
            throw OrbitError.unsupported("ICO images can't be larger than 256 pixels.")
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw OrbitError.unsupported("Orbit can't write ICO images on this Mac.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OrbitError.unsupported("Orbit couldn't write this ICO image.")
        }

        var data = Data()
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append16(0)          // reserved
        append16(1)          // type: icon
        append16(1)          // image count
        data.append(UInt8(image.width == 256 ? 0 : image.width))
        data.append(UInt8(image.height == 256 ? 0 : image.height))
        data.append(0)       // palette size
        data.append(0)       // reserved
        append16(1)          // colour planes
        append16(32)         // bits per pixel
        append32(UInt32(png.length))
        append32(22)         // offset: 6-byte header + 16-byte entry
        data.append(png as Data)
        try data.write(to: url, options: .withoutOverwriting)
    }
}
