import Foundation
@testable import OrbitCore

/// Shared test inputs. Later processor tasks append their own generators here.
enum Fixtures {
    /// A new, empty directory under the system temp folder. The caller removes it.
    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "orbit-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        } catch {
            preconditionFailure("Fixtures.tempDir: \(error)")
        }
        return dir
    }

    /// A UserDefaults suite stored as a plist inside its own temp folder (an absolute-path suite
    /// name), so tests never write to ~/Library/Preferences. `cleanup` removes the folder.
    static func defaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let (d, _, cleanup) = defaultsWithFolder()
        return (d, cleanup)
    }

    /// `defaults()` plus the folder that holds the suite's plist.
    static func defaultsWithFolder() -> (defaults: UserDefaults, folder: URL, cleanup: () -> Void) {
        let dir = tempDir()
        let path = dir.appending(path: "prefs", directoryHint: .notDirectory).path
        guard let d = UserDefaults(suiteName: path) else { preconditionFailure("Fixtures.defaults: \(path)") }
        return (d, dir, {
            d.removePersistentDomain(forName: path)
            try? FileManager.default.removeItem(at: dir)
        })
    }

    /// Writes `contents` to `dir/name` (intermediate folders are created). Never overwrites.
    static func file(_ name: String, _ contents: String, in dir: URL) -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            preconditionFailure("Fixtures.file \(name): \(error)")
        }
        return url
    }

    /// Homebrew's ffmpeg, when it is installed and executable.
    static let ffmpeg: URL? = {
        let path = "/opt/homebrew/bin/ffmpeg"
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }()

    static var hasFFmpeg: Bool { ffmpeg != nil }

    /// The helpers really installed on this Mac.
    static let caps: Capabilities = HelperLocator().locate(customFFmpegPath: nil)
}

// MARK: - Images

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension RGBA {
    var isWhite: Bool { r > 0.98 && g > 0.98 && b > 0.98 && a > 0.98 }
}

extension Fixtures {
    /// A solid-colour (or noisy) image of `w`×`h` pixels, written in the format the name's extension says (PNG by default).
    @discardableResult
    static func image(_ name: String, w: Int, h: Int, alpha: Bool = false, noise: Bool = false, in dir: URL) -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info),
              let data = ctx.data else { preconditionFailure("Fixtures.image: no context") }
        if noise {
            var rng = SystemRandomNumberGenerator()
            let buffer = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
            for i in 0..<(ctx.bytesPerRow * h) { buffer[i] = UInt8.random(in: 0...255, using: &rng) }
            if alpha { for y in 0..<h { for x in 0..<w { buffer[y * ctx.bytesPerRow + x * 4 + 3] = 255 } } }
        } else if alpha {
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let cg = ctx.makeImage() else { preconditionFailure("Fixtures.image: no image") }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        writeImage(cg, to: url, type: type, properties: nil)
        return url
    }

    /// A JPEG of stored size `w`×`h` carrying EXIF orientation `orientation`.
    static func jpegWithOrientation(_ orientation: Int, w: Int, h: Int, in dir: URL) -> URL {
        let url = image("tmp-\(UUID().uuidString).jpg", w: w, h: h, in: dir)
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        try? FileManager.default.removeItem(at: url)
        let out = dir.appending(path: "oriented-\(orientation).jpg", directoryHint: .notDirectory)
        writeImage(cg, to: out, type: .jpeg, properties: [kCGImagePropertyOrientation: orientation])
        return out
    }

    /// A simple SVG with intrinsic size `w`×`h`.
    static func svg(w: Int, h: Int, in dir: URL) -> URL {
        file("shape.svg", """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
        <rect width="\(w)" height="\(h)" fill="#cc3311"/></svg>
        """, in: dir)
    }

    /// The pixel at (`x`, `y`), origin top left, as straight RGBA in 0...1.
    static func pixel(_ url: URL, x: Int, y: Int) -> RGBA {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { preconditionFailure("Fixtures.pixel: cannot read \(url.lastPathComponent)") }
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        let p = data.bindMemory(to: UInt8.self, capacity: 4)
        defer { withExtendedLifetime(ctx) {} }
        let a = Double(p[3]) / 255
        func unpremultiplied(_ v: UInt8) -> Double { a == 0 ? 0 : min(1, Double(v) / 255 / a) }
        return RGBA(r: unpremultiplied(p[0]), g: unpremultiplied(p[1]), b: unpremultiplied(p[2]), a: a)
    }

    /// Pixel size of the first image in the file, as stored.
    static func size(_ url: URL) -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return .zero }
        return CGSize(width: w, height: h)
    }

    /// The content type identifier ImageIO detects for the file.
    static func uti(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let t = CGImageSourceGetType(src) else { return "" }
        return t as String
    }

    private static func writeImage(_ cg: CGImage, to url: URL, type: UTType, properties: [CFString: Any]?) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            preconditionFailure("Fixtures.writeImage: no destination for \(type.identifier)")
        }
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else { preconditionFailure("Fixtures.writeImage: finalize failed") }
    }
}

// MARK: - Image tools

import CoreImage
import CoreImage.CIFilterBuiltins

extension Fixtures {
    /// A noisy JPEG (hard to compress) at JPEG quality `q`.
    static func noisyJPEG(_ w: Int, _ h: Int, q: Double = 0.9, in dir: URL) -> URL {
        let noisy = image("noisy-src-\(UUID().uuidString).png", w: w, h: h, noise: true, in: dir)
        defer { try? FileManager.default.removeItem(at: noisy) }
        let cg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(noisy as CFURL, nil)!, 0, nil)!
        let out = dir.appending(path: "noisy-\(UUID().uuidString.prefix(6)).jpg", directoryHint: .notDirectory)
        writeImage(cg, to: out, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: q])
        return out
    }

    /// A small JPEG with GPS (37.33 N, 122.03 W), Make `OrbitCam`, Model `X1`, BodySerialNumber `SN-12345`,
    /// DateTimeOriginal `2024:05:06 07:08:09`, IPTC byline `IPTC Secret` and an XMP packet with dc:subject `XMP Secret`.
    static func jpegWithMetadata(in dir: URL) -> URL {
        let src = image("meta-src-\(UUID().uuidString).png", w: 64, h: 48, noise: true, in: dir)
        defer { try? FileManager.default.removeItem(at: src) }
        let cg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(src as CFURL, nil)!, 0, nil)!
        let out = dir.appending(path: "photo-\(UUID().uuidString.prefix(6)).jpg", directoryHint: .notDirectory)
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "OrbitCam", kCGImagePropertyTIFFModel: "X1"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "SN-12345",
                                             kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: ["IPTC Secret"]],
        ]
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(xmp, kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, nil)
        CGImageMetadataSetValueWithPath(xmp, nil, "dc:subject" as CFString, ["XMP Secret"] as CFArray)
        // ImageIO drops IPTC given next to an XMP tree, so write the properties first and merge the XMP in a second pass.
        let plain = dir.appending(path: "plain-\(UUID().uuidString).jpg", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: plain) }
        writeImage(cg, to: plain, type: .jpeg, properties: props)
        guard let source = CGImageSourceCreateWithURL(plain as CFURL, nil),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            preconditionFailure("Fixtures.jpegWithMetadata: no destination")
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: xmp, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil) else {
            preconditionFailure("Fixtures.jpegWithMetadata: copy failed")
        }
        return out
    }

    /// A small PNG with tEXt/iTXt `Author` = `PNG Secret` and `Description` = `PNG Description Secret`.
    static func pngWithText(in dir: URL) -> URL {
        let src = image("png-src-\(UUID().uuidString).png", w: 40, h: 30, noise: true, in: dir)
        defer { try? FileManager.default.removeItem(at: src) }
        let cg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(src as CFURL, nil)!, 0, nil)!
        let out = dir.appending(path: "text-\(UUID().uuidString.prefix(6)).png", directoryHint: .notDirectory)
        writeImage(cg, to: out, type: .png, properties: [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGAuthor: "PNG Secret",
                                            kCGImagePropertyPNGDescription: "PNG Description Secret"],
        ])
        return out
    }

    /// Decoded RGBA bytes of the first image (for pixel-identity checks).
    static func decodedPixels(_ url: URL) -> Data {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return Data() }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Data(bytes: data, count: cg.width * cg.height * 4)
    }

    /// A PNG QR code for `text`, with a quiet zone.
    static func qr(_ text: String, in dir: URL, name: String = "qr.png") -> URL {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        let code = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let side = Int(code.extent.width) + 80
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let rendered = CIContext().createCGImage(code, from: code.extent)!
        ctx.interpolationQuality = .none
        ctx.draw(rendered, in: CGRect(x: 40, y: 40, width: code.extent.width, height: code.extent.height))
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        writeImage(ctx.makeImage()!, to: url, type: .png, properties: nil)
        return url
    }

    static func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    /// The fraction of pixels with alpha 0 and with alpha 255.
    static func alphaHistogram(_ url: URL) -> (transparent: Double, opaque: Double) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return (0, 0) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let p = data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        var clear = 0, solid = 0
        for i in 0..<(cg.width * cg.height) {
            let a = p[i * 4 + 3]
            if a == 0 { clear += 1 } else if a == 255 { solid += 1 }
        }
        let total = Double(cg.width * cg.height)
        return (Double(clear) / total, Double(solid) / total)
    }
}
