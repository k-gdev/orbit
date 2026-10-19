import SwiftUI

/// One petal of the wheel: an annular sector with rounded corners whose sides run
/// parallel to the slot's radial edges, so neighbouring petals keep a constant gap.
/// Angles are wheel degrees (0 is straight up, increasing clockwise) and the wheel
/// centre is the centre of the shape's rect.
struct PetalShape: Shape {
    var centerAngle: Double
    var halfAngle: Double
    var innerRadius: Double
    var outerRadius: Double
    var gap: Double = 6
    var cornerRadius: Double = 18

    /// The petal for slot `index` of `count` equal slots in the band `inner...outer`.
    init(index: Int, count: Int, innerRadius: Double, outerRadius: Double) {
        let width = 360.0 / Double(max(count, 1))
        self.init(centerAngle: width * Double(index), halfAngle: width / 2,
                  innerRadius: innerRadius, outerRadius: outerRadius)
    }

    init(centerAngle: Double, halfAngle: Double, innerRadius: Double, outerRadius: Double,
         gap: Double = 6, cornerRadius: Double = 18) {
        self.centerAngle = centerAngle
        self.halfAngle = halfAngle
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.gap = gap
        self.cornerRadius = cornerRadius
    }

    /// Screen point (y down) at a wheel angle and radius around `center`.
    static func point(angle degrees: Double, radius: Double, center: CGPoint) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: center.x + radius * sin(a), y: center.y - radius * cos(a))
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let alpha = halfAngle * .pi / 180
        let g = gap / 2
        let rho = feasibleCornerRadius(alpha: alpha, g: g)

        // Local frame: x to the right, y up, petal axis along +y.
        let d = (x: sin(alpha), y: cos(alpha))     // right radial edge direction
        let n = (x: -cos(alpha), y: sin(alpha))    // normal into the petal
        func local(_ s: Double, _ t: Double) -> (x: Double, y: Double) { (s * d.x + t * n.x, s * d.y + t * n.y) }

        let t = g + rho
        let sOut = ((outerRadius - rho) * (outerRadius - rho) - t * t).squareRoot()
        let sIn = ((innerRadius + rho) * (innerRadius + rho) - t * t).squareRoot()
        let outerCentre = local(sOut, t)
        let innerCentre = local(sIn, t)
        let outerLine = local(sOut, g)
        let innerLine = local(sIn, g)
        let outerArc = (x: outerCentre.x * outerRadius / (outerRadius - rho), y: outerCentre.y * outerRadius / (outerRadius - rho))
        let innerArc = (x: innerCentre.x * innerRadius / (innerRadius + rho), y: innerCentre.y * innerRadius / (innerRadius + rho))

        let c = centerAngle * .pi / 180
        // Rotate clockwise by the centre angle, then flip into screen space (y down).
        func screen(_ p: (x: Double, y: Double), mirrored: Bool = false) -> CGPoint {
            let x = mirrored ? -p.x : p.x
            return CGPoint(x: center.x + x * cos(c) + p.y * sin(c),
                           y: center.y - (-x * sin(c) + p.y * cos(c)))
        }
        func angle(of p: CGPoint, around o: CGPoint) -> Angle {
            .radians(atan2(p.y - o.y, p.x - o.x))
        }
        // Increasing screen angle is clockwise on screen; SwiftUI's `clockwise`
        // flag is expressed in a y-up space, so on-screen clockwise is `false`.
        func arc(_ path: inout Path, around o: CGPoint, radius: Double, from a: CGPoint, to b: CGPoint, onScreenClockwise: Bool) {
            path.addArc(center: o, radius: radius, startAngle: angle(of: a, around: o),
                        endAngle: angle(of: b, around: o), clockwise: !onScreenClockwise)
        }

        let lineInL = screen(innerLine, mirrored: true), lineOutL = screen(outerLine, mirrored: true)
        let arcOutL = screen(outerArc, mirrored: true), arcInL = screen(innerArc, mirrored: true)
        let centreOutL = screen(outerCentre, mirrored: true), centreInL = screen(innerCentre, mirrored: true)
        let lineInR = screen(innerLine), lineOutR = screen(outerLine)
        let arcOutR = screen(outerArc), arcInR = screen(innerArc)
        let centreOutR = screen(outerCentre), centreInR = screen(innerCentre)

        var path = Path()
        path.move(to: lineInL)
        path.addLine(to: lineOutL)
        arc(&path, around: centreOutL, radius: rho, from: lineOutL, to: arcOutL, onScreenClockwise: true)
        arc(&path, around: center, radius: outerRadius, from: arcOutL, to: arcOutR, onScreenClockwise: true)
        arc(&path, around: centreOutR, radius: rho, from: arcOutR, to: lineOutR, onScreenClockwise: true)
        path.addLine(to: lineInR)
        arc(&path, around: centreInR, radius: rho, from: lineInR, to: arcInR, onScreenClockwise: true)
        arc(&path, around: center, radius: innerRadius, from: arcInR, to: arcInL, onScreenClockwise: false)
        arc(&path, around: centreInL, radius: rho, from: arcInL, to: lineInL, onScreenClockwise: true)
        path.closeSubpath()
        return path
    }

    /// Shrinks the corner radius until the four fillets fit the slot (narrow or thin petals).
    private func feasibleCornerRadius(alpha: Double, g: Double) -> Double {
        var rho = max(0, min(cornerRadius, (outerRadius - innerRadius) / 2 - 0.5))
        while rho > 0 {
            let t = g + rho
            let fitsRadially = outerRadius - rho > t
                && ((outerRadius - rho) * (outerRadius - rho) - t * t).squareRoot()
                >= ((innerRadius + rho) * (innerRadius + rho) - t * t).squareRoot()
            let fitsAngularly = alpha >= .pi / 2 || asin(min(1, t / (innerRadius + rho))) <= alpha
            if fitsRadially && fitsAngularly { break }
            rho -= 0.5
        }
        return rho
    }
}
