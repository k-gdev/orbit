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
