import AppKit
import Combine
import OrbitCore
import PDFKit
import SwiftUI

/// State of the Redact editor. Redactions are kept in page space (points, origin bottom left) as PDFKit reports them, and
/// drawn on the open document as black square annotations. The annotations live only in memory: the job re-reads the file.
@MainActor
final class RedactModel: ObservableObject {
    struct Mark: Identifiable {
        let id = UUID()
        let pageIndex: Int
        let rect: CGRect
        let annotation: PDFAnnotation?
    }

    enum Mode { case selectText, drawBox }

    @Published private(set) var document: PDFDocument?
    @Published private(set) var marks: [Mark] = []
    @Published private(set) var loadError: String?
    @Published var mode = Mode.selectText { didSet { if mode == .drawBox { pdfView?.clearSelection() } } }
    /// True while some text is selected in the page view.
    @Published var hasSelection = false

    /// The live page view; set by its representable.
    weak var pdfView: PDFView?

    var canUndo: Bool { !marks.isEmpty }

    /// Rectangles grouped by page, in page order: what the job gets.
    var redactions: [PDFRedaction] {
        Dictionary(grouping: marks, by: \.pageIndex).keys.sorted().map { index in
            PDFRedaction(pageIndex: index, rects: marks.filter { $0.pageIndex == index }.map(\.rect))
        }
    }

    var summary: String {
        guard !marks.isEmpty else { return "Nothing marked yet" }
        let pages = redactions.count
        return "\(marks.count) \(marks.count == 1 ? "redaction" : "redactions") on \(pages) \(pages == 1 ? "page" : "pages")"
    }

    func load(_ url: URL) {
        guard let document = PDFDocument(url: url) else { return fail("Orbit can't read this PDF.") }
        open(document)
    }

    func open(_ document: PDFDocument) {
        if document.isLocked { return fail("This PDF is password protected. Unlock it first.") }
        guard document.pageCount > 0 else { return fail("This PDF has no pages.") }
        self.document = document
    }

    private func fail(_ message: String) { loadError = message }

    /// Marks every selected line (the "Redact Selection" button).
    func redactSelection() {
        guard let selection = pdfView?.currentSelection else { return }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                // A hair of padding so the box covers the glyph edges.
                add(page: page, rect: line.bounds(for: page).insetBy(dx: -1.5, dy: -1.5))
            }
        }
        pdfView?.clearSelection()
        hasSelection = false
    }

    /// Marks `rect` (page space) on `page`. Empty rectangles are ignored; the rectangle is kept inside the page.
    func add(page: PDFPage, rect: CGRect) {
        guard let document else { return }
        let rect = rect.standardized.intersection(page.bounds(for: .cropBox))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return }
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        annotation.color = .black
        annotation.interiorColor = .black
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
        pdfView?.annotationsChanged(on: page)
        marks.append(Mark(pageIndex: document.index(for: page), rect: rect, annotation: annotation))
    }

    func undo() {
        guard let last = marks.popLast() else { return }
        if let annotation = last.annotation, let page = annotation.page {
            page.removeAnnotation(annotation)
            pdfView?.annotationsChanged(on: page)
        }
    }

    /// Adds a mark without a live view (headless snapshots).
    func addForSnapshot(pageIndex: Int, rect: CGRect) {
        marks.append(Mark(pageIndex: pageIndex, rect: rect, annotation: nil))
    }
}

struct PDFRedactEditor: View {
    static let width: CGFloat = 600
    static let pageHeight: CGFloat = 420

    let title: String
    @ObservedObject var model: RedactModel
    let onClose: () -> Void
    let onApply: ([PDFRedaction]) -> Void

    @Environment(\.glassRendering) private var rendering

    var body: some View {
        EditorShell(title: title, applyTitle: "Redact", canApply: !model.marks.isEmpty, onClose: onClose,
                    onApply: { onApply(model.redactions) }, footerLeading: {
            Text(model.summary).font(.system(size: 12)).foregroundStyle(.secondary)
        }, content: {
            VStack(spacing: 12) {
                toolbar
                pageArea
                Text("Pages with a redaction are saved as images, so the text under the black boxes is removed for good. Other pages keep their text.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ToolButton(symbol: "text.cursor", title: "Select Text", selected: model.mode == .selectText) { model.mode = .selectText }
            ToolButton(symbol: "rectangle.dashed", title: "Draw Box", selected: model.mode == .drawBox) { model.mode = .drawBox }
            Spacer(minLength: 0)
            ToolButton(symbol: "text.redaction", title: "Redact Selection", selected: false,
                       enabled: model.hasSelection && model.mode == .selectText) { model.redactSelection() }
            ToolButton(symbol: "arrow.uturn.backward", title: "Undo", selected: false, enabled: model.canUndo) { model.undo() }
        }
    }

    private var pageArea: some View {
        ZStack {
            if let error = model.loadError {
                Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
            } else if rendering == .live {
                RedactPDFRepresentable(model: model)
            } else {
                FlatPageStandIn(model: model)
            }
        }
        .frame(maxWidth: .infinity).frame(height: Self.pageHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// What a headless snapshot shows in place of the page view (an `NSViewRepresentable` does not render there): the first page
/// with its redactions as black boxes.
private struct FlatPageStandIn: View {
    @ObservedObject var model: RedactModel

    var body: some View {
        if let page = model.document?.page(at: 0) {
            let bounds = page.bounds(for: .cropBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .cropBox)
            Image(nsImage: image)
                .resizable().aspectRatio(bounds.width / max(bounds.height, 1), contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        let scale = proxy.size.width / max(bounds.width, 1)
                        ForEach(model.marks.filter { $0.pageIndex == 0 }) { mark in
                            Rectangle().fill(Color.black)
                                .frame(width: mark.rect.width * scale, height: mark.rect.height * scale)
                                .position(x: (mark.rect.midX - bounds.minX) * scale,
                                          y: proxy.size.height - (mark.rect.midY - bounds.minY) * scale)
                        }
                    }
                }
                .padding(10)
        }
    }
}

// MARK: Live page view

/// Page view with a transparent layer on top that, in Draw Box mode, takes the mouse and rubber-bands a rectangle.
private final class RedactContainer: NSView {
    let pdfView = PDFView()
    let overlay = BoxOverlay()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor.black.withAlphaComponent(0.04)
        for view in [pdfView, overlay] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
}

private final class BoxOverlay: NSView {
    var isDrawing = false {
        didSet {
            discardCursorRects()
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Called with the finished rectangle (in this view's coordinates) and where the drag began.
    var onBox: ((CGRect, CGPoint) -> Void)?

    private var start: CGPoint?
    private var current: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? { isDrawing ? super.hitTest(point) : nil }

    override func resetCursorRects() {
        if isDrawing { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            current = nil
            needsDisplay = true
        }
        guard let start, let rect = current else { return }
        onBox?(rect, start)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let current else { return }
        NSColor.black.withAlphaComponent(0.55).setFill()
        current.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(rect: current.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }
}

private struct RedactPDFRepresentable: NSViewRepresentable {
    let model: RedactModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let container = RedactContainer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.pdfView = container.pdfView
        context.coordinator.attach(container)
        container.pdfView.document = model.document
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? RedactContainer else { return }
        if container.pdfView.document !== model.document { container.pdfView.document = model.document }
        container.overlay.isDrawing = model.mode == .drawBox
    }

    @MainActor
    final class Coordinator {
        private let model: RedactModel
        private var observer: NSObjectProtocol?

        init(model: RedactModel) { self.model = model }

        func attach(_ container: RedactContainer) {
            let pdfView = container.pdfView
            observer = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView,
                                                              queue: .main) { [weak self, weak pdfView] _ in
                MainActor.assumeIsolated {
                    let text = pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self?.model.hasSelection = !text.isEmpty
                }
            }
            container.overlay.onBox = { [weak self, weak container] rect, origin in
                MainActor.assumeIsolated {
                    guard let self, let pdfView = container?.pdfView, let overlay = container?.overlay else { return }
                    let anchor = pdfView.convert(origin, from: overlay)
                    guard let page = pdfView.page(for: anchor, nearest: true) else { return }
                    self.model.add(page: page, rect: pdfView.convert(pdfView.convert(rect, from: overlay), to: page))
                }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
