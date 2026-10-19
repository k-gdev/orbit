// Composites the Orbit app icon: the ringed-planet mark from the logo, centred on a cream
// macOS-grid rounded square (824 pt body in a 1024 canvas, corner radius 185).
//
//     swift scripts/make-icon.swift <logo.png> <out-1024.png>
//
// The mark is cut out of the logo's cream background by colour distance and repainted in one flat
// purple, so the icon has no halo and no JPEG-ish noise from the source.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: make-icon.swift <logo.png> <out-1024.png>") }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(args[1])") }
guard logo.width == 1254, logo.height == 1254 else { fail("expected a 1254x1254 logo, got \(logo.width)x\(logo.height)") }

// Pixels of the whole logo, RGBA, origin top left.
let W = logo.width, H = logo.height
var pixels = [UInt8](repeating: 0, count: W * H * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue
pixels.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: space, bitmapInfo: info)!
    ctx.draw(logo, in: CGRect(x: 0, y: 0, width: W, height: H))
}

func average(x: Int, y: Int, size: Int) -> (Double, Double, Double) {
    var r = 0.0, g = 0.0, b = 0.0
    for j in y..<(y + size) { for i in x..<(x + size) {
        let o = (j * W + i) * 4
        r += Double(pixels[o]); g += Double(pixels[o + 1]); b += Double(pixels[o + 2])
    } }
    let n = Double(size * size)
    return (r / n / 255, g / n / 255, b / n / 255)
}

let cream = average(x: 20, y: 20, size: 40)        // paper, top left corner
let purple = average(x: 560, y: 420, size: 40)     // inside the planet body

// Mark bounds in the logo (planet + ring, without the wordmark), with a little air.
let crop = (x: 190, y: 290, w: 880, h: 510)
let dir = (purple.0 - cream.0, purple.1 - cream.1, purple.2 - cream.2)
let norm = dir.0 * dir.0 + dir.1 * dir.1 + dir.2 * dir.2

// Alpha of one source pixel: how far along cream -> purple it is.
func coverage(_ i: Int, _ j: Int) -> Double {
    let o = (j * W + i) * 4
    let d = (Double(pixels[o]) / 255 - cream.0, Double(pixels[o + 1]) / 255 - cream.1, Double(pixels[o + 2]) / 255 - cream.2)
    let raw = (d.0 * dir.0 + d.1 * dir.1 + d.2 * dir.2) / norm
    // Dead zone: paper noise stays fully transparent instead of leaving a faint box.
    return min(max((raw - 0.08) / 0.84, 0), 1)
}

// The mark as a premultiplied RGBA image: flat purple with that coverage.
var mark = [UInt8](repeating: 0, count: crop.w * crop.h * 4)
for j in 0..<crop.h { for i in 0..<crop.w {
    let a = coverage(crop.x + i, crop.y + j)
    let o = (j * crop.w + i) * 4
    mark[o] = UInt8((purple.0 * a * 255).rounded())
    mark[o + 1] = UInt8((purple.1 * a * 255).rounded())
    mark[o + 2] = UInt8((purple.2 * a * 255).rounded())
    mark[o + 3] = UInt8((a * 255).rounded())
} }
let markImage: CGImage = mark.withUnsafeMutableBytes { raw in
    CGContext(data: raw.baseAddress, width: crop.w, height: crop.h, bitsPerComponent: 8, bytesPerRow: crop.w * 4,
              space: space, bitmapInfo: info)!.makeImage()!
}

// Canvas.
let size = 1024
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
out.interpolationQuality = .high
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the body, the way system icons carry one.
out.saveGState()
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
out.setFillColor(CGColor(srgbRed: cream.0, green: cream.1, blue: cream.2, alpha: 1))
out.addPath(bodyPath); out.fillPath()
out.restoreGState()

// The mark, centred in the body: 70 % of the body width.
let targetW = body.width * 0.70
let scale = targetW / CGFloat(crop.w)
let markRect = CGRect(x: body.midX - targetW / 2, y: body.midY - CGFloat(crop.h) * scale / 2,
                      width: targetW, height: CGFloat(crop.h) * scale)
out.saveGState()
out.addPath(bodyPath); out.clip()
out.draw(markImage, in: markRect)
out.restoreGState()

guard let result = out.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("cannot write \(args[2])") }
CGImageDestinationAddImage(dest, result, nil)
guard CGImageDestinationFinalize(dest) else { fail("PNG encode failed") }
print("wrote \(args[2])")
