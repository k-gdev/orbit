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
            try PDFWriter.write(count: 1, to: url) { _ in PDFPageImage(image: image, dpi: dpi) }
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

    /// The picture for one PDF page made from the image file at `url`. A JPEG (RGB or grey) keeps
    /// its compressed data (DCT passthrough, R36): it is not decoded or re-encoded, its EXIF
    /// orientation is applied when the page is drawn, and its metadata segments (EXIF, GPS, XMP,
    /// IPTC, thumbnails) are cut out first so none of it reaches the PDF. Anything else is decoded
    /// upright and embedded losslessly.
    static func pdfPage(_ url: URL) throws -> PDFPageImage {
        let props = properties(url)
        let dpi = dpi(from: props)
        if let image = jpegPassthrough(url, properties: props) {
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            return PDFPageImage(image: image, dpi: dpi, orientation: (1...8).contains(orientation) ? orientation : 1)
        }
        return PDFPageImage(image: try loadOriented(url), dpi: dpi)
    }

    /// The JPEG's own DCT data, metadata removed, as a CGImage Quartz embeds without re-encoding.
    /// Nil for anything that isn't an RGB or greyscale JPEG (CMYK JPEGs take the decode path).
    private static func jpegPassthrough(_ url: URL, properties props: [CFString: Any]) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier,
              let model = props[kCGImagePropertyColorModel] as? String,
              model == (kCGImagePropertyColorModelRGB as String) || model == (kCGImagePropertyColorModelGray as String),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let clean = JPEGSegments.strippingMetadata(data),
              let provider = CGDataProvider(data: clean as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        return image
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

/// One PDF page's picture. `orientation` is the EXIF orientation applied while drawing (1 when the
/// pixels are already upright).
struct PDFPageImage {
    var image: CGImage
    var dpi: Double
    var orientation: Int = 1

    /// The page size in pixels, after orientation (5–8 swap width and height).
    var displayPixels: (width: Int, height: Int) {
        orientation >= 5 ? (image.height, image.width) : (image.width, image.height)
    }

    /// Maps the stored image, drawn at (0, 0, width, height), onto the upright page (y-up, pixels).
    var orientationTransform: CGAffineTransform {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return .identity
        }
    }
}

/// Image-only PDFs: one page per image, each page as large as the image at its DPI.
enum PDFWriter {
    /// Streams `count` pages: `page(i)` is called, drawn and released before the next, so memory
    /// stays at one image regardless of the batch size.
    static func write(count: Int, to url: URL, page: (Int) throws -> PDFPageImage) throws {
        guard count > 0 else { throw OrbitError.unsupported("There are no images to put in a PDF.") }
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw OrbitError.unsupported("Orbit couldn't create this PDF.")
        }
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let picture = try page(index)
                let scale = 72 / picture.dpi
                let pixels = picture.displayPixels
                var box = CGRect(x: 0, y: 0, width: Double(pixels.width) * scale, height: Double(pixels.height) * scale)
                let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                context.beginPDFPage(pageInfo)
                context.saveGState()
                context.scaleBy(x: scale, y: scale)
                context.concatenate(picture.orientationTransform)
                context.draw(picture.image, in: CGRect(x: 0, y: 0, width: picture.image.width, height: picture.image.height))
                context.restoreGState()
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
