import AppKit
import OrbitCore

/// Hidden command-line mode: renders the menu bar glyph (idle and busy), black on light and white on
/// dark, at 12x to a PNG.
///
///     Orbit --snapshot-glyph <out.png> [--replace]
enum GlyphSnapshot {
    static let flag = "--snapshot-glyph"
    static let usage = "usage: Orbit --snapshot-glyph <out.png> [--replace]"

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard let start = arguments.firstIndex(of: flag) else { return }
        let rest = Array(arguments[(start + 1)...])
        guard let path = rest.first, !path.hasPrefix("--") else {
            FileHandle.standardError.write(Data("missing output path\n\(usage)\n".utf8))
            exit(64)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: path)
        let replace = rest.contains("--replace")
        if FileManager.default.fileExists(atPath: path), !replace {
            FileHandle.standardError.write(Data("\(path) exists (pass --replace to overwrite it)\n".utf8))
            exit(1)
        }
        let scale = 12, cell = Int(OrbitGlyph.side) * scale, pad = 24
        let width = pad * 3 + cell * 2, height = pad * 3 + cell * 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else {
            FileHandle.standardError.write(Data("cannot create bitmap\n".utf8))
            exit(1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        // Rows: light bar (black glyph), dark bar (white glyph). Columns: idle, busy.
        for (row, dark) in [false, true].enumerated() {
            ctx.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.94, alpha: 1))
            ctx.fill(CGRect(x: 0, y: height - (row + 1) * (cell + pad) - pad, width: width, height: cell + pad))
            for (col, busy) in [false, true].enumerated() {
                let origin = CGPoint(x: pad + col * (cell + pad), y: height - pad - cell - row * (cell + pad) - pad / 2)
                ctx.saveGState()
                ctx.translateBy(x: origin.x, y: origin.y)
                ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                // Draw the glyph into a transparency layer, then tint it like the menu bar does.
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                OrbitGlyph.draw(in: ctx, busy: busy)
                ctx.setBlendMode(.sourceIn)
                ctx.setFillColor(dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: OrbitGlyph.side, height: OrbitGlyph.side))
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: output, options: replace ? .atomic : .withoutOverwriting)
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
