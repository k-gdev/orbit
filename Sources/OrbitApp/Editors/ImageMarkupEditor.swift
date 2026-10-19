import Combine
import OrbitCore
import SwiftUI

enum MarkupTool: Equatable {
    case crop, arrow, box, text, marker, step, blackout, resize
}

struct CropAspect: Equatable, Identifiable {
    let title: String
    let ratio: Double?
    var id: String { title }

    static let free = CropAspect(title: "Free", ratio: nil)
    static let all = [free,
                      CropAspect(title: "1:1", ratio: 1),
                      CropAspect(title: "4:3", ratio: 4.0 / 3),
                      CropAspect(title: "16:9", ratio: 16.0 / 9),
                      CropAspect(title: "3:2", ratio: 3.0 / 2)]
}

enum MarkupThickness: CaseIterable {
    case thin, medium, thick

    var title: String {
        switch self {
        case .thin: "Thin"
        case .medium: "Medium"
        case .thick: "Thick"
        }
    }

    var multiplier: Double {
        switch self {
        case .thin: 0.6
        case .medium: 1
        case .thick: 1.8
        }
    }
}

enum ResizeMode { case pixels, percent }

/// State of the Markup editor. Everything is in image pixels with the origin at top left, the same space
/// `MarkupDocument` uses; the canvas only converts for display.
@MainActor
final class MarkupModel: ObservableObject {
    struct Snapshot: Equatable {
        var elements: [MarkupElement]
        var crop: CGRect?
        var resizeTarget: CGSize?
    }

    struct TextEntry: Equatable {
        var point: CGPoint
        var string = ""
    }

    /// What a crop drag started on.
    private enum CropDrag {
        case new(anchor: CGPoint)
        case move(start: CGRect, grab: CGPoint)
        case corner(anchor: CGPoint)
    }

    static let maxPixels = 20_000.0

    @Published private(set) var image: EditorImage?
    @Published var loadError: String?
    @Published private(set) var elements: [MarkupElement] = []
    @Published private(set) var crop: CGRect? {
        didSet { if crop != oldValue { cropChanged(from: oldValue) } }
    }
    @Published var draft: MarkupElement?
    @Published var textEntry: TextEntry?
    @Published var tool = MarkupTool.arrow {
        didSet { if tool != oldValue { commitText() } }
    }
    @Published private(set) var aspect = CropAspect.free
    @Published var color = Color(red: 1, green: 0.23, blue: 0.19)
    @Published var thickness = MarkupThickness.medium
    @Published var resizeMode = ResizeMode.pixels
    @Published var lockAspect = true
    /// The size the user asked to resize to; nil keeps the (cropped) size.
    @Published private(set) var resizeTarget: CGSize?
    @Published private var undoStack: [Snapshot] = []
    @Published private var redoStack: [Snapshot] = []

    private var markerPoints: [CGPoint] = []
    private var cropDrag: CropDrag?
    private var cropBefore: Snapshot?

    var imageSize: CGSize { image?.pixelSize ?? .zero }
    var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// Sets the image directly (headless snapshots).
    func set(image: EditorImage) { self.image = image }

    func load(_ url: URL) async {
        do {
            image = try await Task.detached(priority: .userInitiated) { try EditorImage.load(url) }.value
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Document

    /// The crop that will be applied: whole pixels, inside the image, and not the whole image.
    var effectiveCrop: CGRect? {
        guard let crop else { return nil }
        let r = crop.standardized.integral.intersection(imageBounds)
        guard !r.isNull, r.width >= 1, r.height >= 1, r != imageBounds else { return nil }
        return r
    }

    /// Size after cropping, before resizing.
    var baseSize: CGSize { effectiveCrop?.size ?? imageSize }

    var effectiveResize: CGSize? {
        guard let resizeTarget, resizeTarget != baseSize else { return nil }
        return resizeTarget
    }

    var outputSize: CGSize { effectiveResize ?? baseSize }

    var isEmpty: Bool { elements.isEmpty && effectiveCrop == nil && effectiveResize == nil && textEntry?.string.isEmpty != false }

    var canApply: Bool { image != nil && !isEmpty }

    func document() -> MarkupDocument {
        commitText()
        return MarkupDocument(elements: elements, crop: effectiveCrop, resize: effectiveResize)
    }

    // MARK: Sizes that follow the image

    /// 1 for a 1000 px image; marks scale with the image so they look the same at any resolution.
    var unit: Double { max(max(imageSize.width, imageSize.height) / 1000, 0.6) }
    var lineWidth: CGFloat { CGFloat(6 * unit * thickness.multiplier) }
    var markerWidth: CGFloat { CGFloat(9 * unit * thickness.multiplier) }
    var textSize: CGFloat { CGFloat(34 * unit * thickness.multiplier) }
    var rgba: RGBA { RGBA(color) }

    // MARK: Undo

    private var snapshot: Snapshot { Snapshot(elements: elements, crop: crop, resizeTarget: resizeTarget) }

    private func restore(_ s: Snapshot) {
        elements = s.elements
        crop = s.crop
        resizeTarget = s.resizeTarget
    }

    private func recordUndo(_ before: Snapshot) {
        undoStack.append(before)
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        commitText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    // MARK: Marks

    func add(_ element: MarkupElement) {
        let before = snapshot
        elements.append(element)
        recordUndo(before)
    }

    var nextStepNumber: Int {
        elements.reduce(0) { if case .step(let n, _, _) = $1 { max($0, n) } else { $0 } } + 1
    }

    func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
    }

    /// A drag with the current tool. `start` and `point` are image pixels.
    func drag(from start: CGPoint, to point: CGPoint, began: Bool) {
        let s = clamped(start), p = clamped(point)
        switch tool {
        case .arrow:
            draft = .arrow(from: s, to: p, color: rgba, width: lineWidth)
        case .box:
            draft = .box(CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)),
                         color: rgba, width: lineWidth)
        case .blackout:
            draft = .blackout(CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)))
        case .marker:
            if began { markerPoints = [s] }
            if markerPoints.last != p { markerPoints.append(p) }
            draft = .marker(markerPoints, color: rgba, width: markerWidth)
        case .crop, .text, .step, .resize:
            break
        }
    }

    /// The pointer went up: commit the draft, or place a text or step mark for a click.
    func finishDrag(at point: CGPoint, viewDistance: CGFloat) {
        let p = clamped(point)
        defer { draft = nil; markerPoints = [] }
        switch tool {
        case .arrow, .box, .blackout:
            guard viewDistance >= 3, let draft else { return }
            add(draft)
        case .marker:
            if let draft { add(draft) }
        case .text:
            commitText()
            textEntry = TextEntry(point: p)
        case .step:
            commitText()
            add(.step(nextStepNumber, at: p, color: rgba))
        case .crop, .resize:
            break
        }
    }

    func commitText() {
        guard let entry = textEntry else { return }
        textEntry = nil
        let text = entry.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        add(.text(text, at: entry.point, size: textSize, color: rgba))
    }

    // MARK: Crop

    func setAspect(_ new: CropAspect) {
        aspect = new
        tool = .crop
        guard let ratio = new.ratio else { return }
        let before = snapshot
        if let current = crop {
            crop = EditorGeometry.constrain(current, aspect: ratio, within: imageSize)
        } else {
            crop = EditorGeometry.centeredRect(aspect: ratio, within: imageSize)
        }
        if before != snapshot { recordUndo(before) }
    }

    func removeCrop() {
        guard crop != nil else { return }
        let before = snapshot
        crop = nil
        recordUndo(before)
    }

    /// Radius, in image pixels, within which a crop corner can be grabbed.
    func beginCrop(at point: CGPoint, handleRadius: CGFloat) {
        let p = clamped(point)
        cropBefore = snapshot
        if let r = crop?.standardized {
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            if let index = corners.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= handleRadius }) {
                cropDrag = .corner(anchor: corners[3 - index])
                return
            }
            if r.contains(p) {
                cropDrag = .move(start: r, grab: p)
                return
            }
        }
        cropDrag = .new(anchor: p)
    }

    func dragCrop(to point: CGPoint) {
        let p = clamped(point)
        switch cropDrag {
        case .new(let anchor)?, .corner(let anchor)?:
            crop = EditorGeometry.cropRect(anchor: anchor, to: p, aspect: aspect.ratio, within: imageSize)
        case .move(let start, let grab)?:
            let x = min(max(start.minX + p.x - grab.x, 0), imageSize.width - start.width)
            let y = min(max(start.minY + p.y - grab.y, 0), imageSize.height - start.height)
            crop = CGRect(x: x.rounded(), y: y.rounded(), width: start.width, height: start.height)
        case nil:
            break
        }
    }

    func endCrop() {
        defer { cropDrag = nil; cropBefore = nil }
        guard let before = cropBefore else { return }
        // A click, or a sliver, leaves the crop as it was.
        if let r = crop, r.width < 8 || r.height < 8 {
            crop = before.crop
            return
        }
        if before != snapshot { recordUndo(before) }
    }

    private func cropChanged(from old: CGRect?) {
        guard let target = resizeTarget else { return }
        // Keep the resize at the same percentage of the new size.
        let oldBase = effectiveCrop(of: old).size
        guard oldBase.width > 0 else { return }
        let percent = target.width / oldBase.width * 100
        resizeTarget = EditorGeometry.size(forPercent: percent, of: baseSize)
    }

    private func effectiveCrop(of rect: CGRect?) -> CGRect {
        guard let rect else { return imageBounds }
        let r = rect.standardized.integral.intersection(imageBounds)
        return r.isNull ? imageBounds : r
    }

    // MARK: Resize

    var resizeWidth: Double { outputSize.width }
    var resizeHeight: Double { outputSize.height }
    var resizePercent: Double { baseSize.width > 0 ? (outputSize.width / baseSize.width * 100).rounded() : 100 }

    func setResize(width: Double) {
        let w = min(max(width.rounded(), 1), Self.maxPixels)
        let size = lockAspect ? EditorGeometry.size(forWidth: w, keepingAspectOf: baseSize)
                              : CGSize(width: w, height: outputSize.height)
        setResizeTarget(size)
    }

    func setResize(height: Double) {
        let h = min(max(height.rounded(), 1), Self.maxPixels)
        let size = lockAspect ? EditorGeometry.size(forHeight: h, keepingAspectOf: baseSize)
                              : CGSize(width: outputSize.width, height: h)
        setResizeTarget(size)
    }

    func setResize(percent: Double) {
        setResizeTarget(EditorGeometry.size(forPercent: min(max(percent, 1), 1000), of: baseSize))
    }

    func resetResize() {
        guard resizeTarget != nil else { return }
        let before = snapshot
        resizeTarget = nil
        recordUndo(before)
    }

    private func setResizeTarget(_ size: CGSize) {
        let clamped = CGSize(width: min(size.width, Self.maxPixels), height: min(size.height, Self.maxPixels))
        guard clamped != resizeTarget else { return }
        let before = snapshot
        resizeTarget = clamped
        recordUndo(before)
    }

    /// Sets the crop directly (headless snapshots).
    func setCrop(_ rect: CGRect?) { crop = rect }

    /// Sets the marks directly (headless snapshots).
    func setElements(_ list: [MarkupElement]) { elements = list }
}

struct ImageMarkupEditor: View {
    static let width: CGFloat = 680

    let title: String
    @ObservedObject var model: MarkupModel
    let onClose: () -> Void
    let onApply: (MarkupDocument) -> Void

    var body: some View {
        EditorShell(title: title, canApply: model.canApply, onClose: onClose,
                    onApply: { onApply(model.document()) }) {
            VStack(spacing: 12) {
                MarkupCanvas(model: model).frame(height: 380)
                toolRow
                optionRow
                statusRow
            }
        }
    }

    // MARK: Toolbar

    private var toolRow: some View {
        HStack(spacing: 6) {
            tool(.crop, "crop", "Crop")
            tool(.arrow, "arrow.up.right", "Arrow")
            tool(.box, "rectangle", "Box")
            tool(.text, "textformat", "Text")
            tool(.marker, "pencil.tip", "Marker")
            tool(.step, "1.circle", "Step")
            tool(.blackout, "rectangle.fill", "Blackout")
            tool(.resize, "arrow.up.left.and.arrow.down.right", "Resize")
        }
    }

    private func tool(_ tool: MarkupTool, _ symbol: String, _ title: String) -> some View {
        ToolButton(symbol: symbol, title: title, selected: model.tool == tool, enabled: model.image != nil, expands: true) {
            model.tool = tool
        }
    }

    private var optionRow: some View {
        HStack(spacing: 8) {
            switch model.tool {
            case .crop:
                ForEach(CropAspect.all) { aspect in
                    ChoiceChip(title: aspect.title, selected: model.aspect == aspect) { model.setAspect(aspect) }
                }
                if model.crop != nil { ChoiceChip(title: "Remove crop", selected: false) { model.removeCrop() } }
            case .resize:
                resizeControls
            case .text:
                hint("Click the photo to type")
            case .step:
                hint("Click to number a spot")
            case .blackout:
                hint("Drag over anything to black it out")
            case .arrow, .box, .marker:
                hint("Drag on the photo")
            }
            Spacer(minLength: 8)
            if [.arrow, .box, .text, .marker].contains(model.tool) {
                ForEach(MarkupThickness.allCases, id: \.title) { t in
                    ChoiceChip(title: String(t.title.prefix(1)), selected: model.thickness == t) { model.thickness = t }
                        .help(t.title)
                }
            }
            if model.tool != .blackout, model.tool != .crop, model.tool != .resize {
                OrbitColorWell(color: $model.color, help: "Color")
            }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle()).disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconButtonStyle()).disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo")
        }
        .frame(minHeight: 32)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private var resizeControls: some View {
        HStack(spacing: 8) {
            ChoiceChip(title: "Pixels", selected: model.resizeMode == .pixels) { model.resizeMode = .pixels }
            ChoiceChip(title: "Percent", selected: model.resizeMode == .percent) { model.resizeMode = .percent }
            switch model.resizeMode {
            case .pixels:
                NumberField(value: Binding(get: { model.resizeWidth }, set: { model.setResize(width: $0) }))
                Button { model.lockAspect.toggle() } label: {
                    Image(systemName: model.lockAspect ? "lock.fill" : "lock.open")
                        .font(.system(size: 12)).foregroundStyle(model.lockAspect ? EditorStyle.accent : Color.secondary)
                }
                .buttonStyle(.plain).help(model.lockAspect ? "Keep the proportions" : "Change width and height separately")
                NumberField(value: Binding(get: { model.resizeHeight }, set: { model.setResize(height: $0) }))
            case .percent:
                NumberField(value: Binding(get: { model.resizePercent }, set: { model.setResize(percent: $0) }), width: 56)
                Text("%").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if model.resizeTarget != nil { ChoiceChip(title: "Reset", selected: false) { model.resetResize() } }
        }
    }

    private var statusRow: some View {
        HStack {
            if let error = model.loadError {
                Text(error).foregroundStyle(.secondary)
            } else if model.image != nil {
                if let crop = model.effectiveCrop {
                    Text("Crop \(Int(crop.width)) × \(Int(crop.height)) px").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height)) px")
            }
        }
        .font(.system(size: 13).monospacedDigit())
        .frame(minHeight: 18)
    }
}

private struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}
