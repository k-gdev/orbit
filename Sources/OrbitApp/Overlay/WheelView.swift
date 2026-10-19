import OrbitCore
import SwiftUI

/// The radial wheel: glass petals around the hub, plus the open sub-ring.
/// Laid out in a square of `geometry.panelSide` with the wheel centre in the middle.
struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var colorScheme

    static let accent = Color(red: 1, green: 0x5C / 255, blue: 0x1A / 255)
    static let highlightSpring = Animation.spring(response: 0.28, dampingFraction: 0.72)

    private var geometry: WheelGeometry { model.geometry }

    var body: some View {
        let side = geometry.panelSide
        let slices = model.content.slices
        ZStack {
            if !slices.isEmpty {
                // The faint disc the petals sit on, as in the hero video. A plain
                // tint, not glass, so the petals' glass never samples glass.
                Circle()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.3))
                    .overlay(Circle().stroke(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.3), lineWidth: 0.5))
                    .frame(width: geometry.subRingInner * 2, height: geometry.subRingInner * 2)
            }
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                PetalView(slice: slice,
                          shape: PetalShape(index: index, count: slices.count,
                                            innerRadius: geometry.deadZoneRadius + 8,
                                            outerRadius: geometry.outerRadius),
                          style: model.kind == .convert ? .format : .tool,
                          emphasis: emphasis(forSlice: index))
            }
            if let parent = model.openSubRing, slices.indices.contains(parent) {
                subRing(parent: parent, of: slices)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
            HubView(thumbnail: model.thumbnail, title: model.hubTitle,
                    message: slices.isEmpty ? model.content.hubMessage : nil,
                    multipleItems: model.items.count > 1, radius: geometry.deadZoneRadius)
        }
        .frame(width: side, height: side)
        .scaleEffect(model.revealed ? 1 : 0.85)
        .opacity(model.revealed ? 1 : 0)
        .animation(Self.highlightSpring, value: model.highlighted)
        .animation(Self.highlightSpring, value: model.subHighlighted)
        .animation(Self.highlightSpring, value: model.openSubRing)
        .allowsHitTesting(false)
    }

    private func subRing(parent: Int, of slices: [Slice]) -> some View {
        let children = slices[parent].children
        let step = geometry.subRingSliceDegrees
        let start = geometry.centerAngle(index: parent, count: slices.count) - Double(children.count) * step / 2
        return ZStack {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                PetalView(slice: child,
                          shape: PetalShape(centerAngle: start + step * (Double(index) + 0.5), halfAngle: step / 2,
                                            innerRadius: geometry.subRingInner, outerRadius: geometry.subRingOuter),
                          style: .child,
                          emphasis: model.subHighlighted == index ? .highlighted : .normal)
            }
        }
    }

    private func emphasis(forSlice index: Int) -> PetalView.Emphasis {
        guard model.highlighted == index else { return .normal }
        return model.subHighlighted == nil ? .highlighted : .parentOfHighlight
    }
}

/// One petal: its glass (or accent) fill and its label, in the wheel's full square.
struct PetalView: View {
    enum Style { case format, tool, child }
    enum Emphasis { case normal, highlighted, parentOfHighlight }

    let slice: Slice
    let shape: PetalShape
    let style: Style
    let emphasis: Emphasis

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let labelRadius = shape.innerRadius + (shape.outerRadius - shape.innerRadius) * labelPosition
            let labelPoint = PetalShape.point(angle: shape.centerAngle, radius: labelRadius, center: centre)
            let chord = 2 * labelRadius * sin(min(shape.halfAngle, 90) * .pi / 180) - shape.gap
            ZStack {
                fill
                label
                    .frame(width: max(chord - 12, 24))
                    .position(labelPoint)
            }
            .scaleEffect(emphasis == .highlighted ? 1.06 : 1,
                         anchor: UnitPoint(x: labelPoint.x / max(size.width, 1), y: labelPoint.y / max(size.height, 1)))
        }
    }

    private var labelPosition: Double { style == .child ? 0.5 : 0.53 }

    @ViewBuilder private var fill: some View {
        switch emphasis {
        case .highlighted: shape.fill(WheelView.accent)
        case .parentOfHighlight: shape.fill(WheelView.accent.opacity(0.55))
        case .normal: GlassBackground(shape: shape)
        }
    }

    private var foreground: Color { emphasis == .normal ? .primary : .white }

    @ViewBuilder private var label: some View {
        VStack(spacing: 3) {
            switch style {
            case .format:
                Text(slice.title)
                    .font(.system(size: 17, weight: .bold))
            case .tool:
                if let symbol = slice.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .regular))
                        .frame(height: 24)
                }
                Text(slice.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
            case .child:
                Text(slice.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            if let subtitle = slice.subtitle {
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(foreground)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.75)
    }
}
