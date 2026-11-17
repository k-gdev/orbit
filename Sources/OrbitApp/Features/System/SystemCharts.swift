import OrbitCore
import SwiftUI

/// A small line chart of recent 0...1 values (CPU or GPU load): the newest sample at the right edge, a
/// soft fill underneath, and a faint baseline. Slots are spaced for the history's full capacity, so the
/// line grows in from the right as samples arrive.
struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    var color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        GeometryReader { geo in
            let points = Self.points(values, capacity: capacity, in: geo.size)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height - 0.5))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 0.5))
                }
                .stroke(style.trackFill, lineWidth: 1)
                if points.count > 1 {
                    Self.area(points, height: geo.size.height)
                        .fill(LinearGradient(colors: [color.opacity(colorScheme == .dark ? 0.38 : 0.28), color.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                    Self.line(points)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                if let last = points.last {
                    Circle().fill(color).frame(width: 4.5, height: 4.5).position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }

    static func points(_ values: [Double], capacity: Int, in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let slots = max(capacity - 1, 1)
        let step = size.width / CGFloat(slots)
        let inset: CGFloat = 2.5      // keeps the line's top and bottom inside the frame
        let ceiling = SparklineScale.ceiling(for: values)
        return values.suffix(capacity).reversed().enumerated().map { index, value in
            let y = inset + (1 - CGFloat(min(max(value / ceiling, 0), 1))) * (size.height - 2 * inset)
            return CGPoint(x: size.width - CGFloat(index) * step, y: y)
        }
        .reversed()
    }

    private static func line(_ points: [CGPoint]) -> Path {
        Path { path in
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    private static func area(_ points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: points[0].x, y: height))
            for point in points { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
            path.closeSubpath()
        }
    }
}

/// A thin horizontal capsule meter (memory use): the unfilled track in the panel's track colour and the
/// filled part in `color`.
struct MeterBar: View {
    let fraction: Double
    var color: Color
    var height: CGFloat = 6

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PanelStyle.colors(for: colorScheme).trackFill)
                Capsule().fill(color)
                    .frame(width: max(height, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One tiny vertical bar per core, filled from the bottom by its load: a cluster at a glance.
struct CoreBars: View {
    let loads: [Double]
    var color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let track = PanelStyle.colors(for: colorScheme).trackFill
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                ZStack(alignment: .bottom) {
                    Capsule().fill(track)
                    Capsule().fill(color)
                        .frame(height: max(4, 16 * CGFloat(min(max(load, 0), 1))))
                        .opacity(load > 0.005 ? 1 : 0.35)
                }
                .frame(width: 5.5, height: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A battery outline filled to `percent`: green while charging, red when low, ink otherwise.
struct BatteryGlyph: View {
    let percent: Int
    var isCharging: Bool
    var isLow: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let fill: Color = isCharging ? .green : isLow ? .red : style.inkOnTrack
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(style.secondaryInk.opacity(0.55), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(fill)
                    .frame(width: max(2, 20 * CGFloat(min(max(percent, 0), 100)) / 100), height: 7)
                    .padding(.leading, 2)
                if isCharging {
                    Image(systemName: "bolt.fill").font(.system(size: 7, weight: .black))
                        .foregroundStyle(percent > 55 ? Color.white : style.inkOnTrack)
                        .frame(width: 24)
                }
            }
            .frame(width: 24, height: 11)
            RoundedRectangle(cornerRadius: 1).fill(style.secondaryInk.opacity(0.55)).frame(width: 1.5, height: 4)
        }
        .accessibilityHidden(true)
    }
}
