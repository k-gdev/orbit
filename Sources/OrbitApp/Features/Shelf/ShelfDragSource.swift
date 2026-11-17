import AppKit
import OrbitCore
import SwiftUI

private struct ShelfPreviewHoverKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    /// The file whose entry shows its hover state without a pointer (the snapshot CLI sets it).
    var shelfPreviewHover: URL? {
        get { self[ShelfPreviewHoverKey.self] }
        set { self[ShelfPreviewHoverKey.self] = newValue }
    }
}

/// One line of a shelf entry's right-click menu.
enum ShelfMenuEntry {
    case action(String, () -> Void)
    case separator
}

/// A transparent AppKit view laid over a shelf tile or list row. It is what makes the entry draggable:
/// SwiftUI's own `onDrag` can't say which operations a drag allows, but Finder needs `.move` offered to
/// move a file on the same volume (and ⌥ for copy). Dragging the entry out starts an `NSDraggingSession`
/// allowing copy, move and generic; a double-click opens the file; right-click shows its menu; it reports
/// hover (SwiftUI's `onHover` doesn't fire for an app that is never active) and can draw a small remove
/// button itself, so that button doesn't have to sit over this view.
///
/// SwiftUI controls placed above it in a `ZStack` still win the hit test over it.
struct ShelfDragSource: NSViewRepresentable {
    /// The files a drag out of this entry carries.
    var urls: [URL]
    var toolTip: String?
    /// Draw a ✕ at the top right (or `.trailing`) while hovered; clicking it calls `onRemove`.
    var removeButton: ShelfDragSourceView.RemoveButton = .none
    var onHover: (Bool) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onRemove: () -> Void = {}
    /// Called when a drag from here ended with a move or delete result: the files may have left, to be re-checked shortly.
    var onMovedOut: ([URL]) -> Void = { _ in }
    var menu: () -> [ShelfMenuEntry] = { [] }
    /// Show the hover state without a pointer (snapshots).
    var simulatesHover = false

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ShelfDragSourceView) {
        view.urls = urls
        view.toolTip = toolTip
        view.removeButton = removeButton
        view.onHover = onHover
        view.onOpen = onOpen
        view.onRemove = onRemove
        view.onMovedOut = onMovedOut
        view.menuEntries = menu
        if simulatesHover { view.simulateHover() }
    }
}

final class ShelfDragSourceView: NSView, NSDraggingSource {
    enum RemoveButton { case none, topTrailing, trailing }

    var urls: [URL] = []
    var removeButton = RemoveButton.none { didSet { if oldValue != removeButton { needsDisplay = true } } }
    var onHover: (Bool) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onRemove: () -> Void = {}
    var onMovedOut: ([URL]) -> Void = { _ in }
    var menuEntries: () -> [ShelfMenuEntry] = { [] }

    private var mouseDownEvent: NSEvent?
    private var pressedRemove = false
    private var isDragging = false
    private var draggingURLs: [URL] = []
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    private static let removeSize: CGFloat = 16

    override init(frame frameRect: NSRect) {
        assert(NSDragOperation.move.rawValue == ShelfDragOutcome.moveOperation
               && NSDragOperation.delete.rawValue == ShelfDragOutcome.deleteOperation, "ShelfDragOutcome is out of step with AppKit")
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    // The window is moved by its own handle; a mouse-down here belongs to the entry.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways`: Orbit is an accessory app that is never active, and hover must still work.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        onHover(false)
    }

    // MARK: Remove button

    private var removeRect: NSRect? {
        let size = Self.removeSize
        switch removeButton {
        case .none: return nil
        case .topTrailing: return NSRect(x: bounds.maxX - size - 3, y: isFlipped ? 3 : bounds.maxY - size - 3, width: size, height: size)
        case .trailing: return NSRect(x: bounds.maxX - size - 6, y: bounds.midY - size / 2, width: size, height: size)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, let rect = removeRect else { return }
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let cross = rect.insetBy(dx: 4.8, dy: 4.8)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cross.minX, y: cross.minY))
        path.line(to: NSPoint(x: cross.maxX, y: cross.maxY))
        path.move(to: NSPoint(x: cross.minX, y: cross.maxY))
        path.line(to: NSPoint(x: cross.maxX, y: cross.minY))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }

    /// Shows the hover state without a pointer (the snapshot CLI).
    func simulateHover() {
        guard !hovering else { return }
        hovering = true
        // Not from inside a SwiftUI update pass.
        DispatchQueue.main.async { [weak self] in self?.onHover(true) }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        switch urls.count {
        case 0: toolTip?.components(separatedBy: "\n").first.map { URL(fileURLWithPath: $0).lastPathComponent }
        case 1: urls[0].lastPathComponent
        default: "\(urls.count) files"
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        isDragging = false
        let point = convert(event.locationInWindow, from: nil)
        pressedRemove = hovering && (removeRect?.insetBy(dx: -3, dy: -3).contains(point) ?? false)
        if !pressedRemove, event.clickCount == 2 { onOpen() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !pressedRemove, !isDragging, let down = mouseDownEvent, !urls.isEmpty else { return }
        let from = down.locationInWindow
        guard hypot(event.locationInWindow.x - from.x, event.locationInWindow.y - from.y) > 4 else { return }
        isDragging = true
        beginDrag(from: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil; pressedRemove = false }
        guard pressedRemove, let rect = removeRect else { return }
        if rect.insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil)) { onRemove() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let entries = menuEntries()
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case .action(let title, let handler): menu.addItem(ClosureMenuItem(title: title, handler: handler))
            case .separator: menu.addItem(.separator())
            }
        }
        return menu
    }

    // MARK: Dragging

    private func beginDrag(from event: NSEvent) {
        draggingURLs = urls
        let point = convert(event.locationInWindow, from: nil)
        let iconSize: CGFloat = 48
        let items = urls.prefix(6).enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // A copy: the cached icon is shared, and its size must not change under the views using it.
            let icon = (ShelfIcon.icon(for: url).copy() as? NSImage) ?? ShelfIcon.icon(for: url)
            icon.size = NSSize(width: iconSize, height: iconSize)
            // A stack of icons for several files, each a little off the last.
            let offset = CGFloat(index) * 4
            item.setDraggingFrame(NSRect(x: point.x - iconSize / 2 + offset, y: point.y - iconSize / 2 + (isFlipped ? offset : -offset),
                                         width: iconSize, height: iconSize), contents: icon)
            return item
        }
        // Files beyond the sixth ride along without an icon of their own.
        let extras = urls.dropFirst(6).map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 1, height: 1), contents: nil)
            return item
        }
        beginDraggingSession(with: items + extras, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Offer all three so the destination picks: Finder moves on the same volume, copies across volumes
        // and copies with ⌥; other apps take a copy or open the file.
        [.copy, .move, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownEvent = nil
        let dragged = draggingURLs
        draggingURLs = []
        if ShelfDragOutcome.mayHaveMovedFiles(operationRawValue: operation.rawValue) { onMovedOut(dragged) }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
