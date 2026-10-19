import AppKit

/// The menu bar icon: the logo's ringed planet as a code-drawn template image (no resources, per the
/// global constraints). The ring's back half disappears behind the planet; its front half crosses the
/// planet with a gap cut either side, as in the logo. The busy variant draws the ring dashed.
enum OrbitGlyph {
    static let side: CGFloat = 18

    /// 18 x 18 pt template image; the system tints it for light/dark menu bars.
    static func image(busy: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, busy: busy)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Orbit"
        return image
    }

    /// Draws into a context whose unit square is `side` x `side`, y up. Opaque pixels are black.
    static func draw(in ctx: CGContext, busy: Bool) {
        let centre = CGPoint(x: side / 2, y: side / 2)
        let planetRadius: CGFloat = 4.9
        let ringRX: CGFloat = 8.4, ringRY: CGFloat = 2.1
        let ringWidth: CGFloat = 1.4, gap: CGFloat = 0.9
        let tilt: CGFloat = 22 * .pi / 180

        // Half of the tilted ring ellipse (`front` is the lower half, in front of the planet), or all of it.
        func ring(front: Bool?) -> CGPath {
            let transform = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: tilt)
            let path = CGMutablePath()
            let steps = 128
            let span: CGFloat = front == nil ? 2 * .pi : .pi
            for i in 0...steps {
                let t = span * CGFloat(i) / CGFloat(steps) + (front == true ? .pi : 0)
                let p = CGPoint(x: ringRX * cos(t), y: ringRY * sin(t)).applying(transform)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            if front == nil { path.closeSubpath() }
            return path
        }

        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineCap(.butt)
        let planet = CGRect(x: centre.x - planetRadius, y: centre.y - planetRadius,
                            width: planetRadius * 2, height: planetRadius * 2)
        ctx.fillEllipse(in: planet)

        // Cut the gap around the ring where it crosses the planet, then draw the front half.
        ctx.setBlendMode(.clear)
        ctx.addPath(ring(front: true))
        ctx.setLineWidth(ringWidth + gap * 2)
        ctx.strokePath()
        ctx.setBlendMode(.normal)
        if busy { ctx.setLineDash(phase: 0, lengths: [1.5, 1.3]) }
        ctx.setLineWidth(ringWidth)
        ctx.addPath(ring(front: true))
        ctx.strokePath()

        // The back half, visible only outside the planet. Idle strokes the whole ring (no seam where the
        // halves meet); busy strokes just the back half so the dashes don't overlap.
        ctx.saveGState()
        ctx.addRect(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.addEllipse(in: planet.insetBy(dx: -gap / 2, dy: -gap / 2))
        ctx.clip(using: .evenOdd)
        ctx.addPath(ring(front: busy ? false : nil))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.restoreGState()
    }
}
