import CoreGraphics
import CoreText
import Foundation

/// Burns a markup document into the pixels of an image: elements first (in pixel space, origin top left),
/// then the crop, then the resize.
public enum MarkupRenderer {
    static let stepDiameter: CGFloat = 36

    public static func render(_ image: CGImage, _ document: MarkupDocument) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let opaque = !ImageFile.hasAlpha(image)
        var result = image

        if !document.elements.isEmpty {
            let ctx = try ImageBitmap.makeContext(width: image.width, height: image.height, opaque: opaque)
            ctx.draw(image, in: bounds)
            // From here on, coordinates are pixels with the origin at the top left.
            ctx.translateBy(x: 0, y: CGFloat(image.height))
            ctx.scaleBy(x: 1, y: -1)
            for element in document.elements { draw(element, in: ctx) }
            guard let marked = ctx.makeImage() else { throw ImageBitmap.failure }
            result = marked
        }

        if let crop = document.crop {
            let rect = crop.integral.intersection(CGRect(x: 0, y: 0, width: result.width, height: result.height))
            guard !rect.isNull, rect.width >= 1, rect.height >= 1, let cropped = result.cropping(to: rect) else {
                throw OrbitError.unsupported("The crop is outside the image.")
            }
            result = cropped
        }

        if let size = document.resize {
            let w = Int(size.width.rounded()), h = Int(size.height.rounded())
            guard w >= 1, h >= 1 else { throw OrbitError.unsupported("The new size must be at least 1 pixel.") }
            if w != result.width || h != result.height {
                let ctx = try ImageBitmap.makeContext(width: w, height: h, opaque: opaque)
                ctx.interpolationQuality = .high
                ctx.draw(result, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let resized = ctx.makeImage() else { throw ImageBitmap.failure }
                result = resized
            }
        }
        return result
    }

    private static func draw(_ element: MarkupElement, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch element {
        case .blackout(let rect):
            ctx.setBlendMode(.normal)
            ctx.setShouldAntialias(false)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(rect.standardized.integral)

        case .box(let rect, let color, let width):
            ctx.setStrokeColor(ImageBitmap.cgColor(color))
            ctx.setLineWidth(width)
            ctx.setLineJoin(.miter)
            ctx.stroke(rect)

        case .arrow(let from, let to, let color, let width):
            let dx = to.x - from.x, dy = to.y - from.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return }
            let ux = dx / length, uy = dy / length
            let head = min(max(width * 4, 14), length)
            let base = CGPoint(x: to.x - ux * head * 0.8, y: to.y - uy * head * 0.8)
            ctx.setStrokeColor(ImageBitmap.cgColor(color))
            ctx.setFillColor(ImageBitmap.cgColor(color))
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.move(to: from)
            ctx.addLine(to: base)
            ctx.strokePath()
            let half = head * 0.45
            ctx.move(to: to)
            ctx.addLine(to: CGPoint(x: to.x - ux * head + -uy * half, y: to.y - uy * head + ux * half))
            ctx.addLine(to: CGPoint(x: to.x - ux * head - -uy * half, y: to.y - uy * head - ux * half))
            ctx.closePath()
            ctx.fillPath()

        case .marker(let points, let color, let width):
            guard let first = points.first else { return }
            ctx.setStrokeColor(ImageBitmap.cgColor(color))
            ctx.setFillColor(ImageBitmap.cgColor(color))
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if points.count == 1 {
                ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            } else {
                ctx.addLines(between: points)
                ctx.strokePath()
            }

        case .text(let string, let origin, let size, let color):
            drawText(string, topLeft: origin, size: size, color: ImageBitmap.cgColor(color), in: ctx)

        case .step(let number, let center, let color):
            let r = stepDiameter / 2
            ctx.setFillColor(ImageBitmap.cgColor(color))
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: stepDiameter, height: stepDiameter))
            drawText(String(number), centeredAt: center, size: 20, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                     bold: true, in: ctx)
        }
    }

    private static func line(_ string: String, size: CGFloat, color: CGColor, bold: Bool) -> CTLine {
        let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes as [NSAttributedString.Key: Any]))
    }

    /// Draws with `topLeft` as the top left of the text, in the flipped (top-left origin) context.
    private static func drawText(_ string: String, topLeft: CGPoint, size: CGFloat, color: CGColor, in ctx: CGContext) {
        let ctLine = line(string, size: size, color: color, bold: false)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(ctLine, &ascent, nil, nil)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: topLeft.x, y: topLeft.y + ascent)
        CTLineDraw(ctLine, ctx)
    }

    private static func drawText(_ string: String, centeredAt center: CGPoint, size: CGFloat, color: CGColor,
                                 bold: Bool, in ctx: CGContext) {
        let ctLine = line(string, size: size, color: color, bold: bold)
        let bounds = CTLineGetBoundsWithOptions(ctLine, [])
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // In this flipped context the glyph box spans baseline - maxY ... baseline - minY.
        ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y + bounds.midY)
        CTLineDraw(ctLine, ctx)
    }
}
