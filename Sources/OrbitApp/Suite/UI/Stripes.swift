import SwiftUI

/// Diagonal "/" hatching filling its rect (and nothing outside it): the boost zone of a `PillSlider` past
/// 100. `spacing` is the repeat distance along the x axis and `stripeWidth` each stripe's width, in points.
struct Stripes: Shape {
    var spacing: CGFloat = 10
    var stripeWidth: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard spacing > 0, rect.width > 0, rect.height > 0 else { return path }
        let h = rect.height
        var x = rect.minX - h
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + stripeWidth, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + stripeWidth + h, y: rect.minY))
            path.addLine(to: CGPoint(x: x + h, y: rect.minY))
            path.closeSubpath()
            x += spacing
        }
        return path.intersection(Path(rect))
    }
}
