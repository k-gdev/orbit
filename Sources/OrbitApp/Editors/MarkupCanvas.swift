import OrbitCore
import SwiftUI

/// The Markup editor's canvas: the image fitted in the view, the marks drawn over it, the crop, and the
/// gestures that make new marks. Marks are drawn in image pixels, scaled to the view, with the same
/// geometry `MarkupRenderer` burns into the file.
struct MarkupCanvas: View {
    @ObservedObject var model: MarkupModel

    @State private var dragging = false
    @FocusState private var textFocused: Bool
    @Environment(\.glassRendering) private var rendering

    private static let handleRadius: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let view = geo.size
            let fitted = EditorGeometry.fittedRect(image: model.imageSize, in: view)
            let scale = fitted.width > 0 ? fitted.width / model.imageSize.width : 1
            ZStack(alignment: .topLeading) {
                if let proxy = model.image?.proxy {
                    Image(decorative: proxy, scale: 1).resizable().interpolation(.medium)
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                    Canvas { context, size in draw(into: &context, view: size, fitted: fitted, scale: scale) }
                        .allowsHitTesting(false)
                    textField(view: view, scale: scale)
                } else if let error = model.loadError {
                    Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(width: view.width, height: view.height)
                } else {
                    ProgressView().controlSize(.small).frame(width: view.width, height: view.height)
                }
            }
            .frame(width: view.width, height: view.height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .gesture(dragGesture(view: view, scale: scale))
        }
    }

    // MARK: Gestures

    private func dragGesture(view: CGSize, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.image != nil else { return }
                let size = model.imageSize
                let start = EditorGeometry.viewToImage(value.startLocation, image: size, view: view)
                let point = EditorGeometry.viewToImage(value.location, image: size, view: view)
                let began = !dragging
                dragging = true
                if model.tool == .crop {
                    if began { model.beginCrop(at: start, handleRadius: Self.handleRadius / scale) }
                    if hypot(value.translation.width, value.translation.height) >= 2 { model.dragCrop(to: point) }
                } else {
                    model.drag(from: start, to: point, began: began)
                }
            }
            .onEnded { value in
                dragging = false
                guard model.image != nil else { return }
                if model.tool == .crop {
                    model.endCrop()
                } else {
                    let point = EditorGeometry.viewToImage(value.location, image: model.imageSize, view: view)
                    model.finishDrag(at: point, viewDistance: hypot(value.translation.width, value.translation.height))
                }
            }
    }

    // MARK: Text entry

    @ViewBuilder
    private func textField(view: CGSize, scale: CGFloat) -> some View {
        if let entry = model.textEntry, rendering == .live {
            let origin = EditorGeometry.imageToView(entry.point, image: model.imageSize, view: view)
            TextField("Text", text: Binding(get: { model.textEntry?.string ?? "" }, set: { model.textEntry?.string = $0 }))
                .textFieldStyle(.plain)
                .font(.custom("HelveticaNeue", fixedSize: max(13, model.textSize * scale)))
                .foregroundColor(model.color)
                .focused($textFocused)
                .onSubmit { model.commitText() }
                .frame(width: 180)
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.4)))
                .offset(x: origin.x, y: origin.y)
                .onAppear { textFocused = true }
        }
    }

    // MARK: Drawing

    private func draw(into context: inout GraphicsContext, view: CGSize, fitted: CGRect, scale: CGFloat) {
        context.clip(to: Path(fitted))
        var marks = context
        marks.translateBy(x: fitted.minX, y: fitted.minY)
        marks.scaleBy(x: scale, y: scale)
        for element in model.elements { Self.draw(element, into: &marks) }
        if let draft = model.draft { Self.draw(draft, into: &marks) }

        guard let crop = model.crop?.standardized, crop.width > 0, crop.height > 0 else { return }
        let rect = EditorGeometry.imageToView(crop, image: model.imageSize, view: view)
        var dim = Path(fitted)
        dim.addRect(rect)
        context.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
        guard model.tool == .crop else { return }
        for i in 1...2 {
            var grid = Path()
            let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
            grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
        }
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let handle = Path(ellipseIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10))
            context.fill(handle, with: .color(.white))
            context.stroke(handle, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
        }
    }

    /// Draws one mark in image pixels (the context is already scaled to them).
    private static func draw(_ element: MarkupElement, into ctx: inout GraphicsContext) {
        switch element {
        case .blackout(let rect):
            ctx.fill(Path(rect.standardized.integral), with: .color(.black))

        case .box(let rect, let color, let width):
            ctx.stroke(Path(rect), with: .color(color.color), style: StrokeStyle(lineWidth: width, lineJoin: .miter))

        case .arrow(let from, let to, let color, let width):
            let dx = to.x - from.x, dy = to.y - from.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return }
            let ux = dx / length, uy = dy / length
            let head = min(max(width * 4, 14), length)
            let half = head * 0.45
            var shaft = Path()
            shaft.move(to: from)
            shaft.addLine(to: CGPoint(x: to.x - ux * head * 0.8, y: to.y - uy * head * 0.8))
            ctx.stroke(shaft, with: .color(color.color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            var tip = Path()
            tip.move(to: to)
            tip.addLine(to: CGPoint(x: to.x - ux * head + -uy * half, y: to.y - uy * head + ux * half))
            tip.addLine(to: CGPoint(x: to.x - ux * head - -uy * half, y: to.y - uy * head - ux * half))
            tip.closeSubpath()
            ctx.fill(tip, with: .color(color.color))

        case .marker(let points, let color, let width):
            guard let first = points.first else { return }
            if points.count == 1 {
                ctx.fill(Path(ellipseIn: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)),
                         with: .color(color.color))
            } else {
                var path = Path()
                path.addLines(points)
                ctx.stroke(path, with: .color(color.color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }

        case .text(let string, let origin, let size, let color):
            ctx.draw(Text(string).font(.custom("HelveticaNeue", fixedSize: size)).foregroundColor(color.color),
                     at: origin, anchor: .topLeading)

        case .step(let number, let center, let color):
            let d: CGFloat = 36 // MarkupRenderer.stepDiameter
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)), with: .color(color.color))
            ctx.draw(Text(String(number)).font(.custom("HelveticaNeue-Bold", fixedSize: 20)).foregroundColor(.white),
                     at: center, anchor: .center)
        }
    }
}
