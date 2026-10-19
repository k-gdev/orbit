import AppKit
import Combine
import OrbitCore
import SwiftUI

struct VideoCropAspect: Equatable, Identifiable {
    let title: String
    /// Width ÷ height; nil lets the rectangle take any shape.
    let ratio: Double?
    var id: String { title }

    static let free = VideoCropAspect(title: "Freeform", ratio: nil)
    static let all = [free,
                      VideoCropAspect(title: "1:1", ratio: 1),
                      VideoCropAspect(title: "4:3", ratio: 4.0 / 3),
                      VideoCropAspect(title: "16:9", ratio: 16.0 / 9),
                      VideoCropAspect(title: "9:16", ratio: 9.0 / 16)]
}

/// State of the Crop Video editor: the crop rectangle in the video's display pixels (top left origin), and the aspect
/// ratio it keeps. Sizes and positions are whole, even pixels, because video encoders need even dimensions.
@MainActor
final class CropModel: ObservableObject {
    let session: MediaSession

    @Published private(set) var aspect = VideoCropAspect.free
    @Published private(set) var rect = CGRect.zero

    private enum Drag {
        case move(grab: CGSize)
        case resize(anchor: CGPoint)
    }

    private var drag: Drag?
    private var sessionChanges: AnyCancellable?

    /// The smallest side a crop can have.
    static let minimumSide: CGFloat = 16

    init(session: MediaSession) {
        self.session = session
        session.generatesStills = true
        sessionChanges = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var size: CGSize { session.videoSize ?? .zero }

    func load() async {
        await session.load()
        reset()
    }

    func reset() {
        aspect = .free
        rect = CGRect(origin: .zero, size: size)
    }

    var isWholeFrame: Bool { rect.size == size }

    /// What Apply hands to the job; nil when the crop is the whole frame (nothing to do) or the video isn't open yet.
    var parameters: ToolParameters? {
        guard session.isReady, size.width > 0, rect.width >= 2, rect.height >= 2, !isWholeFrame else { return nil }
        return .cropRect(rect)
    }

    // MARK: Aspect ratio and sliders

    /// Switches the ratio: the rectangle becomes the largest of that ratio inside the current one, around its center.
    func setAspect(_ new: VideoCropAspect) {
        aspect = new
        guard let ratio = new.ratio, size.width > 0 else { return }
        var w = rect.width, h = w / ratio
        if h > rect.height { h = rect.height; w = h * ratio }
        place(width: w, height: h, around: CGPoint(x: rect.midX, y: rect.midY))
    }

    var widthPercent: Double { size.width > 0 ? Double(rect.width / size.width) * 100 : 100 }
    var heightPercent: Double { size.height > 0 ? Double(rect.height / size.height) * 100 : 100 }

    func setWidthPercent(_ percent: Double) {
        guard size.width > 0 else { return }
        var w = max(CGFloat(percent) / 100 * size.width, Self.minimumSide)
        var h = aspect.ratio.map { w / CGFloat($0) } ?? rect.height
        if h > size.height { h = size.height; w = h * CGFloat(aspect.ratio ?? 1) }
        place(width: w, height: h, around: CGPoint(x: rect.midX, y: rect.midY))
    }

    func setHeightPercent(_ percent: Double) {
        guard size.height > 0 else { return }
        var h = max(CGFloat(percent) / 100 * size.height, Self.minimumSide)
        var w = aspect.ratio.map { h * CGFloat($0) } ?? rect.width
        if w > size.width { w = size.width; h = w / CGFloat(aspect.ratio ?? 1) }
        place(width: w, height: h, around: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// A rectangle `width` x `height` centered on `center` as closely as the frame allows.
    private func place(width: CGFloat, height: CGFloat, around center: CGPoint) {
        let w = min(max(width, Self.minimumSide), size.width), h = min(max(height, Self.minimumSide), size.height)
        rect = snapped(CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
    }

    /// Whole, even pixels, inside the frame. A side that spans the frame stays exactly as long as the frame.
    func snapped(_ r: CGRect) -> CGRect {
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }
        let w = r.width >= size.width ? size.width : max(2, (r.width / 2).rounded(.down) * 2)
        let h = r.height >= size.height ? size.height : max(2, (r.height / 2).rounded(.down) * 2)
        let x = min(max(even(r.minX), 0), max(size.width - w, 0))
        let y = min(max(even(r.minY), 0), max(size.height - h, 0))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Dragging (points are video pixels)

    /// A drag started at `point`: on a corner it resizes against the opposite corner, inside the rectangle it moves it,
    /// and elsewhere it draws a new rectangle from that point.
    func beginDrag(at point: CGPoint, handleRadius: CGFloat) {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        if let index = corners.indices.min(by: { distance(corners[$0], point) < distance(corners[$1], point) }),
           distance(corners[index], point) <= handleRadius {
            drag = .resize(anchor: corners[3 - index])
        } else if rect.contains(point) {
            drag = .move(grab: CGSize(width: point.x - rect.minX, height: point.y - rect.minY))
        } else {
            drag = .resize(anchor: CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height)))
        }
    }

    func updateDrag(to point: CGPoint) {
        switch drag {
        case .move(let grab):
            rect = snapped(CGRect(x: point.x - grab.width, y: point.y - grab.height, width: rect.width, height: rect.height))
        case .resize(let anchor):
            let r = EditorGeometry.cropRect(anchor: anchor, to: point, aspect: aspect.ratio, within: size)
            if r.width >= Self.minimumSide, r.height >= Self.minimumSide { rect = snapped(r) }
        case nil:
            break
        }
    }

    func endDrag() { drag = nil }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// The hero's "Crop Video" panel: a frame with a draggable crop rectangle, Aspect ratio, Reset and the pixel size,
/// Width and Height sliders, and a frame scrubber.
struct VideoCropEditor: View {
    static let width: CGFloat = 440

    let title: String
    @ObservedObject var model: CropModel
    let onClose: () -> Void
    let onApply: (ToolParameters) -> Void

    @Environment(\.glassRendering) private var rendering

    private var session: MediaSession { model.session }

    var body: some View {
        EditorShell(title: title, canApply: model.parameters != nil, onClose: onClose,
                    onApply: { if let parameters = model.parameters { onApply(parameters) } }) {
            VStack(spacing: 14) {
                preview
                aspectRow
                HStack {
                    Button { model.reset() } label: {
                        Text("Reset").font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(verbatim: "\(Int(model.rect.width)) × \(Int(model.rect.height)) px")
                        .font(.system(size: 14).monospacedDigit())
                }
                VStack(spacing: 10) {
                    sliderRow("Width", percent: Binding(get: { model.widthPercent }, set: { model.setWidthPercent($0) }))
                    sliderRow("Height", percent: Binding(get: { model.heightPercent }, set: { model.setHeightPercent($0) }))
                }
                scrubber
            }
        }
    }

    // MARK: Preview

    /// The panel is sized once, when it opens, so the preview area has the same height whatever the video turns out to be.
    private var preview: some View {
        previewContent.frame(maxWidth: .infinity).frame(height: 250)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch session.status {
        case .ready:
            if let size = session.videoSize {
                CropCanvas(model: model, image: session.still, videoSize: size)
                    .aspectRatio(size, contentMode: .fit)
            }
        case .loading(let message):
            note { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(message) } }
        case .failed(let message):
            note { Text(message).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 16) }
        }
    }

    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 12.5)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    // MARK: Controls

    private var aspectRow: some View {
        HStack(spacing: 14) {
            Text("Aspect ratio").font(.system(size: 15, weight: .medium))
            if rendering == .live {
                Menu {
                    ForEach(VideoCropAspect.all) { option in
                        Button(option.title) { model.setAspect(option) }
                    }
                } label: { popupLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else {
                popupLabel
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var popupLabel: some View {
        HStack {
            Text(model.aspect.title).font(.system(size: 15))
            Spacer(minLength: 12)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(width: 170)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
    }

    private func sliderRow(_ label: String, percent: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 14)).frame(width: 52, alignment: .leading)
            OrbitSlider(value: percent, range: 5...100, step: 1)
            Text("\(Int(percent.wrappedValue.rounded()))%")
                .font(.system(size: 14).monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                StepButton(forward: false) { session.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                ScrubberView(duration: session.duration, playhead: session.playhead, onSeek: { session.seek(to: $0) })
                StepButton(forward: true) { session.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            HStack {
                TimeLabel(seconds: session.playhead)
                TimeLabel(seconds: session.duration, alignment: .trailing)
            }
        }
        .opacity(session.isReady ? 1 : 0.5)
        .allowsHitTesting(session.isReady)
    }
}

/// The frame with the crop rectangle on it: everything outside the rectangle is dimmed, the rectangle has a white edge
/// and corner handles. Dragging uses `EditorGeometry` to go between this view and the video's pixels.
private struct CropCanvas: View {
    @ObservedObject var model: CropModel
    let image: CGImage?
    let videoSize: CGSize

    private static let grabRadius: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let view = proxy.size
            let crop = EditorGeometry.imageToView(model.rect, image: videoSize, view: view)
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: view.width, height: view.height).clipped()
                } else {
                    ProgressView().controlSize(.small).frame(width: view.width, height: view.height)
                }
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: view))
                    p.addRect(crop)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Rectangle().stroke(Color.white, lineWidth: 2).frame(width: crop.width, height: crop.height).offset(x: crop.minX, y: crop.minY)
                ForEach(0..<4, id: \.self) { corner in
                    let x = corner % 2 == 0 ? crop.minX : crop.maxX, y = corner < 2 ? crop.minY : crop.maxY
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.4), radius: 1.5)
                        .offset(x: x - 4.5, y: y - 4.5)
                }
            }
            .frame(width: view.width, height: view.height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let toPixels = { (p: CGPoint) in EditorGeometry.viewToImage(p, image: videoSize, view: view) }
                    if !dragging {
                        dragging = true
                        let scale = videoSize.width / max(EditorGeometry.fittedRect(image: videoSize, in: view).width, 1)
                        model.beginDrag(at: toPixels(drag.startLocation), handleRadius: Self.grabRadius * scale)
                    }
                    model.updateDrag(to: toPixels(drag.location))
                }
                .onEnded { _ in
                    dragging = false
                    model.endDrag()
                })
        }
    }

    @State private var dragging = false
}
