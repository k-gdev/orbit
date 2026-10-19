import OrbitCore
import SwiftUI

/// Where times sit along a scrubber `width` points wide. The ends are inset so a knob or handle at 0 or at the
/// duration is not clipped.
enum ScrubberGeometry {
    static let inset: CGFloat = 10

    static func x(_ time: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return inset }
        let usable = max(width - 2 * inset, 1)
        return inset + CGFloat(min(max(time / duration, 0), 1)) * usable
    }

    static func time(atX x: CGFloat, duration: Double, width: CGFloat) -> Double {
        let usable = max(width - 2 * inset, 1)
        return min(max(Double((x - inset) / usable), 0), 1) * duration
    }
}

/// The editors' timeline. In its plain style it is a knob on a thin track (the hero's frame scrubber). In the range
/// style it is a taller bar that can also show a selection with a handle at each end (trim and bleep), split markers,
/// and marked ranges (bleep). Dragging a handle moves that end; dragging anywhere else moves the playhead.
struct ScrubberView: View {
    enum Style { case plain, range }

    var duration: Double
    var playhead: Double
    var style = Style.plain
    var selection: ClosedRange<Double>?
    var markers: [Double] = []
    var ranges: [ClosedRange<Double>] = []
    var onSeek: (Double) -> Void
    var onMoveStart: ((Double) -> Void)?
    var onMoveEnd: ((Double) -> Void)?

    @State private var target: Target?

    private enum Target { case start, end, playhead }

    private static let knob: CGFloat = 20
    private static let barHeight: CGFloat = 40
    private static let handleWidth: CGFloat = 12
    private static let grabRadius: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = { (t: Double) in ScrubberGeometry.x(t, duration: duration, width: width) }
            ZStack(alignment: .topLeading) {
                switch style {
                case .plain: plain(x: x, height: proxy.size.height)
                case .range: range(x: x, width: width)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if target == nil { target = hit(at: drag.startLocation.x, x: x) }
                    let t = ScrubberGeometry.time(atX: drag.location.x, duration: duration, width: width)
                    switch target ?? .playhead {
                    case .start: onMoveStart?(t)
                    case .end: onMoveEnd?(t)
                    case .playhead: onSeek(t)
                    }
                }
                .onEnded { _ in target = nil })
        }
        .frame(height: style == .plain ? Self.knob + 2 : Self.barHeight + 10)
    }

    private func hit(at point: CGFloat, x: (Double) -> CGFloat) -> Target {
        guard style == .range, let selection, onMoveStart != nil, onMoveEnd != nil else { return .playhead }
        let startX = x(selection.lowerBound), endX = x(selection.upperBound)
        let toStart = abs(point - startX), toEnd = abs(point - endX)
        guard min(toStart, toEnd) <= Self.grabRadius else { return .playhead }
        if toStart == toEnd { return point < startX ? .start : .end }
        return toStart < toEnd ? .start : .end
    }

    // MARK: Plain

    private func plain(x: (Double) -> CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                .padding(.horizontal, ScrubberGeometry.inset).offset(y: (height - 4) / 2)
            Circle().fill(Color.white)
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .offset(x: x(playhead) - Self.knob / 2, y: (height - Self.knob) / 2)
        }
    }

    // MARK: Range

    private func range(x: @escaping (Double) -> CGFloat, width: CGFloat) -> some View {
        let top: CGFloat = 5
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.10))
                .frame(width: max(width - 2 * ScrubberGeometry.inset, 0), height: Self.barHeight)
                .offset(x: ScrubberGeometry.inset, y: top)
            ForEach(Array(ranges.enumerated()), id: \.offset) { _, r in
                Rectangle().fill(Color.red.opacity(0.55))
                    .frame(width: max(x(r.upperBound) - x(r.lowerBound), 2), height: Self.barHeight)
                    .offset(x: x(r.lowerBound), y: top)
            }
            if let selection {
                Rectangle().fill(OrbitTheme.accent.opacity(0.28))
                    .frame(width: max(x(selection.upperBound) - x(selection.lowerBound), 0), height: Self.barHeight)
                    .overlay(alignment: .top) { Rectangle().fill(OrbitTheme.accent).frame(height: 2) }
                    .overlay(alignment: .bottom) { Rectangle().fill(OrbitTheme.accent).frame(height: 2) }
                    .offset(x: x(selection.lowerBound), y: top)
                handle(at: x(selection.lowerBound), top: top)
                handle(at: x(selection.upperBound), top: top)
            }
            ForEach(Array(markers.enumerated()), id: \.offset) { _, t in
                Rectangle().fill(OrbitTheme.accentMarker).frame(width: 2, height: Self.barHeight + 4)
                    .offset(x: x(t) - 1, y: top - 2)
                Circle().fill(OrbitTheme.accentMarker).frame(width: 8, height: 8).offset(x: x(t) - 4, y: top - 5)
            }
            Rectangle().fill(Color.primary.opacity(0.9)).frame(width: 2, height: Self.barHeight + 10)
                .shadow(color: .white.opacity(0.6), radius: 1)
                .offset(x: x(playhead) - 1)
        }
    }

    private func handle(at centerX: CGFloat, top: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(OrbitTheme.accent)
            .frame(width: Self.handleWidth, height: Self.barHeight)
            .overlay { Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 14) }
            .offset(x: centerX - Self.handleWidth / 2, y: top)
    }
}

/// ◁| and |▷: one frame back or forward (the hero's frame stepper), drawn as a path so it renders everywhere.
struct StepButton: View {
    let forward: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StepGlyph(forward: forward)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 15, height: 12)
                .frame(width: 52, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(forward ? "Next" : "Previous")
    }
}

struct StepGlyph: Shape {
    let forward: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let barX = forward ? rect.minX + 0.8 : rect.maxX - 0.8
        p.move(to: CGPoint(x: barX, y: rect.minY))
        p.addLine(to: CGPoint(x: barX, y: rect.maxY))
        let near = forward ? rect.minX + 5 : rect.maxX - 5
        let far = forward ? rect.maxX : rect.minX
        p.move(to: CGPoint(x: near, y: rect.minY))
        p.addLine(to: CGPoint(x: far, y: rect.midY))
        p.addLine(to: CGPoint(x: near, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A time under a scrubber: monospaced and quiet, like the hero's.
struct TimeLabel: View {
    let seconds: Double
    var alignment = Alignment.leading

    var body: some View {
        Text(TimeFormat.string(seconds))
            .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}
